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
from blazeseq.errors import ParseContext, raise_parse_error

comptime BED_TAB: Byte = 9  # ord('\t')


def _is_valid_bed_field_count(n: Int) -> Bool:
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


# ---------------------------------------------------------------------------
# BedErrorCode: format-local trivial enum for hot-path field parsing
# ---------------------------------------------------------------------------


struct BedErrorCode(Copyable, Equatable, TrivialRegisterPassable):
    """Trivial error code returned by low-level BED field parsers; caller raises."""

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
    comptime SCORE_RANGE     = Self(4)
    comptime RGB_FORMAT      = Self(5)
    comptime RGB_RANGE       = Self(6)
    comptime FIELD_COUNT     = Self(7)
    comptime BLOCK_INVALID   = Self(8)

    def message(self) -> String:
        if self == Self.INT_EMPTY:      return "BED: integer field is empty"
        if self == Self.INT_INVALID:    return "BED: invalid byte in integer field"
        if self == Self.STRAND_INVALID: return "BED: strand must be +, -, or ."
        if self == Self.SCORE_RANGE:    return "BED: score must be in [0, 1000]"
        if self == Self.RGB_FORMAT:     return "BED: itemRgb must be 0 or r,g,b"
        if self == Self.RGB_RANGE:      return "BED: itemRgb components must be 0-255"
        if self == Self.FIELD_COUNT:    return "BED: invalid number of fields"
        if self == Self.BLOCK_INVALID:  return "BED: blockCount must be > 0"
        return "BED: parse error"


# ---------------------------------------------------------------------------
# Low-level field parsers — return BedErrorCode, never raise
# ---------------------------------------------------------------------------


@always_inline
def _parse_uint64_from_span(span: Span[UInt8, _], mut result: UInt64) -> BedErrorCode:
    """Parse a decimal UInt64 from a byte span. Returns OK or an error code."""
    result = 0
    if len(span) == 0:
        return BedErrorCode.INT_EMPTY
    for i in range(len(span)):
        var digit = span[i] - 48  # wraps on underflow for non-digit bytes
        if digit > 9:
            return BedErrorCode.INT_INVALID
        result = result * 10 + digit.cast[DType.uint64]()
    return BedErrorCode.OK


@always_inline
def _parse_strand(span: Span[UInt8, _], mut result: Strand) -> BedErrorCode:
    """Parse a single-byte strand field. Returns OK or STRAND_INVALID."""
    result = Strand.Unknown
    if len(span) != 1:
        return BedErrorCode.STRAND_INVALID
    var c = span[0]
    if c == UInt8(ord("+")):
        result = Strand.Plus
        return BedErrorCode.OK
    if c == UInt8(ord("-")):
        result = Strand.Minus
        return BedErrorCode.OK
    if c == UInt8(ord(".")):
        return BedErrorCode.OK
    return BedErrorCode.STRAND_INVALID


@always_inline
def _parse_score(span: Span[UInt8, _], mut result: Int) -> BedErrorCode:
    """Parse a BED score [0, 1000]. Returns OK, INT_EMPTY, INT_INVALID, or SCORE_RANGE."""
    result = 0
    var v: UInt64 = 0
    var code = _parse_uint64_from_span(span, v)
    if code != BedErrorCode.OK:
        return code
    if v > 1000:
        return BedErrorCode.SCORE_RANGE
    result = Int(v)
    return BedErrorCode.OK


def _parse_item_rgb(
    span: Span[UInt8, _],
    ctx: ParseContext,
) raises -> ItemRgb:
    """Parse an itemRgb field. Uses raise_parse_error for rich context on failure."""
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
        raise_parse_error(ctx, BedErrorCode.RGB_FORMAT.message())
    var r = atol(parts[0])
    var g = atol(parts[1])
    var b = atol(parts[2])
    if r < 0 or r > 255 or g < 0 or g > 255 or b < 0 or b > 255:
        raise_parse_error(ctx, BedErrorCode.RGB_RANGE.message())
    return ItemRgb(UInt8(r), UInt8(g), UInt8(b))


# ---------------------------------------------------------------------------
# Parsed-field structs for next_view helpers
# ---------------------------------------------------------------------------


