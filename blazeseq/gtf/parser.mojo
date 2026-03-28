"""Parser for GTF2.2 files.

GTF is a 9-column tab-delimited format with tag "value" attributes.
Mandatory attributes: gene_id, transcript_id. Comment lines start with #.
Use next_view() / next_record() and views() / records() iterators.
"""

from std.collections import List
from std.collections.string import String, StringSlice
from std.iter import Iterator
from std.memory import Span

from blazeseq.byte_string import BString
from blazeseq.CONSTS import EOF
from blazeseq.features import Position, Interval
from blazeseq.gtf.record import GtfRecord, GtfView, GtfStrand
from blazeseq.io.buffered import EOFError
from blazeseq.io.delimited import (
    DelimitedReader,
    DelimitedView,
    LineAction,
    LinePolicy,
)
from blazeseq.io.readers import Reader
from blazeseq.errors import ParseContext, raise_parse_error

comptime GTF_TAB: Byte = 9  # ord('\t')
comptime GTF_NUM_FIELDS: Int = 9


# ---------------------------------------------------------------------------
# GtfErrorCode: format-local trivial enum for hot-path field parsing
# ---------------------------------------------------------------------------


struct GtfErrorCode(Copyable, Equatable, TrivialRegisterPassable):
    """Trivial error code returned by low-level GTF field parsers; caller raises."""

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

    comptime OK              = Self(0)
    comptime INT_EMPTY       = Self(1)
    comptime INT_INVALID     = Self(2)
    comptime STRAND_INVALID  = Self(3)
    comptime PHASE_INVALID   = Self(4)
    comptime FIELD_COUNT     = Self(5)

    def message(self) -> String:
        if self == Self.INT_EMPTY:      return "GTF: integer field is empty"
        if self == Self.INT_INVALID:    return "GTF: invalid byte in integer field"
        if self == Self.STRAND_INVALID: return "GTF: strand must be +, -, or ."
        if self == Self.PHASE_INVALID:  return "GTF: phase must be 0, 1, or 2"
        if self == Self.FIELD_COUNT:    return "GTF: row must have exactly 9 fields"
        return "GTF: parse error"


# ---------------------------------------------------------------------------
# Line policy
# ---------------------------------------------------------------------------


@fieldwise_init
struct GtfLinePolicy(Copyable, LinePolicy, Movable, TrivialRegisterPassable):
    """GTF: skip blank lines and lines starting with #."""

    @always_inline
    def classify(self, line: Span[UInt8, _]) -> LineAction:
        if len(line) == 0:
            return LineAction.SKIP
        if line[0] == UInt8(ord("#")):
            return LineAction.SKIP
        return LineAction.YIELD


# ---------------------------------------------------------------------------
# Field parsing helpers
# ---------------------------------------------------------------------------


@always_inline
def _parse_uint64_from_span(span: Span[UInt8, _], mut result: UInt64) -> GtfErrorCode:
    """Parse a decimal UInt64. Returns OK or an error code; never raises."""
    result = 0
    if len(span) == 0:
        return GtfErrorCode.INT_EMPTY
    for i in range(len(span)):
        var digit = span[i] - 48
        if digit > 9:
            return GtfErrorCode.INT_INVALID
        result = result * 10 + digit.cast[DType.uint64]()
    return GtfErrorCode.OK


def _parse_score_span(span: Span[UInt8, _]) raises -> Optional[Float64]:
    if len(span) == 0:
        return None
    if len(span) == 1 and span[0] == UInt8(ord(".")):
        return None
    var s = StringSlice(unsafe_from_utf8=span)
    return Optional(atof(s))


def _parse_gtf_strand(span: Span[UInt8, _], mut result: Optional[GtfStrand]) -> GtfErrorCode:
    """Parse GTF strand field. Returns OK or STRAND_INVALID; never raises."""
    result = None
    if len(span) == 0:
        return GtfErrorCode.OK
    if len(span) == 1:
        var c = span[0]
        if c == UInt8(ord("+")):
            result = Optional(GtfStrand.Plus)
            return GtfErrorCode.OK
        if c == UInt8(ord("-")):
            result = Optional(GtfStrand.Minus)
            return GtfErrorCode.OK
        if c == UInt8(ord(".")):
            result = Optional(GtfStrand.Unstranded)
            return GtfErrorCode.OK
    return GtfErrorCode.STRAND_INVALID


