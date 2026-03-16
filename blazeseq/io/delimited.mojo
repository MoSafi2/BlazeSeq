from std.collections import List
from std.collections.string import String
from std.memory import Span
from std.iter import Iterator
from std.collections import InlineArray

from blazeseq.byte_string import BString
from blazeseq.CONSTS import EOF
from blazeseq.io.buffered import EOFError, LineIterator
from blazeseq.io.readers import Reader
from blazeseq.utils import memchr, format_parse_error


# ---------------------------------------------------------------------------
# FieldOffsets — stack-allocated field boundary table
# ---------------------------------------------------------------------------


struct FieldOffsets[MAX: Int = 64](Copyable, Movable, Sized):
    """Stack-allocated flat array of (start, end) byte pairs for up to MAX fields.

    Layout: [start0, end0, start1, end1, …]  — avoids a separate count field
    at the cost of doubling the index arithmetic, which is branch-free.
    """

    var _data: InlineArray[Int, Self.MAX * 2]
    var _num_fields: Int

    @always_inline
    fn __init__(out self):
        self._data = InlineArray[Int, self.MAX * 2](fill=0)
        self._num_fields = 0

    @always_inline
    fn __len__(self) -> Int:
        return self._num_fields

    @always_inline
    fn start(self, i: Int) -> Int:
        return self._data[i * 2]

    @always_inline
    fn end(self, i: Int) -> Int:
        return self._data[i * 2 + 1]

    @always_inline
    fn _push(mut self, start: Int, end: Int):
        if self._num_fields < Self.MAX:
            self._data[self._num_fields * 2] = start
            self._data[self._num_fields * 2 + 1] = end
            self._num_fields += 1


# ---------------------------------------------------------------------------
# _fill_offsets — shared parse kernel (no allocation)
# ---------------------------------------------------------------------------


@always_inline
fn _fill_offsets[
    O: Origin, MAX: Int
](line: Span[Byte, O], delimiter: Byte, mut offsets: FieldOffsets[MAX]):
    """Scan `line` for `delimiter` and write field boundaries into `offsets`.

    Zero allocations. Works over any span origin — the caller owns the buffer.
    Handles trailing delimiters (appends one empty final field).
    """
    offsets._num_fields = 0
    var n = len(line)
    var start = 0

    while start <= n:
        var idx = memchr(line, delimiter, start)
        var end = idx if idx != -1 else n
        offsets._push(start, end)
        if idx == -1:
            break
        start = idx + 1

    # Trailing delimiter -> one extra empty field.
    if n > 0 and line[n - 1] == delimiter:
        offsets._push(n, n)


# ---------------------------------------------------------------------------
# DelimitedRecordView — zero-alloc, NOT thread-safe, NOT to be stored
# ---------------------------------------------------------------------------


struct DelimitedRecordView[
    O: Origin,
    MAX: Int = 64,
](Movable, Sized, Writable):
    """A non-owning view over one delimited row.

    Holds a `Span` into the *reader's internal buffer* and a stack-allocated
    `FieldOffsets`. No heap allocation is made.

    **Lifetime contract**: the view is invalidated the moment `LineIterator`
    advances (i.e. on the next `next_line()` call or any buffer compaction).
    Never store a `DelimitedRecordView`; call `.to_record()` if you need
    the record to outlive the current iteration step.

    Not thread-safe — the backing span is a raw pointer into the reader buffer.
    """

    var _line: Span[UInt8, Self.O]
    var _offsets: FieldOffsets[Self.MAX]
    var _delimiter: Byte

    @always_inline
    fn __init__(out self, line: Span[UInt8, Self.O], delimiter: UInt8):
        self._line = line
        self._offsets = FieldOffsets[Self.MAX]()
        _fill_offsets(line, delimiter, self._offsets)
        self._delimiter = delimiter

    @always_inline
    fn num_fields(self) -> Int:
        return len(self._offsets)

    @always_inline
    fn __len__(self) -> Int:
        return len(self._offsets)

    @always_inline
    fn get_span(self, idx: Int) -> Span[UInt8, Self.O]:
        """Zero-copy view of field `idx`. Same lifetime as this view."""
        return self._line[self._offsets.start(idx) : self._offsets.end(idx)]

    @always_inline
    fn get(self, idx: Int) -> Optional[Span[UInt8, Self.O]]:
        if idx < 0 or idx >= len(self._offsets):
            return None
        return self.get_span(idx)

    @always_inline
    fn to_record(deinit self) -> DelimitedRecord[Self.MAX]:
        """Copy the backing bytes and offsets into an owned `DelimitedRecord`.

        One `BString` allocation; offsets are copied by value (stack to stack).
        Call this when the record must outlive the current iteration step.
        """
        return DelimitedRecord[Self.MAX](self^)

    fn write_to[w: Writer](self, mut writer: w):
        for i in range(len(self._offsets)):
            if i > 0:
                writer.write(self._delimiter)
            writer.write(String(self.get_span(i)))


