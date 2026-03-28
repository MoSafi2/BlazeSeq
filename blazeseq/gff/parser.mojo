"""Parser for GFF3 files.

GFF3 is a 9-column tab-delimited format with key=value attributes and
directives (##). The parser stops at ##FASTA sections and collects
##sequence-region directives. Use next_view() / next_record() and
views() / records() iterators as with BED/FAI.
"""

from std.collections import List
from std.collections.string import String, StringSlice
from std.iter import Iterator
from std.memory import Span

from blazeseq.byte_string import BString
from blazeseq.CONSTS import EOF
from blazeseq.features import Position, Interval
from blazeseq.gff.record import Gff3Record, Gff3View, Gff3Strand, SequenceRegion
from blazeseq.io.buffered import EOFError
from blazeseq.io.delimited import (
    DelimitedReader,
    DelimitedView,
    LineAction,
    LinePolicy,
)
from blazeseq.io.readers import Reader
from blazeseq.errors import ParseContext, raise_parse_error

comptime GFF_TAB: Byte = 9  # ord('\t')
comptime GFF_NUM_FIELDS: Int = 9


# ---------------------------------------------------------------------------
# Gff3ErrorCode: format-local trivial enum for hot-path field parsing
# ---------------------------------------------------------------------------


struct Gff3ErrorCode(Copyable, Equatable, TrivialRegisterPassable):
    """Trivial error code returned by low-level GFF3 field parsers; caller raises.
    """

    var value: Int8

    @always_inline
    def __init__(out self, value: Int8):
        self.value = value

    @always_inline
    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    @always_inline
    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value

    comptime OK = Self(0)
    comptime VERSION = Self(1)
    comptime SEQ_REGION = Self(2)
    comptime INT_EMPTY = Self(3)
    comptime INT_INVALID = Self(4)
    comptime STRAND_INVALID = Self(5)
    comptime PHASE_INVALID = Self(6)
    comptime FIELD_COUNT = Self(7)

    def message(self) -> String:
        if self == Self.VERSION:
            return "GFF3: ##gff-version must be 3.x"
        if self == Self.SEQ_REGION:
            return "GFF3: malformed ##sequence-region directive"
        if self == Self.INT_EMPTY:
            return "GFF3: integer field is empty"
        if self == Self.INT_INVALID:
            return "GFF3: invalid byte in integer field"
        if self == Self.STRAND_INVALID:
            return "GFF3: strand must be +, -, ., or ?"
        if self == Self.PHASE_INVALID:
            return "GFF3: phase must be 0, 1, or 2"
        if self == Self.FIELD_COUNT:
            return "GFF3: row must have exactly 9 fields"
        return "GFF3: parse error"


# ---------------------------------------------------------------------------
# Directive helper functions
# ---------------------------------------------------------------------------


def _starts_with(span: Span[UInt8, _], lit: StringLiteral) -> Bool:
    """True if span begins with the bytes of lit."""
    var s = StringSlice(lit)
    var n = len(s)
    if len(span) < n:
        return False
    var b = s.as_bytes()
    for i in range(n):
        if span[i] != b[i]:
            return False
    return True


def _check_gff_version(line: Span[UInt8, _], ctx: ParseContext) raises:
    """Raise if ##gff-version declares a version other than 3.x."""
    # "##gff-version 3" minimum: 15 bytes; version digit is at index 14
    if len(line) < 15 or line[14] != UInt8(ord("3")):
        raise_parse_error(ctx, Gff3ErrorCode.VERSION.message())


def _parse_sequence_region(
    line: Span[UInt8, _],
    ctx: ParseContext,
) raises -> SequenceRegion:
    """Parse '##sequence-region seqid start end' into SequenceRegion."""
    # prefix "##sequence-region " is 18 bytes
    var prefix_len = 18
    if len(line) <= prefix_len:
        raise_parse_error(ctx, Gff3ErrorCode.SEQ_REGION.message())
    var rest = line[prefix_len:]
    # seqid
    var i: Int = 0
    while i < len(rest) and rest[i] != UInt8(ord(" ")):
        i += 1
    if i == 0:
        raise_parse_error(ctx, "GFF3: ##sequence-region missing seqid")
    var seqid = BString(rest[0:i])
    i += 1  # skip space
    # start
    var j = i
    while j < len(rest) and rest[j] != UInt8(ord(" ")):
        j += 1
    var start: UInt64 = 0
    var sc = _parse_uint64_from_span(rest[i:j], start)
    if sc != Gff3ErrorCode.OK:
        raise_parse_error(ctx, sc.message())
    j += 1  # skip space
    # end — trim trailing whitespace/newline
    var end_span = rest[j:]
    var end_len = len(end_span)
    while end_len > 0 and (
        end_span[end_len - 1] == UInt8(ord("\n"))
        or end_span[end_len - 1] == UInt8(ord("\r"))
        or end_span[end_len - 1] == UInt8(ord(" "))
    ):
        end_len -= 1
    var end: UInt64 = 0
    var ec = _parse_uint64_from_span(end_span[0:end_len], end)
    if ec != Gff3ErrorCode.OK:
        raise_parse_error(ctx, ec.message())
    var region = Interval(Position(start), Position(end))
    return SequenceRegion(seqid=seqid^, region=region)