struct _BedRequiredParsed(Movable):
    """Result of parsing required BED fields (chrom, chromStart, chromEnd)."""

    var chrom_span: Span[UInt8, MutExternalOrigin]
    var chrom_start: UInt64
    var chrom_end: UInt64
    var num_fields: Int

    def __init__(
        out self,
        *,
        chrom_span: Span[UInt8, MutExternalOrigin],
        chrom_start: UInt64,
        chrom_end: UInt64,
        num_fields: Int,
    ):
        self.chrom_span = chrom_span
        self.chrom_start = chrom_start
        self.chrom_end = chrom_end
        self.num_fields = num_fields


struct _BedOptionalFields[O: Origin](Movable):
    """Parsed optional BED fields (name through blockStarts)."""

    var name: Optional[Span[UInt8, Self.O]]
    var score: Optional[Int]
    var strand: Optional[Strand]
    var thick_start: Optional[UInt64]
    var thick_end: Optional[UInt64]
    var item_rgb: Optional[ItemRgb]
    var block_count: Optional[Int]
    var block_sizes_span: Optional[Span[UInt8, Self.O]]
    var block_starts_span: Optional[Span[UInt8, Self.O]]

    def __init__(
        out self,
        *,
        name: Optional[Span[UInt8, Self.O]],
        score: Optional[Int],
        strand: Optional[Strand],
        thick_start: Optional[UInt64],
        thick_end: Optional[UInt64],
        item_rgb: Optional[ItemRgb],
        block_count: Optional[Int],
        block_sizes_span: Optional[Span[UInt8, Self.O]],
        block_starts_span: Optional[Span[UInt8, Self.O]],
    ):
        self.name = name
        self.score = score
        self.strand = strand
        self.thick_start = thick_start
        self.thick_end = thick_end
        self.item_rgb = item_rgb
        self.block_count = block_count
        self.block_sizes_span = block_sizes_span
        self.block_starts_span = block_starts_span


# ---------------------------------------------------------------------------
# BedLinePolicy — skip blank and comment lines, yield data rows
# ---------------------------------------------------------------------------


