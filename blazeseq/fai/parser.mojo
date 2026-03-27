"""Parser for FASTA/FASTQ .fai index files.

The .fai format is a TAB-delimited text index with 5 columns for FASTA and
6 columns for FASTQ:

    NAME        (string)  – reference sequence name
    LENGTH      (int)     – total length of the reference (bases)
    OFFSET      (int)     – byte offset of first base in the FASTA/FASTQ file
    LINEBASES   (int)     – number of bases per sequence line
    LINEWIDTH   (int)     – number of bytes per sequence line (incl. newline)
    QUALOFFSET  (int)     – (FASTQ only) byte offset of first quality

This parser streams `FaiRecord` entries from a `Reader`, built on top of the
generic `DelimitedReader` (TAB-separated, no header). Use `next_view()`
or `views()` for zero-allocation parsing; the view is invalidated on the next
advance. Call `.to_record()` on a view or use `next_record()` / `records()`
when you need an owned record.
"""


from std.collections import List
from std.collections.string import String, StringSlice
from std.iter import Iterator
from std.memory import Span

from blazeseq.CONSTS import EOF
from blazeseq.fai.record import FaiRecord, FaiView
from blazeseq.io.buffered import EOFError
from blazeseq.io.delimited import DelimitedReader, DelimitedView
from blazeseq.io.readers import Reader
from blazeseq.errors import ParseContext, raise_parse_error


# ---------------------------------------------------------------------------
# FaiErrorCode: format-local trivial enum for hot-path field parsing
# ---------------------------------------------------------------------------


struct FaiErrorCode(Copyable, Equatable, TrivialRegisterPassable):
    """Trivial error code returned by low-level FAI field parsers; caller raises."""

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

    comptime OK          = Self(0)
    comptime INT_EMPTY   = Self(1)
    comptime INT_INVALID = Self(2)
    comptime FIELD_COUNT = Self(3)

    def message(self) -> String:
        if self == Self.INT_EMPTY:   return "FAI: integer field is empty"
        if self == Self.INT_INVALID: return "FAI: invalid byte in integer field"
        if self == Self.FIELD_COUNT: return "FAI: row must have 5 or 6 TAB-delimited columns"
        return "FAI: parse error"


@always_inline
def _parse_int64_from_span(span: Span[UInt8, _], mut result: Int64) -> FaiErrorCode:
    """Parse a decimal Int64 from a byte span. Returns OK or an error code."""
    result = 0
    if len(span) == 0:
        return FaiErrorCode.INT_EMPTY
    for i in range(len(span)):
        var digit = span[i] - 48
        if digit > 9:
            return FaiErrorCode.INT_INVALID
        result = result * 10 + digit.cast[DType.int64]()
    return FaiErrorCode.OK


