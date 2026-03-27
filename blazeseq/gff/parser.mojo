"""Parser for GTF and GFF3 files.

Both formats are 9-column tab-delimited. GTF uses tag "value" attributes;
GFF3 uses key=value and supports directives (##) and ##FASTA (stop).
Use next_view() / next_record() and views() / records() as with BED/FAI.
"""

from std.collections import List
from std.collections.string import String, StringSlice
from std.iter import Iterator
from std.memory import Span, UnsafePointer, alloc

from blazeseq.byte_string import BString
from blazeseq.CONSTS import EOF
from blazeseq.features import Position, Interval
from blazeseq.gff.record import GffRecord, GffView, GffStrand, SequenceRegion
from blazeseq.io.buffered import EOFError
from blazeseq.io.delimited import (
    DelimitedReader,
    DelimitedView,
    LineAction,
    LinePolicy,
)
from blazeseq.io.readers import Reader
from blazeseq.utils import format_parse_error, ParseContext

comptime GFF_TAB: Byte = 9  # ord('\t')
comptime GFF_NUM_FIELDS: Int = 9


# ---------------------------------------------------------------------------
# Directive helper functions
# ---------------------------------------------------------------------------


fn _starts_with(span: Span[UInt8, _], lit: StringLiteral) -> Bool:
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


fn _check_gff_version(line: Span[UInt8, _]) raises:
    """Raise if ##gff-version declares a version other than 3.x."""
    # "##gff-version 3" minimum: 15 bytes; version digit is at index 14
    if len(line) < 15 or line[14] != UInt8(ord("3")):
        raise Error("GFF3: ##gff-version must be 3.x")


fn _parse_sequence_region(
    line: Span[UInt8, _],
    ctx: ParseContext,
) raises -> SequenceRegion:
    """Parse '##sequence-region seqid start end' into SequenceRegion."""
    # prefix "##sequence-region " is 18 bytes
    var prefix_len = 18
    if len(line) <= prefix_len:
        var msg = format_parse_error(ctx, "GFF3: malformed ##sequence-region directive")
        raise Error(msg)
    var rest = line[prefix_len:]
    # seqid
    var i: Int = 0
    while i < len(rest) and rest[i] != UInt8(ord(" ")):
        i += 1
    if i == 0:
        var msg = format_parse_error(ctx, "GFF3: ##sequence-region missing seqid")
        raise Error(msg)
    var seqid = BString(rest[0:i])
    i += 1  # skip space
    # start
    var j = i
    while j < len(rest) and rest[j] != UInt8(ord(" ")):
        j += 1
    var start = _parse_uint64_from_span(rest[i:j])
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
    var end = _parse_uint64_from_span(end_span[0:end_len])
    var region = Interval(Position(start), Position(end))
    return SequenceRegion(seqid=seqid^, region=region)


# ---------------------------------------------------------------------------
# Line policies
# ---------------------------------------------------------------------------


struct GffGtfLinePolicy(Copyable, LinePolicy, Movable, TrivialRegisterPassable):
    """GTF/GFF2: skip blank lines and lines starting with #."""

    fn __init__(out self):
        pass

    @always_inline
    fn classify(self, line: Span[UInt8, _]) -> LineAction:
        if len(line) == 0:
            return LineAction.SKIP
        if line[0] == UInt8(ord("#")):
            return LineAction.SKIP
        return LineAction.YIELD

    @always_inline
    fn handle_metadata(mut self, line: Span[UInt8, _]) raises:
        ...


struct Gff3LinePolicy(Copyable, LinePolicy, Movable, TrivialRegisterPassable):
    """GFF3: skip blank; ## lines -> METADATA; ##FASTA -> STOP.

    Stateful: collects ##sequence-region directives via a pointer to a
    List[SequenceRegion] owned by Gff3Parser. Validates ##gff-version is 3.x.
    Both fields are trivially passable (Bool + UnsafePointer).
    """

    var _seen_version: Bool
    var _regions_ptr: UnsafePointer[List[SequenceRegion], MutAnyOrigin]

    fn __init__(out self):
        self._seen_version = False
        self._regions_ptr = UnsafePointer[List[SequenceRegion], MutAnyOrigin]()

    @always_inline
    fn classify(self, line: Span[UInt8, _]) -> LineAction:
        if len(line) == 0:
            return LineAction.SKIP
        if len(line) >= 2 and line[0] == UInt8(ord("#")) and line[1] == UInt8(ord("#")):
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

    @always_inline
    fn handle_metadata(mut self, line: Span[UInt8, _]) raises:
        if _starts_with(line, "##gff-version"):
            _check_gff_version(line)
            self._seen_version = True
        elif _starts_with(line, "##sequence-region"):
            if self._regions_ptr:
                var ctx = ParseContext(0, 0, 0)
                var region = _parse_sequence_region(line, ctx)
                self._regions_ptr[].append(region^)


# ---------------------------------------------------------------------------
# Shared field parsing
# ---------------------------------------------------------------------------