# ---------------------------------------------------------------------------
# DelimitedRecord — owned, storeable, sendable
# ---------------------------------------------------------------------------


struct DelimitedRecord[MAX: Int = 64](Copyable, Movable, Sized, Writable):
    """An owned, heap-allocated delimited row.

    Created either directly (when ownership is needed from the start) or via
    `DelimitedRecordView.to_record()`. Holds exactly one `BString` (the raw
    line bytes) and a stack-allocated `FieldOffsets`.

    Field access via `get_span()` is zero-copy into the owned `BString`.
    """

    var _line: BString
    var _offsets: FieldOffsets[Self.MAX]

    @always_inline
    fn __init__(out self):
        self._line = BString()
        self._offsets = FieldOffsets[Self.MAX]()

    @always_inline
    fn __init__(out self, var view: DelimitedRecordView[_, Self.MAX]):
        """Materialize from a view — one `BString` alloc, offsets copied by value.
        """
        # TODO: use Move instead of a copy, Lifetime Issue here
        self._line = BString(view._line)
        self._offsets = view._offsets.copy()

    @always_inline
    fn num_fields(self) -> Int:
        return len(self._offsets)

    @always_inline
    fn __len__(self) -> Int:
        return len(self._offsets)

    @always_inline
    fn get_span(ref self, idx: Int) -> Span[UInt8, origin_of(self._line)]:
        """Zero-copy view of field `idx`. Lifetime tied to this record."""
        return self._line.as_span()[
            self._offsets.start(idx) : self._offsets.end(idx)
        ]

    @always_inline
    fn __getitem__(ref self, idx: Int) -> BString:
        """Owned copy of field `idx`. Prefer `get_span()` in hot paths."""
        return BString(self.get_span(idx))

    fn get(ref self, idx: Int) -> Optional[BString]:
        if idx < 0 or idx >= len(self._offsets):
            return None
        return BString(self.get_span(idx))

    fn write_to[w: Writer](ref self, mut writer: w):
        for i in range(len(self._offsets)):
            if i > 0:
                writer.write("\t")
            writer.write(String(self.get_span(i)))


# ---------------------------------------------------------------------------
# DelimitedReader
# ---------------------------------------------------------------------------


