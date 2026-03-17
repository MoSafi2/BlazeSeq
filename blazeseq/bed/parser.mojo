"""Parser for BED (Browser Extensible Data) files.

BED is TAB-delimited with 3 required fields (chrom, chromStart, chromEnd)
and 9 optional fields. Comment lines (start with #) and blank lines are skipped.
Valid column counts: 3, 4, 5, 6, 7, 8, 9, 12 (BED10 and BED11 are prohibited).

Use `next_view()` / `views()` for zero-allocation parsing; the view is
invalidated on the next advance. Call `.to_record()` on a view or use
`next_record()` / `records()` for owned records.
"""

from std.collections import List
from std.collections.string import String, StringSlice
from std.iter import Iterator
from std.memory import Span

from blazeseq.CONSTS import EOF
from blazeseq.bed.record import (
    BedRecord,
    BedView,
    ItemRgb,
    Strand,
)
from blazeseq.io.buffered import EOFError
from blazeseq.io.delimited import (
    DelimitedReader,
    DelimitedView,
    LineAction,
    LinePolicy,
)
from blazeseq.io.readers import Reader
from blazeseq.utils import format_parse_error, ParseContext

comptime BED_TAB: Byte = 9  # ord('\t')
comptime BED_VALID_FIELD_COUNTS: Tuple[
    Int, Int, Int, Int, Int, Int, Int, Int
] = (
    3,
    4,
    5,
    6,
    7,
    8,
    9,
    12,
)


fn _is_valid_bed_field_count(n: Int) -> Bool:
    return (
        n == 3
        or n == 4
        or n == 5
        or n == 6
        or n == 7
        or n == 8
        or n == 9
        or n == 12
    )


fn _parse_uint64_from_span(span: Span[UInt8, _]) raises -> UInt64:
    var s = StringSlice(unsafe_from_utf8=span)
    return UInt64(atol(s))


fn _parse_strand(span: Span[UInt8, _]) raises -> Strand:
    if len(span) != 1:
        raise Error("strand must be one character: +, -, or .")
    var c = span[0]
    if c == UInt8(ord("+")):
        return Strand.Plus
    if c == UInt8(ord("-")):
        return Strand.Minus
    if c == UInt8(ord(".")):
        return Strand.Unknown
    raise Error("strand must be +, -, or .")


fn _parse_score(span: Span[UInt8, _]) raises -> Int:
    var v = _parse_uint64_from_span(span)
    if v < 0 or v > 1000:
        raise Error("score must be in [0, 1000]")
    return Int(v)


fn _parse_item_rgb(span: Span[UInt8, _]) raises -> ItemRgb:
    var s = StringSlice(unsafe_from_utf8=span)
    var trimmed = s.strip()
    if trimmed == "0":
        return ItemRgb(0, 0, 0)
    # Parse r,g,b
    var parts = List[String]()
    var start: Int = 0
    var n = len(span)
    while start < n:
        while start < n and (
            span[start] == UInt8(ord(" ")) or span[start] == UInt8(ord(","))
        ):
            start += 1
        if start >= n:
            break
        var end = start
        while end < n and span[end] != UInt8(ord(",")):
            end += 1
        parts.append(
            String(StringSlice(unsafe_from_utf8=span[start:end]).strip())
        )
        start = end + 1
    if len(parts) != 3:
        raise Error("itemRgb must be 0 or r,g,b")
    var r = Int(atol(parts[0]))
    var g = Int(atol(parts[1]))
    var b = Int(atol(parts[2]))
    if r < 0 or r > 255 or g < 0 or g > 255 or b < 0 or b > 255:
        raise Error("itemRgb components must be 0-255")
    return ItemRgb(UInt8(r), UInt8(g), UInt8(b))


# ---------------------------------------------------------------------------
# BedLinePolicy — skip blank and comment lines, yield data rows
# ---------------------------------------------------------------------------


struct BedLinePolicy(Copyable, LinePolicy, Movable, TrivialRegisterPassable):
    """Line policy for BED: skip blank lines and lines starting with #."""

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


