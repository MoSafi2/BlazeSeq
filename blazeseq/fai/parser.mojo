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
generic `DelimitedReader` (TAB-separated, no header). Use `next_record_view()`
or `views()` for zero-allocation parsing; the view is invalidated on the next
advance. Call `.to_record()` on a view or use `next_record()` / `records()`
when you need an owned record.
"""


from std.collections import List
from std.collections.string import String, StringSlice
from std.iter import Iterator
from std.memory import Span

from blazeseq.CONSTS import EOF
from blazeseq.fai.record import FaiRecord, FaiRecordView
from blazeseq.io.buffered import EOFError
from blazeseq.io.delimited import DelimitedReader, DelimitedRecordView
from blazeseq.io.readers import Reader
from blazeseq.utils import format_parse_error


struct FaiParser[R: Reader](Iterable, Movable):
    """Streaming parser for .fai index files over a `Reader`.

    API:
        - `next_record_view()` → `FaiRecordView` (zero-alloc; invalidated on next advance)
        - `next_record()` → `FaiRecord` (materialized; raises EOFError when exhausted)
        - `for rec in parser` / `records()` → `FaiRecord` (standard iteration)
        - `for view in parser.views()` → `FaiRecordView` (zero-alloc iteration)
        - `collect()` → `List[FaiRecord]` (helper that reads the whole index)
    """

    # Iterator type alias for `for rec in parser` loops.
    comptime IteratorType[origin: Origin] = _FaiParserRecordIter[Self.R, origin]

    var _rows: DelimitedReader[Self.R]

    fn __init__(out self, var reader: Self.R) raises:
        self._rows = DelimitedReader[Self.R](
            reader^, delimiter=9, has_header=False
        )

    # ------------------------------------------------------------------ #
    # Public accessors                                                   #
    # ------------------------------------------------------------------ #

    @always_inline
    fn has_more(self) -> Bool:
        return self._rows.has_more()

    @always_inline
    fn _get_record_number(ref self) -> Int:
        return self._rows._get_record_number()

    @always_inline
    fn _get_line_number(ref self) -> Int:
        return self._rows._get_line_number()

    @always_inline
    fn _get_file_position(ref self) -> Int64:
        return self._rows._get_file_position()

    # ------------------------------------------------------------------ #
    # Record API                                                         #
    # ------------------------------------------------------------------ #

    fn next_record_view(mut self) raises -> FaiRecordView[MutExternalOrigin]:
        """Return the next FAI index row as a zero-alloc `FaiRecordView`.

        The view borrows from the reader's buffer and is invalidated on the
        next call to any advancing method. Call `.to_record()` when you need
        an owned `FaiRecord`.

        Raises:
            EOFError: When no more records are available.
            Error:    On malformed input (wrong column count, non-integer fields).
        """
        if not self.has_more():
            raise EOFError()

        var view = self._rows.next_record_view()
        var n_fields = view.num_fields()
        if n_fields != 5 and n_fields != 6:
            var msg = format_parse_error(
                "FAI row must have 5 or 6 TAB-delimited columns",
                self._get_record_number() + 1,
                self._get_line_number(),
                self._get_file_position(),
                "",
            )
            raise Error(msg)

        fn _parse_int64_from_span(span: Span[UInt8, _]) raises -> Int64:
            var s = StringSlice(unsafe_from_utf8=span)
            return Int64(atol(s))

        var length = _parse_int64_from_span(view.get_span(1))
        var offset = _parse_int64_from_span(view.get_span(2))
        var line_bases = _parse_int64_from_span(view.get_span(3))
        var line_width = _parse_int64_from_span(view.get_span(4))

        var qual_offset: Optional[Int64] = None
        if n_fields == 6:
            qual_offset = _parse_int64_from_span(view.get_span(5))

        return FaiRecordView[MutExternalOrigin](
            _name=view.get_span(0),
            _length=length,
            _offset=offset,
            _line_bases=line_bases,
            _line_width=line_width,
            _qual_offset=qual_offset,
        )

    fn next_record(mut self) raises -> FaiRecord:
        """Return the next FAI index row as a `FaiRecord`.

        Convenience wrapper around `next_record_view().to_record()`.

        Raises:
            EOFError: When no more records are available.
            Error:    On malformed input (wrong column count, non-integer fields).
        """
        return self.next_record_view().to_record()

    fn collect(mut self) raises -> List[FaiRecord]:
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

    fn views(ref self) -> _FaiParserViewIter[Self.R, origin_of(self)]:
        """Iterator yielding zero-alloc `FaiRecordView`s."""
        return _FaiParserViewIter[Self.R, origin_of(self)](Pointer(to=self))

    fn records(ref self) -> _FaiParserRecordIter[Self.R, origin_of(self)]:
        """Iterator yielding owned `FaiRecord`s."""
        return {Pointer(to=self)}

    fn __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.records()


struct _FaiParserViewIter[R: Reader, origin: Origin](Iterator):
    """Iterator yielding zero-alloc `FaiRecordView`s."""

    comptime Element = FaiRecordView[MutExternalOrigin]

    var _src: Pointer[FaiParser[Self.R], Self.origin]

    fn __init__(out self, src: Pointer[FaiParser[Self.R], Self.origin]):
        self._src = src

    fn __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    fn __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    fn __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[Pointer[FaiParser[Self.R], MutExternalOrigin]](
            self._src
        )
        try:
            return mut_ptr[].next_record_view()
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

    fn __init__(
        out self,
        src: Pointer[FaiParser[Self.R], Self.origin],
    ):
        self._src = src

    fn __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    fn __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    fn __next__(mut self) raises StopIteration -> Self.Element:
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