struct DelimitedReader[R: Reader, MAX: Int = 64](Movable):
    """Generic delimited-file reader over a `Reader`.

    Supports TSV, CSV, FAI, and similar formats.

    The hot path — `next_record_view()` / `for view in dr.views()` — yields a
    `DelimitedRecordView` with **zero heap allocations** per row: the span
    lives in the reader's internal buffer and the offsets are stack-allocated.

    Call `.materialize()` on the view when you need the record to outlive the
    current iteration step; `next_record()` / `for record in dr.records()` do
    this automatically (one `BString` alloc per row).

    `for view in dr` (i.e. `__iter__`) defaults to the zero-alloc view path.

    Example — filter without allocating on every row:
        ```
        var dr = DelimitedReader[FileReader](reader^, has_header=True)
        var results = List[DelimitedRecord]()
        for view in dr.views():
            if String(view.get_span(2)) == "homo_sapiens":
                results.append(view.materialize())  # alloc only on match
        ```
    """

    var lines: LineIterator[Self.R]
    var _delimiter: UInt8
    var _record_number: Int
    var _has_header: Bool
    var _header: Optional[DelimitedRecord[Self.MAX]]
    var _expected_num_fields: Int

    fn __init__(
        out self,
        var reader: Self.R,
        delimiter: UInt8 = 9,  # ord("\t")
        has_header: Bool = False,
    ) raises:
        self.lines = LineIterator(reader^)
        self._delimiter = delimiter
        self._record_number = 0
        self._has_header = has_header
        self._header = None
        self._expected_num_fields = 0

        if self._has_header and self.lines.has_more():
            # Header must survive the whole session, so always materialize.
            var line = self._next_nonempty_line()
            self._header = DelimitedRecordView[MutExternalOrigin, Self.MAX](
                line, self._delimiter
            ).to_record()

    @always_inline
    fn has_more(self) -> Bool:
        return self.lines.has_more()

    @always_inline
    fn get_record_number(ref self) -> Int:
        return self._record_number

    @always_inline
    fn get_line_number(ref self) -> Int:
        return self.lines.get_line_number()

    @always_inline
    fn get_file_position(ref self) -> Int64:
        return self.lines.get_file_position()

    fn header(ref self) -> Optional[DelimitedRecord[Self.MAX]]:
        """Copy of the stored header record, if present."""
        return self._header.copy()

    # ------------------------------------------------------------------
    # Hot path: zero-alloc view
    # ------------------------------------------------------------------

    fn next_record_view(
        mut self,
    ) raises -> DelimitedRecordView[MutExternalOrigin, Self.MAX]:
        """Return the next row as a zero-alloc `DelimitedRecordView`.

        The view borrows from the reader's internal line buffer and is
        invalidated on the next call to any advancing method. Call
        `.materialize()` to obtain an owned `DelimitedRecord`.

        Raises `EOFError` when no more records are available.
        """
        if not self.has_more():
            raise EOFError()

        var line = self._next_nonempty_line()
        var view = DelimitedRecordView[MutExternalOrigin, Self.MAX](
            line, self._delimiter
        )
        self._check_field_count(view.num_fields())
        self._record_number += 1
        return view^

    # ------------------------------------------------------------------
    # Convenience: owned record (one BString alloc per row)
    # ------------------------------------------------------------------

    fn next_record(mut self) raises -> DelimitedRecord[Self.MAX]:
        """Return the next row as an owned `DelimitedRecord`.

        Convenience wrapper around `next_record_view().materialize()`.
        Raises `EOFError` when no more records are available.
        """
        return self.next_record_view().to_record()

    # ------------------------------------------------------------------
    # Iterators
    # ------------------------------------------------------------------

    fn views(
        ref self,
    ) -> _DelimitedViewIter[Self.R, Self.MAX, origin_of(self)]:
        """Iterator yielding zero-alloc `DelimitedRecordView`s."""
        return _DelimitedViewIter[Self.R, Self.MAX, origin_of(self)](
            Pointer(to=self)
        )

    fn records(
        ref self,
    ) -> _DelimitedRecordIter[Self.R, Self.MAX, origin_of(self)]:
        """Iterator yielding owned `DelimitedRecord`s."""
        return _DelimitedRecordIter[Self.R, Self.MAX, origin_of(self)](
            Pointer(to=self)
        )

    fn __iter__(
        ref self,
    ) -> _DelimitedViewIter[Self.R, Self.MAX, origin_of(self)]:
        """Default iteration yields zero-alloc views."""
        return self.views()

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    @always_inline
    fn _next_nonempty_line(
        mut self,
    ) raises -> Span[UInt8, MutExternalOrigin]:
        while True:
            var line = self.lines.next_line()  # raises EOFError at end-of-file
            if len(line) > 0:
                return line

    @always_inline
    fn _check_field_count(mut self, n: Int) raises:
        if self._expected_num_fields == 0:
            self._expected_num_fields = n
        elif n != self._expected_num_fields:
            raise Error(
                format_parse_error(
                    "Delimited row has inconsistent number of fields",
                    self._record_number + 1,
                    self.get_line_number(),
                    self.get_file_position(),
                    "",
                )
            )


# ---------------------------------------------------------------------------
# Iterator — views (zero-alloc)
# ---------------------------------------------------------------------------


struct _DelimitedViewIter[
    R: Reader,
    MAX: Int,
    origin: Origin,
](Iterator):
    """Yields `DelimitedRecordView` — no heap allocation per row."""

    comptime Element = DelimitedRecordView[MutExternalOrigin, Self.MAX]

    var _src: Pointer[DelimitedReader[Self.R, Self.MAX], Self.origin]

    fn __init__(
        out self,
        src: Pointer[DelimitedReader[Self.R, Self.MAX], Self.origin],
    ):
        self._src = src

    fn __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    fn __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    fn __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[
            Pointer[DelimitedReader[Self.R, Self.MAX], MutExternalOrigin]
        ](self._src)
        try:
            return mut_ptr[].next_record_view()
        except e:
            var msg = String(e)
            if msg == EOF or msg.startswith(EOF):
                raise StopIteration()
            else:
                print(msg)
                raise StopIteration()


# ---------------------------------------------------------------------------
# Iterator — owned records (one BString alloc per row)
# ---------------------------------------------------------------------------


struct _DelimitedRecordIter[
    R: Reader,
    MAX: Int,
    origin: Origin,
](Iterator):
    """Yields owned `DelimitedRecord`s — use when records must be stored."""

    comptime Element = DelimitedRecord[Self.MAX]

    var _src: Pointer[DelimitedReader[Self.R, Self.MAX], Self.origin]

    fn __init__(
        out self,
        src: Pointer[DelimitedReader[Self.R, Self.MAX], Self.origin],
    ):
        self._src = src

    fn __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    fn __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    fn __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[
            Pointer[DelimitedReader[Self.R, Self.MAX], MutExternalOrigin]
        ](self._src)
        try:
            return mut_ptr[].next_record()
        except e:
            var msg = String(e)
            if msg == EOF or msg.startswith(EOF):
                raise StopIteration()
            else:
                print(msg)
                raise StopIteration()