fn _parse_uint64_from_span(span: Span[UInt8, _]) raises -> UInt64:
    var result: UInt64 = 0
    var n = len(span)
    if n == 0:
        raise Error("GFF: empty integer field")
    for i in range(n):
        var digit = span[i] - 48
        if digit > 9:
            raise Error("GFF: invalid integer " + chr(Int(span[i])))
        result = result * 10 + digit.cast[DType.uint64]()
    return result


fn _parse_score_span(span: Span[UInt8, _]) raises -> Optional[Float64]:
    if len(span) == 0:
        return None
    if len(span) == 1 and span[0] == UInt8(ord(".")):
        return None
    var s = StringSlice(unsafe_from_utf8=span)
    return Optional(atof(s))


fn _parse_gff_strand(span: Span[UInt8, _]) raises -> Optional[GffStrand]:
    if len(span) == 0:
        return None
    if len(span) == 1:
        var c = span[0]
        if c == UInt8(ord("+")):
            return Optional(GffStrand.Plus)
        if c == UInt8(ord("-")):
            return Optional(GffStrand.Minus)
        if c == UInt8(ord(".")):
            return Optional(GffStrand.Unstranded)
        if c == UInt8(ord("?")):
            return Optional(GffStrand.Unknown)
    raise Error("GFF: strand must be +, -, ., or ?")


fn _parse_phase_span(span: Span[UInt8, _]) raises -> Optional[UInt8]:
    if len(span) == 0:
        return None
    if len(span) == 1 and span[0] == UInt8(ord(".")):
        return None
    var v = _parse_uint64_from_span(span)
    if v > 2:
        raise Error("GFF: phase must be 0, 1, or 2")
    return Optional(UInt8(v))


fn _parse_gff_row(
    view: DelimitedView[MutExternalOrigin, 16],
    ctx: ParseContext,
    format_gtf: Bool,
) raises -> GffView[MutExternalOrigin]:
    """Parse one 9-field row into GffView."""
    if view.num_fields() != GFF_NUM_FIELDS:
        var msg = format_parse_error(
            ctx,
            "GFF row must have exactly 9 fields",
            "",
            1,
        )
        raise Error(msg)
    var seqid = view.get_span(0)
    var source = view.get_span(1)
    var ftype = view.get_span(2)
    var start = _parse_uint64_from_span(view.get_span(3))
    var end = _parse_uint64_from_span(view.get_span(4))
    if start > end:
        var msg = format_parse_error(ctx, "GFF start must be <= end")
        raise Error(msg)
    var score = _parse_score_span(view.get_span(5))
    var strand = _parse_gff_strand(view.get_span(6))
    var phase = _parse_phase_span(view.get_span(7))
    # Per GFF3 spec: phase is required for CDS features
    if not format_gtf:
        var ftype_str = StringSlice(unsafe_from_utf8=ftype)
        if String(ftype_str) == "CDS" and not phase:
            var msg = format_parse_error(ctx, "GFF3: CDS feature requires phase (0, 1, or 2)")
            raise Error(msg)
    var attrs_span = view.get_span(8)
    return GffView[MutExternalOrigin](
        _seqid=seqid,
        _source=source,
        _type=ftype,
        start=start,
        end=end,
        score=score,
        strand=strand,
        phase=phase,
        _attributes=attrs_span,
        _format_gtf=format_gtf,
    )


# ---------------------------------------------------------------------------
# GtfParser
# ---------------------------------------------------------------------------


struct GtfParser[R: Reader](Iterable, Movable):
    """Streaming GTF parser. Yields GffView / GffRecord."""

    comptime IteratorType[origin: Origin] = _GffParserRecordIter[Self.R, origin]

    var _rows: DelimitedReader[Self.R, GffGtfLinePolicy, 16]

    fn __init__(out self, var reader: Self.R) raises:
        self._rows = DelimitedReader[Self.R, GffGtfLinePolicy, 16](
            reader^, delimiter=GFF_TAB, has_header=False
        )

    @always_inline
    fn has_more(self) -> Bool:
        return self._rows.has_more()

    @always_inline
    fn _parse_context(ref self) -> ParseContext:
        return self._rows._parse_context()

    fn next_view(mut self) raises -> GffView[MutExternalOrigin]:
        if not self.has_more():
            raise EOFError()
        var view = self._rows.next_view()
        return _parse_gff_row(view, self._parse_context(), True)

    fn next_record(mut self) raises -> GffRecord:
        return self.next_view().to_record()

    fn views(ref self) -> _GffParserViewIter[Self.R, origin_of(self)]:
        return _GffParserViewIter[Self.R, origin_of(self)](Pointer(to=self))

    fn records(ref self) -> _GffParserRecordIter[Self.R, origin_of(self)]:
        return _GffParserRecordIter[Self.R, origin_of(self)](Pointer(to=self))

    fn __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.records()


# ---------------------------------------------------------------------------
# Gff3Parser
# ---------------------------------------------------------------------------