# ---------------------------------------------------------------------------
# Line policy
# ---------------------------------------------------------------------------


@fieldwise_init
struct Gff3LinePolicy(Copyable, LinePolicy, Movable, TrivialRegisterPassable):
    """GFF3: skip blank and single-# lines; ## lines -> METADATA; ##FASTA -> STOP.
    """

    @always_inline
    def classify(self, line: Span[UInt8, _]) -> LineAction:
        if len(line) == 0:
            return LineAction.SKIP
        if (
            len(line) >= 2
            and line[0] == UInt8(ord("#"))
            and line[1] == UInt8(ord("#"))
        ):
            # ### forward-reference boundary — no payload, skip cleanly
            if len(line) == 3 and line[2] == UInt8(ord("#")):
                return LineAction.SKIP
            if len(line) >= 7:
                if (
                    line[2] == UInt8(ord("F"))
                    and line[3] == UInt8(ord("A"))
                    and line[4] == UInt8(ord("S"))
                    and line[5] == UInt8(ord("T"))
                    and line[6] == UInt8(ord("A"))
                ):
                    return LineAction.STOP
            return LineAction.METADATA
        if line[0] == UInt8(ord("#")):
            return LineAction.SKIP
        return LineAction.YIELD


# ---------------------------------------------------------------------------
# Field parsing helpers
# ---------------------------------------------------------------------------


@always_inline
def _parse_uint64_from_span(
    span: Span[UInt8, _], mut result: UInt64
) -> Gff3ErrorCode:
    """Parse a decimal UInt64. Returns OK or an error code; never raises."""
    result = 0
    if len(span) == 0:
        return Gff3ErrorCode.INT_EMPTY
    for i in range(len(span)):
        var digit = span[i] - 48
        if digit > 9:
            return Gff3ErrorCode.INT_INVALID
        result = result * 10 + digit.cast[DType.uint64]()
    return Gff3ErrorCode.OK


def _parse_score_span(span: Span[UInt8, _]) raises -> Optional[Float64]:
    if len(span) == 0:
        return None
    if len(span) == 1 and span[0] == UInt8(ord(".")):
        return None
    var s = StringSlice(unsafe_from_utf8=span)
    return Optional(atof(s))


def _parse_gff3_strand(
    span: Span[UInt8, _], mut result: Optional[Gff3Strand]
) -> Gff3ErrorCode:
    """Parse GFF3 strand field. Returns OK or STRAND_INVALID; never raises."""
    result = None
    if len(span) == 0:
        return Gff3ErrorCode.OK
    if len(span) == 1:
        var c = span[0]
        if c == UInt8(ord("+")):
            result = Optional(Gff3Strand.Plus)
            return Gff3ErrorCode.OK
        if c == UInt8(ord("-")):
            result = Optional(Gff3Strand.Minus)
            return Gff3ErrorCode.OK
        if c == UInt8(ord(".")):
            result = Optional(Gff3Strand.Unstranded)
            return Gff3ErrorCode.OK
        if c == UInt8(ord("?")):
            result = Optional(Gff3Strand.Unknown)
            return Gff3ErrorCode.OK
    return Gff3ErrorCode.STRAND_INVALID


def _parse_phase_span(
    span: Span[UInt8, _], mut result: Optional[UInt8]
) -> Gff3ErrorCode:
    """Parse GFF3 phase field. Returns OK or an error code; never raises."""
    result = None
    if len(span) == 0:
        return Gff3ErrorCode.OK
    if len(span) == 1 and span[0] == UInt8(ord(".")):
        return Gff3ErrorCode.OK
    var v: UInt64 = 0
    var ic = _parse_uint64_from_span(span, v)
    if ic != Gff3ErrorCode.OK:
        return ic
    if v > 2:
        return Gff3ErrorCode.PHASE_INVALID
    result = Optional(UInt8(v))
    return Gff3ErrorCode.OK


def _parse_gff3_row(
    view: DelimitedView[MutExternalOrigin, 16],
    ctx: ParseContext,
) raises -> Gff3View[MutExternalOrigin]:
    """Parse one 9-field row into Gff3View. Enforces CDS requires phase."""
    if view.num_fields() != GFF_NUM_FIELDS:
        raise_parse_error(ctx, Gff3ErrorCode.FIELD_COUNT.message())
    var seqid = view.get_span(0)
    var source = view.get_span(1)
    var ftype = view.get_span(2)
    var start: UInt64 = 0
    var sc = _parse_uint64_from_span(view.get_span(3), start)
    if sc != Gff3ErrorCode.OK:
        raise_parse_error(ctx, sc.message())
    var end: UInt64 = 0
    var ec = _parse_uint64_from_span(view.get_span(4), end)
    if ec != Gff3ErrorCode.OK:
        raise_parse_error(ctx, ec.message())
    if start > end:
        raise_parse_error(ctx, "GFF3: start must be <= end")
    var score = _parse_score_span(view.get_span(5))
    var strand: Optional[Gff3Strand] = None
    var stc = _parse_gff3_strand(view.get_span(6), strand)
    if stc != Gff3ErrorCode.OK:
        raise_parse_error(ctx, stc.message())
    var phase: Optional[UInt8] = None
    var pc = _parse_phase_span(view.get_span(7), phase)
    if pc != Gff3ErrorCode.OK:
        raise_parse_error(ctx, pc.message())
    # Per GFF3 spec: phase is required for CDS features
    var ftype_str = StringSlice(unsafe_from_utf8=ftype)
    if String(ftype_str) == "CDS" and not phase:
        raise_parse_error(ctx, "GFF3: CDS feature requires phase (0, 1, or 2)")
    var attrs_span = view.get_span(8)
    return Gff3View[MutExternalOrigin](
        _seqid=seqid,
        _source=source,
        _type=ftype,
        start=start,
        end=end,
        score=score,
        strand=strand,
        phase=phase,
        _attributes=attrs_span,
    )