struct BedParser[R: Reader](Iterable, Movable):
    """Streaming BED parser over a Reader.

    Skips comment lines (starting with #) and blank lines.
    API:
        - next_view() -> BedView (zero-alloc; invalidated on next advance)
        - next_record() -> BedRecord (materialized; raises EOFError when exhausted)
        - for rec in parser / records() -> BedRecord
        - for view in parser.views() -> BedView
    """

    comptime IteratorType[origin: Origin] = _BedParserRecordIter[Self.R, origin]

    var _rows: DelimitedReader[Self.R, BedLinePolicy, 32]

    fn __init__(out self, var reader: Self.R) raises:
        self._rows = DelimitedReader[Self.R, BedLinePolicy, 32](
            reader^, delimiter=BED_TAB, has_header=False
        )

    @always_inline
    fn has_more(self) -> Bool:
        return self._rows.has_more()

    @always_inline
    fn _parse_context(ref self) -> ParseContext:
        return self._rows._parse_context()

    fn next_view(mut self) raises -> BedView[MutExternalOrigin]:
        """Return the next BED record as a zero-alloc view.

        Raises:
            EOFError: When no more records.
            Error: On invalid field count, non-integer coordinates, chromStart > chromEnd,
                   invalid score/strand/itemRgb/block lists.
        """
        if not self.has_more():
            raise EOFError()

        var view = self._rows.next_view()
        var n = view.num_fields()

        if not _is_valid_bed_field_count(n):
            var msg = format_parse_error(
                self._parse_context(),
                (
                    "BED row must have 3, 4, 5, 6, 7, 8, 9, or 12 fields"
                    " (BED10/BED11 prohibited)"
                ),
            )
            raise Error(msg)

        var chrom_span = view.get_span(0)
        var chrom_start = _parse_uint64_from_span(view.get_span(1))
        var chrom_end = _parse_uint64_from_span(view.get_span(2))

        if chrom_start > chrom_end:
            var msg = format_parse_error(
                self._parse_context(),
                "chromStart must be <= chromEnd",
            )
            raise Error(msg)

        var name_opt: Optional[Span[UInt8, MutExternalOrigin]] = None
        var score_opt: Optional[Int] = None
        var strand_opt: Optional[Strand] = None
        var thick_start_opt: Optional[UInt64] = None
        var thick_end_opt: Optional[UInt64] = None
        var item_rgb_opt: Optional[ItemRgb] = None
        var block_count_opt: Optional[Int] = None
        var block_sizes_span_opt: Optional[
            Span[UInt8, MutExternalOrigin]
        ] = None
        var block_starts_span_opt: Optional[
            Span[UInt8, MutExternalOrigin]
        ] = None

        if n >= 4:
            name_opt = view.get_span(3)
        if n >= 5:
            try:
                score_opt = _parse_score(view.get_span(4))
            except e:
                var msg = format_parse_error(
                    self._parse_context(),
                    String(e),
                )
                raise Error(msg)
        if n >= 6:
            try:
                strand_opt = _parse_strand(view.get_span(5))
            except e:
                var msg = format_parse_error(
                    self._parse_context(),
                    String(e),
                )
                raise Error(msg)
        if n >= 7:
            thick_start_opt = _parse_uint64_from_span(view.get_span(6))
        if n >= 8:
            thick_end_opt = _parse_uint64_from_span(view.get_span(7))
        if n >= 9:
            try:
                item_rgb_opt = _parse_item_rgb(view.get_span(8))
            except e:
                var msg = format_parse_error(
                    self._parse_context(),
                    String(e),
                )
                raise Error(msg)
        if n == 12:
            block_count_opt = Int(
                UInt64(_parse_uint64_from_span(view.get_span(9)))
            )
            block_sizes_span_opt = view.get_span(10)
            block_starts_span_opt = view.get_span(11)

        return BedView[MutExternalOrigin](
            _chrom=chrom_span,
            _chrom_start=chrom_start,
            _chrom_end=chrom_end,
            _name=name_opt,
            _score=score_opt,
            _strand=strand_opt,
            _thick_start=thick_start_opt,
            _thick_end=thick_end_opt,
            _item_rgb=item_rgb_opt,
            _block_count=block_count_opt,
            _block_sizes_span=block_sizes_span_opt,
            _block_starts_span=block_starts_span_opt,
            _num_fields=n,
        )

    fn next_record(mut self) raises -> BedRecord:
        """Return the next BED record as an owned BedRecord."""
        return self.next_view().to_record()

    fn views(ref self) -> _BedParserViewIter[Self.R, origin_of(self)]:
        """Iterator yielding zero-alloc BedViews."""
        return _BedParserViewIter[Self.R, origin_of(self)](Pointer(to=self))

    fn records(ref self) -> _BedParserRecordIter[Self.R, origin_of(self)]:
        """Iterator yielding owned BedRecords."""
        return _BedParserRecordIter[Self.R, origin_of(self)](Pointer(to=self))

    fn __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.records()


struct _BedParserViewIter[R: Reader, origin: Origin](Iterator):
    comptime Element = BedView[MutExternalOrigin]

    var _src: Pointer[BedParser[Self.R], Self.origin]

    fn __init__(out self, src: Pointer[BedParser[Self.R], Self.origin]):
        self._src = src

    fn __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    fn __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    fn __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[Pointer[BedParser[Self.R], MutExternalOrigin]](
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


struct _BedParserRecordIter[R: Reader, origin: Origin](Iterator):
    comptime Element = BedRecord

    var _src: Pointer[BedParser[Self.R], Self.origin]

    fn __init__(out self, src: Pointer[BedParser[Self.R], Self.origin]):
        self._src = src

    fn __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    fn __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    fn __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[Pointer[BedParser[Self.R], MutExternalOrigin]](
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
