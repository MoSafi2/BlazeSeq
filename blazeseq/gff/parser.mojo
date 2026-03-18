"""Parser for GTF and GFF3 files.

Both formats are 9-column tab-delimited. GTF uses tag "value" attributes;
GFF3 uses key=value and supports directives (##) and ##FASTA (stop).
Use next_view() / next_record() and views() / records() as with BED/FAI.
"""

from std.collections import List
from std.collections.string import String, StringSlice
from std.iter import Iterator
from std.memory import Span

from blazeseq.CONSTS import EOF
from blazeseq.gff.record import GffRecord, GffView, GffStrand
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
    """GFF3: skip blank; ## lines -> METADATA; ##FASTA -> STOP."""

    fn __init__(out self):
        pass

    @always_inline
    fn classify(self, line: Span[UInt8, _]) -> LineAction:
        if len(line) == 0:
            return LineAction.SKIP
        if len(line) >= 2 and line[0] == UInt8(ord("#")) and line[1] == UInt8(ord("#")):
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
        ...


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
            return Optional(GffStrand.Unknown)
        if c == UInt8(ord("?")):
            return Optional(GffStrand.Unstranded)
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
    """Streaming GFF3 parser. Yields GffView / GffRecord. Stops at ##FASTA."""

    comptime IteratorType[origin: Origin] = _Gff3ParserRecordIter[Self.R, origin]

    var _rows: DelimitedReader[Self.R, Gff3LinePolicy, 16]

    fn __init__(out self, var reader: Self.R) raises:
        self._rows = DelimitedReader[Self.R, Gff3LinePolicy, 16](
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