struct FaiParser[R: Reader](Iterable, Movable):
    """Streaming parser for .fai index files over a `Reader`.

    API:
        - `next_view()` → `FaiView` (zero-alloc; invalidated on next advance)
        - `next_record()` → `FaiRecord` (materialized; raises EOFError when exhausted)
        - `for rec in parser` / `records()` → `FaiRecord` (standard iteration)
        - `for view in parser.views()` → `FaiView` (zero-alloc iteration)
        - `collect()` → `List[FaiRecord]` (helper that reads the whole index)
    """

    # Iterator type alias for `for rec in parser` loops.
    comptime IteratorType[origin: Origin] = _FaiParserRecordIter[Self.R, origin]

    var _rows: DelimitedReader[Self.R]

    def __init__(out self, var reader: Self.R) raises:
        self._rows = DelimitedReader[Self.R](
            reader^, delimiter=9, has_header=False
        )

    # ------------------------------------------------------------------ #
    # Public accessors                                                   #
    # ------------------------------------------------------------------ #

    @always_inline
    def has_more(self) -> Bool:
        return self._rows.has_more()

    @always_inline
    def _parse_context(ref self) -> ParseContext:
        return self._rows._parse_context()

    # ------------------------------------------------------------------ #
    # Record API                                                         #
    # ------------------------------------------------------------------ #

    def next_view(mut self) raises -> FaiView[MutExternalOrigin]:
        """Return the next FAI index row as a zero-alloc `FaiView`.

        The view borrows from the reader's buffer and is invalidated on the
        next call to any advancing method. Call `.to_record()` when you need
        an owned `FaiRecord`.

        Raises:
            EOFError: When no more records are available.
            Error:    On malformed input (wrong column count, non-integer fields).
        """
        if not self.has_more():
            raise EOFError()

        var ctx = self._parse_context()
        var view = self._rows.next_view()
        var n_fields = view.num_fields()
        if n_fields != 5 and n_fields != 6:
            raise_parse_error(ctx, FaiErrorCode.FIELD_COUNT.message())

        var length: Int64 = 0
        var lc = _parse_int64_from_span(view.get_span(1), length)
        if lc != FaiErrorCode.OK:
            raise_parse_error(ctx, lc.message())
        var offset: Int64 = 0
        var oc = _parse_int64_from_span(view.get_span(2), offset)
        if oc != FaiErrorCode.OK:
            raise_parse_error(ctx, oc.message())
        var line_bases: Int64 = 0
        var lbc = _parse_int64_from_span(view.get_span(3), line_bases)
        if lbc != FaiErrorCode.OK:
            raise_parse_error(ctx, lbc.message())
        var line_width: Int64 = 0
        var lwc = _parse_int64_from_span(view.get_span(4), line_width)
        if lwc != FaiErrorCode.OK:
            raise_parse_error(ctx, lwc.message())

        var qual_offset: Optional[Int64] = None
        if n_fields == 6:
            var qo: Int64 = 0
            var qc = _parse_int64_from_span(view.get_span(5), qo)
            if qc != FaiErrorCode.OK:
                raise_parse_error(ctx, qc.message())
            qual_offset = qo

        return FaiView[MutExternalOrigin](
            _name=view.get_span(0),
            _length=length,
            _offset=offset,
            _line_bases=line_bases,
            _line_width=line_width,
            _qual_offset=qual_offset,
        )

    def next_record(mut self) raises -> FaiRecord:
        """Return the next FAI index row as a `FaiRecord`.

        Convenience wrapper around `next_view().to_record()`.

        Raises:
            EOFError: When no more records are available.
            Error:    On malformed input (wrong column count, non-integer fields).
        """
        return self.next_view().to_record()

    def collect(mut self) raises -> List[FaiRecord]:
        """Read all rows from this index into memory."""
        var out = List[FaiRecord]()
        while True:
            try:
                var rec = self.next_record()
                out.append(rec^)
            except e:
                var msg = String(e)
                if msg == EOF or msg.startswith(EOF):
                    break
                raise e^
        return out^

    def views(ref self) -> _FaiParserViewIter[Self.R, origin_of(self)]:
        """Iterator yielding zero-alloc `FaiView`s."""
        return _FaiParserViewIter[Self.R, origin_of(self)](Pointer(to=self))

    def records(ref self) -> _FaiParserRecordIter[Self.R, origin_of(self)]:
        """Iterator yielding owned `FaiRecord`s."""
        return {Pointer(to=self)}

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.records()


struct _FaiParserViewIter[R: Reader, origin: Origin](Iterator):
    """Iterator yielding zero-alloc `FaiView`s."""

    comptime Element = FaiView[MutExternalOrigin]

    var _src: Pointer[FaiParser[Self.R], Self.origin]

    def __init__(out self, src: Pointer[FaiParser[Self.R], Self.origin]):
        self._src = src

    def __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    def __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    def __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[Pointer[FaiParser[Self.R], MutExternalOrigin]](
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


struct _FaiParserRecordIter[R: Reader, origin: Origin](Iterator):
    """Iterator returned by `for rec in parser`."""

    comptime Element = FaiRecord

    var _src: Pointer[FaiParser[Self.R], Self.origin]

    def __init__(
        out self,
        src: Pointer[FaiParser[Self.R], Self.origin],
    ):
        self._src = src

    def __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    def __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    def __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[Pointer[FaiParser[Self.R], MutExternalOrigin]](
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