struct BedLinePolicy(Copyable, LinePolicy, Movable, TrivialRegisterPassable):
    """Line policy for BED: skip blank lines and lines starting with #."""

    def __init__(out self):
        pass

    @always_inline
    def classify(self, line: Span[UInt8, _]) -> LineAction:
        if len(line) == 0:
            return LineAction.SKIP
        if line[0] == UInt8(ord("#")):
            return LineAction.SKIP
        return LineAction.YIELD

    @always_inline
    def handle_metadata(mut self, line: Span[UInt8, _]) raises:
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

    def __init__(out self, var reader: Self.R) raises:
        self._rows = DelimitedReader[Self.R, BedLinePolicy, 32](
            reader^, delimiter=BED_TAB, has_header=False
        )

    @always_inline
    def has_more(self) -> Bool:
        return self._rows.has_more()

    @always_inline
    def _parse_context(ref self) -> ParseContext:
        return self._rows._parse_context()

    def _parse_bed_required(
        ref self,
        view: DelimitedView[MutExternalOrigin, 32],
    ) raises -> _BedRequiredParsed:
        """Validate field count and parse required BED fields (chrom, chromStart, chromEnd).
        """
        var ctx = self._parse_context()
        var n = view.num_fields()
        if not _is_valid_bed_field_count(n):
            raise_parse_error(
                ctx,
                "BED row must have 3, 4, 5, 6, 7, 8, 9, or 12 fields"
                " (BED10/BED11 prohibited)",
            )
        var chrom_span = view.get_span(0)
        var chrom_start: UInt64 = 0
        var cs_code = _parse_uint64_from_span(view.get_span(1), chrom_start)
        if cs_code != BedErrorCode.OK:
            raise_parse_error(ctx, cs_code.message())
        var chrom_end: UInt64 = 0
        var ce_code = _parse_uint64_from_span(view.get_span(2), chrom_end)
        if ce_code != BedErrorCode.OK:
            raise_parse_error(ctx, ce_code.message())
        if chrom_start > chrom_end:
            raise_parse_error(ctx, "BED: chromStart must be <= chromEnd")
        return _BedRequiredParsed(
            chrom_span=chrom_span,
            chrom_start=chrom_start,
            chrom_end=chrom_end,
            num_fields=n,
        )

    def _parse_bed_optional_fields(
        ref self,
        view: DelimitedView[MutExternalOrigin, 32],
        n: Int,
    ) raises -> _BedOptionalFields[MutExternalOrigin]:
        """Parse optional BED fields (name, score, strand, thick, itemRgb, blocks) based on n.
        """
        var ctx = self._parse_context()
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
            var score: Int = 0
            var sc_code = _parse_score(view.get_span(4), score)
            if sc_code != BedErrorCode.OK:
                raise_parse_error(ctx, sc_code.message())
            score_opt = score
        if n >= 6:
            var strand: Strand = Strand.Unknown
            var st_code = _parse_strand(view.get_span(5), strand)
            if st_code != BedErrorCode.OK:
                raise_parse_error(ctx, st_code.message())
            strand_opt = strand
        if n >= 7:
            var thick_start: UInt64 = 0
            var ts_code = _parse_uint64_from_span(view.get_span(6), thick_start)
            if ts_code != BedErrorCode.OK:
                raise_parse_error(ctx, ts_code.message())
            thick_start_opt = thick_start
        if n >= 8:
            var thick_end: UInt64 = 0
            var te_code = _parse_uint64_from_span(view.get_span(7), thick_end)
            if te_code != BedErrorCode.OK:
                raise_parse_error(ctx, te_code.message())
            thick_end_opt = thick_end
        if n >= 9:
            item_rgb_opt = _parse_item_rgb(view.get_span(8), ctx)
        if n == 12:
            var bc_raw: UInt64 = 0
            var bc_code = _parse_uint64_from_span(view.get_span(9), bc_raw)
            if bc_code != BedErrorCode.OK:
                raise_parse_error(ctx, bc_code.message())
            var bc = Int(bc_raw)
            if bc < 1:
                raise_parse_error(ctx, BedErrorCode.BLOCK_INVALID.message())
            block_count_opt = bc
            block_sizes_span_opt = view.get_span(10)
            block_starts_span_opt = view.get_span(11)
        return _BedOptionalFields[MutExternalOrigin](
            name=name_opt,
            score=score_opt,
            strand=strand_opt,
            thick_start=thick_start_opt,
            thick_end=thick_end_opt,
            item_rgb=item_rgb_opt,
            block_count=block_count_opt,
            block_sizes_span=block_sizes_span_opt,
            block_starts_span=block_starts_span_opt,
        )

    def next_view(mut self) raises -> BedView[MutExternalOrigin]:
        """Return the next BED record as a zero-alloc view.

        Raises:
            EOFError: When no more records.
            Error: On invalid field count, non-integer coordinates, chromStart > chromEnd,
                   invalid score/strand/itemRgb/block lists.
        """
        if not self.has_more():
            raise EOFError()
        var view = self._rows.next_view()
        var required = self._parse_bed_required(view)
        var optional = self._parse_bed_optional_fields(
            view, required.num_fields
        )
        return BedView[MutExternalOrigin](
            _chrom=required.chrom_span,
            chrom_start=required.chrom_start,
            chrom_end=required.chrom_end,
            _name=optional.name,
            score=optional.score,
            strand=optional.strand,
            thick_start=optional.thick_start,
            thick_end=optional.thick_end,
            _item_rgb=optional.item_rgb,
            block_count=optional.block_count,
            _block_sizes_span=optional.block_sizes_span,
            _block_starts_span=optional.block_starts_span,
            num_fields=required.num_fields,
        )

    def next_record(mut self) raises -> BedRecord:
        """Return the next BED record as an owned BedRecord."""
        return self.next_view().to_record()

    def views(ref self) -> _BedParserViewIter[Self.R, origin_of(self)]:
        """Iterator yielding zero-alloc BedViews."""
        return _BedParserViewIter[Self.R, origin_of(self)](Pointer(to=self))

    def records(ref self) -> _BedParserRecordIter[Self.R, origin_of(self)]:
        """Iterator yielding owned BedRecords."""
        return _BedParserRecordIter[Self.R, origin_of(self)](Pointer(to=self))

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.records()


struct _BedParserViewIter[R: Reader, origin: Origin](Iterator):
    comptime Element = BedView[MutExternalOrigin]

    var _src: Pointer[BedParser[Self.R], Self.origin]

    def __init__(out self, src: Pointer[BedParser[Self.R], Self.origin]):
        self._src = src

    def __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    def __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    def __next__(mut self) raises StopIteration -> Self.Element:
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

    def __init__(out self, src: Pointer[BedParser[Self.R], Self.origin]):
        self._src = src

    def __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    def __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    def __next__(mut self) raises StopIteration -> Self.Element:
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