struct Gff3Parser[R: Reader](Iterable, Movable):
    """Streaming GFF3 parser. Yields GffView / GffRecord. Stops at ##FASTA.

    Collects ##sequence-region directives into an owned heap list accessible
    via sequence_regions(). Validates ##gff-version is 3.x when present.
    """

    comptime IteratorType[origin: Origin] = _Gff3ParserRecordIter[Self.R, origin]

    var _rows: DelimitedReader[Self.R, Gff3LinePolicy, 16]
    var _seq_regions: UnsafePointer[List[SequenceRegion], MutAnyOrigin]

    fn __init__(out self, var reader: Self.R) raises:
        # Allocate the sequence-region list on the heap so the pointer inside
        # the policy remains stable even if Gff3Parser is moved.
        self._seq_regions = alloc[List[SequenceRegion]](1)
        self._seq_regions[0] = List[SequenceRegion]()
        self._rows = DelimitedReader[Self.R, Gff3LinePolicy, 16](
            reader^, delimiter=GFF_TAB, has_header=False
        )
        # Link the policy to our owned list after construction.
        self._rows.policy._regions_ptr = self._seq_regions

    fn __del__(deinit self):
        self._seq_regions.destroy_pointee()
        self._seq_regions.free()

    fn sequence_regions(ref self) -> List[SequenceRegion]:
        """Return a copy of all ##sequence-region directives encountered so far."""
        var result = List[SequenceRegion]()
        var src = self._seq_regions
        for i in range(len(src[])):
            result.append(SequenceRegion(src[i].copy()))
        return result^

    @always_inline
    fn has_more(self) -> Bool:
        return self._rows.has_more()

    @always_inline
    fn _parse_context(ref self) -> ParseContext:
        return self._rows._parse_context()

    fn next_view(mut self) raises -> GffView[MutExternalOrigin]:
        if not self.has_more():
            raise EOFError()
        var view = self._rows.next_view()
        return _parse_gff_row(view, self._parse_context(), False)

    fn next_record(mut self) raises -> GffRecord:
        return self.next_view().to_record()

    fn views(ref self) -> _Gff3ParserViewIter[Self.R, origin_of(self)]:
        return _Gff3ParserViewIter[Self.R, origin_of(self)](Pointer(to=self))

    fn records(ref self) -> _Gff3ParserRecordIter[Self.R, origin_of(self)]:
        return _Gff3ParserRecordIter[Self.R, origin_of(self)](Pointer(to=self))

    fn __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.records()


# ---------------------------------------------------------------------------
# Iterators — GtfParser
# ---------------------------------------------------------------------------


struct _GffParserViewIter[R: Reader, origin: Origin](Iterator):
    comptime Element = GffView[MutExternalOrigin]

    var _src: Pointer[GtfParser[Self.R], Self.origin]

    fn __init__(out self, src: Pointer[GtfParser[Self.R], Self.origin]):
        self._src = src

    fn __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    fn __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    fn __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[Pointer[GtfParser[Self.R], MutExternalOrigin]](self._src)
        try:
            return mut_ptr[].next_view()
        except e:
            var msg = String(e)
            if msg == EOF or msg.startswith(EOF):
                raise StopIteration()
            else:
                print(msg)
                raise StopIteration()


struct _GffParserRecordIter[R: Reader, origin: Origin](Iterator):
    comptime Element = GffRecord

    var _src: Pointer[GtfParser[Self.R], Self.origin]

    fn __init__(out self, src: Pointer[GtfParser[Self.R], Self.origin]):
        self._src = src

    fn __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    fn __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    fn __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[Pointer[GtfParser[Self.R], MutExternalOrigin]](self._src)
        try:
            return mut_ptr[].next_record()
        except e:
            var msg = String(e)
            if msg == EOF or msg.startswith(EOF):
                raise StopIteration()
            else:
                print(msg)
                raise StopIteration()


# ---------------------------------------------------------------------------
# Iterators — Gff3Parser
# ---------------------------------------------------------------------------


struct _Gff3ParserViewIter[R: Reader, origin: Origin](Iterator):
    comptime Element = GffView[MutExternalOrigin]

    var _src: Pointer[Gff3Parser[Self.R], Self.origin]

    fn __init__(out self, src: Pointer[Gff3Parser[Self.R], Self.origin]):
        self._src = src

    fn __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    fn __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    fn __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[Pointer[Gff3Parser[Self.R], MutExternalOrigin]](self._src)
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
    comptime Element = GffRecord

    var _src: Pointer[Gff3Parser[Self.R], Self.origin]

    fn __init__(out self, src: Pointer[Gff3Parser[Self.R], Self.origin]):
        self._src = src

    fn __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    fn __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    fn __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[Pointer[Gff3Parser[Self.R], MutExternalOrigin]](self._src)
        try:
            return mut_ptr[].next_record()
        except e:
            var msg = String(e)
            if msg == EOF or msg.startswith(EOF):
                raise StopIteration()
            else:
                print(msg)
                raise StopIteration()