# ---------------------------------------------------------------------------
# Gff3Parser
# ---------------------------------------------------------------------------


struct Gff3Parser[R: Reader](Iterable, Movable):
    """Streaming GFF3 parser. Yields Gff3View / Gff3Record. Stops at ##FASTA.

    Collects ##sequence-region directives into an owned heap list accessible
    via sequence_regions(). Validates ##gff-version is 3.x when present.
    """

    comptime IteratorType[origin: Origin] = _Gff3ParserRecordIter[
        Self.R, origin
    ]

    var _rows: DelimitedReader[Self.R, Gff3LinePolicy, 16]
    var _seq_regions: List[SequenceRegion]

    def __init__(out self, var reader: Self.R) raises:
        self._seq_regions = List[SequenceRegion]()
        self._rows = DelimitedReader[Self.R, Gff3LinePolicy, 16](
            reader^, delimiter=GFF_TAB, has_header=False
        )

    def sequence_regions(ref self) -> List[SequenceRegion]:
        """Return a copy of all ##sequence-region directives encountered so far.
        """
        return self._seq_regions.copy()

    @always_inline
    def has_more(self) -> Bool:
        return self._rows.has_more()

    @always_inline
    def _parse_context(ref self) -> ParseContext:
        return self._rows._parse_context()

    def next_view(mut self) raises -> Gff3View[MutExternalOrigin]:
        while True:
            var line = self._rows.lines.next_line()  # raises EOFError at EOF
            var action = self._rows.policy.classify(line)
            if action == LineAction.YIELD:
                var view = DelimitedView[MutExternalOrigin, 16](line, GFF_TAB)
                var ctx = self._parse_context()
                self._rows._record_number += 1
                return _parse_gff3_row(view, ctx)
            elif action == LineAction.SKIP:
                continue
            elif action == LineAction.METADATA:
                var ctx = ParseContext(0, 0, 0)
                if _starts_with(line, "##gff-version"):
                    _check_gff_version(line, ctx)
                elif _starts_with(line, "##sequence-region"):
                    var region = _parse_sequence_region(line, ctx)
                    self._seq_regions.append(region^)
            else:  # STOP
                raise EOFError()

    def next_record(mut self) raises -> Gff3Record:
        return self.next_view().to_record()

    def views(ref self) -> _Gff3ParserViewIter[Self.R, origin_of(self)]:
        return _Gff3ParserViewIter[Self.R, origin_of(self)](Pointer(to=self))

    def records(ref self) -> _Gff3ParserRecordIter[Self.R, origin_of(self)]:
        return _Gff3ParserRecordIter[Self.R, origin_of(self)](Pointer(to=self))

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.records()


# ---------------------------------------------------------------------------
# Iterators — Gff3Parser
# ---------------------------------------------------------------------------


struct _Gff3ParserViewIter[R: Reader, origin: Origin](Iterator):
    comptime Element = Gff3View[MutExternalOrigin]

    var _src: Pointer[Gff3Parser[Self.R], Self.origin]

    def __init__(out self, src: Pointer[Gff3Parser[Self.R], Self.origin]):
        self._src = src

    def __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    def __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    def __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[Pointer[Gff3Parser[Self.R], MutExternalOrigin]](
            self._src
        )
        try:
            return mut_ptr[].next_view()
        except e:
            var msg = String(e)
            if msg == EOF or msg.startswith(EOF):
                raise StopIteration()
            else:
                print(msg)
                raise StopIteration()


struct _Gff3ParserRecordIter[R: Reader, origin: Origin](Iterator):
    comptime Element = Gff3Record

    var _src: Pointer[Gff3Parser[Self.R], Self.origin]

    def __init__(out self, src: Pointer[Gff3Parser[Self.R], Self.origin]):
        self._src = src

    def __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    def __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    def __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[Pointer[Gff3Parser[Self.R], MutExternalOrigin]](
            self._src
        )
        try:
            return mut_ptr[].next_record()
        except e:
            var msg = String(e)
            if msg == EOF or msg.startswith(EOF):
                raise StopIteration()
            else:
                print(msg)
                raise StopIteration()