def _parse_phase_span(span: Span[UInt8, _], mut result: Optional[UInt8]) -> GtfErrorCode:
    """Parse GTF phase field. Returns OK or an error code; never raises."""
    result = None
    if len(span) == 0:
        return GtfErrorCode.OK
    if len(span) == 1 and span[0] == UInt8(ord(".")):
        return GtfErrorCode.OK
    var v: UInt64 = 0
    var ic = _parse_uint64_from_span(span, v)
    if ic != GtfErrorCode.OK:
        return ic
    if v > 2:
        return GtfErrorCode.PHASE_INVALID
    result = Optional(UInt8(v))
    return GtfErrorCode.OK


def _parse_gtf_row(
    view: DelimitedView[MutExternalOrigin, 16],
    ctx: ParseContext,
) raises -> GtfView[MutExternalOrigin]:
    """Parse one 9-field GTF row into GtfView."""
    if view.num_fields() != GTF_NUM_FIELDS:
        raise_parse_error(ctx, GtfErrorCode.FIELD_COUNT.message())
    var seqid = view.get_span(0)
    var source = view.get_span(1)
    var ftype = view.get_span(2)
    var start: UInt64 = 0
    var sc = _parse_uint64_from_span(view.get_span(3), start)
    if sc != GtfErrorCode.OK:
        raise_parse_error(ctx, sc.message())
    var end: UInt64 = 0
    var ec = _parse_uint64_from_span(view.get_span(4), end)
    if ec != GtfErrorCode.OK:
        raise_parse_error(ctx, ec.message())
    if start > end:
        raise_parse_error(ctx, "GTF: start must be <= end")
    var score = _parse_score_span(view.get_span(5))
    var strand: Optional[GtfStrand] = None
    var stc = _parse_gtf_strand(view.get_span(6), strand)
    if stc != GtfErrorCode.OK:
        raise_parse_error(ctx, stc.message())
    var phase: Optional[UInt8] = None
    var pc = _parse_phase_span(view.get_span(7), phase)
    if pc != GtfErrorCode.OK:
        raise_parse_error(ctx, pc.message())
    var attrs_span = view.get_span(8)
    return GtfView[MutExternalOrigin](
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
# GtfParser
# ---------------------------------------------------------------------------


struct GtfParser[R: Reader](Iterable, Movable):
    """Streaming GTF2.2 parser. Yields GtfView / GtfRecord."""

    comptime IteratorType[origin: Origin] = _GtfParserRecordIter[Self.R, origin]

    var _rows: DelimitedReader[Self.R, GtfLinePolicy, 16]

    def __init__(out self, var reader: Self.R) raises:
        self._rows = DelimitedReader[Self.R, GtfLinePolicy, 16](
            reader^, delimiter=GTF_TAB, has_header=False
        )

    @always_inline
    def has_more(self) -> Bool:
        return self._rows.has_more()

    @always_inline
    def _parse_context(ref self) -> ParseContext:
        return self._rows._parse_context()

    def next_view(mut self) raises -> GtfView[MutExternalOrigin]:
        if not self.has_more():
            raise EOFError()
        var view = self._rows.next_view()
        return _parse_gtf_row(view, self._parse_context())

    def next_record(mut self) raises -> GtfRecord:
        return self.next_view().to_record()

    def views(ref self) -> _GtfParserViewIter[Self.R, origin_of(self)]:
        return _GtfParserViewIter[Self.R, origin_of(self)](Pointer(to=self))

    def records(ref self) -> _GtfParserRecordIter[Self.R, origin_of(self)]:
        return _GtfParserRecordIter[Self.R, origin_of(self)](Pointer(to=self))

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.records()


# ---------------------------------------------------------------------------
# Iterators — GtfParser
# ---------------------------------------------------------------------------


struct _GtfParserViewIter[R: Reader, origin: Origin](Iterator):
    comptime Element = GtfView[MutExternalOrigin]

    var _src: Pointer[GtfParser[Self.R], Self.origin]

    def __init__(out self, src: Pointer[GtfParser[Self.R], Self.origin]):
        self._src = src

    def __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    def __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    def __next__(mut self) raises StopIteration -> Self.Element:
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


struct _GtfParserRecordIter[R: Reader, origin: Origin](Iterator):
    comptime Element = GtfRecord

    var _src: Pointer[GtfParser[Self.R], Self.origin]

    def __init__(out self, src: Pointer[GtfParser[Self.R], Self.origin]):
        self._src = src

    def __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    def __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    def __next__(mut self) raises StopIteration -> Self.Element:
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
