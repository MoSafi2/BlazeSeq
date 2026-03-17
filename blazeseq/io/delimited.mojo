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


trait LinePolicy(
    Copyable,
    ImplicitlyDestructible,
    Movable,
    TrivialRegisterPassable,
):
    """Classify a raw line before it reaches the data-row path.

    The DelimitedReader calls `classify()` on every line. The returned
    `LineDisposition` controls what happens next:

      YIELD    — hand the line to the field-splitting path as a normal row.
      SKIP     — discard the line and advance.
      METADATA — route the line to `handle_metadata()` then advance.
      HEADER   — parse the line as column names then advance.
      STOP     — terminate iteration immediately (e.g. embedded FASTA block).
    """

    fn __init__(out self):
        ...

    @always_inline
    fn classify(self, line: Span[UInt8, _]) -> LineAction:
        ...

    @always_inline
    fn handle_metadata(mut self, line: Span[UInt8, _]) raises:
        """Called when classify() returns METADATA. Default: no-op."""
        ...


@fieldwise_init
struct LineAction(
    Copyable, Equatable, Movable, TrivialRegisterPassable, Writable
):
    """The action a LinePolicy returns for a given line."""

    var _tag: UInt8

    comptime YIELD = Self(0)  # pass to caller as a data row
    comptime SKIP = Self(1)  # discard silently
    comptime METADATA = Self(2)  # structured content; route to metadata handler
    comptime HEADER = Self(3)  # column-name line; parse field names from it
    comptime STOP = Self(4)  # terminate iteration (e.g. ##FASTA in GFF3)

    fn __eq__(self, other: Self) -> Bool:
        return self._tag == other._tag


struct DefaultLinePolicy(
    Copyable, LinePolicy, Movable, TrivialRegisterPassable
):
    """The default line policy for delimited readers.

    Skips blank lines (SKIP) and yields all non-empty lines (YIELD).
    """

    fn __init__(out self):
        pass

    @always_inline
    fn classify(self, line: Span[UInt8, _]) -> LineAction:
        if len(line) == 0:
            return LineAction.SKIP
        return LineAction.YIELD

    @always_inline
    fn handle_metadata(mut self, line: Span[UInt8, _]) raises:
        ...


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
# DelimitedView — zero-alloc, NOT thread-safe, NOT to be stored
# ---------------------------------------------------------------------------


struct DelimitedView[
    O: Origin,
    MAX: Int = 64,
](Movable, Sized, Writable):
    """A non-owning view over one delimited row.

    Holds a `Span` into the *reader's internal buffer* and a stack-allocated
    `FieldOffsets`. No heap allocation is made.

    **Lifetime contract**: the view is invalidated the moment `LineIterator`
    advances (i.e. on the next `next_line()` call or any buffer compaction).
    Never store a `DelimitedView`; call `.to_record()` if you need
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
    `DelimitedView.to_record()`. Holds exactly one `BString` (the raw
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
    fn __init__(out self, var view: DelimitedView[_, Self.MAX]):
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


struct DelimitedReader[
    R: Reader, P: LinePolicy = DefaultLinePolicy, MAX: Int = 64
](Movable):
    """Generic delimited-file reader over a `Reader`.

    Supports TSV, CSV, FAI, BED, GFF, and similar formats.

    The hot path — `next_view()` / `for view in dr.views()` — yields a
    `DelimitedView` with **zero heap allocations** per row: the span
    lives in the reader's internal buffer and the offsets are stack-allocated.

    Call `.to_record()` on the view when you need the record to outlive the
    current iteration step; `next_record()` / `for record in dr.records()` do
    this automatically (one `BString` alloc per row).

    `for view in dr` (i.e. `__iter__`) defaults to the zero-alloc view path.

    Example — filter without allocating on every row:
        ```mojo
        from blazeseq.io import DelimitedReader, FileReader
        from std.pathlib import Path
        from blazeseq.io import DelimitedRecord

        var reader = FileReader(Path("data.tsv"))
        var dr = DelimitedReader[FileReader](reader^, has_header=True)
        var results = List[DelimitedRecord[64]]()
        while dr.has_more():
            var view = dr.next_view()
            if String(view.get_span(2)) == "homo_sapiens":
                results.append(view^.to_record())  # alloc only on match
        ```
    """

    var lines: LineIterator[Self.R]
    var policy: Self.P
    var _delimiter: UInt8
    var _record_number: Int
    var _has_header: Bool
    var _header: Optional[DelimitedRecord[Self.MAX]]
    var _expected_num_fields: Int

    fn __init__(
        out self,
        var reader: Self.R,
        delimiter: Byte = Byte(ord("\t")),  # ord("\t")
        has_header: Bool = False,
    ) raises:
        self.lines = LineIterator(reader^)
        self._delimiter = delimiter
        self._record_number = 0
        self._has_header = has_header
        self._header = None
        self._expected_num_fields = 0
        self.policy = Self.P()

        if self._has_header and self.lines.has_more():
            var line = self._next_data_line()
            self._parse_header_from(line)

    @always_inline
    fn has_more(self) -> Bool:
        return self.lines.has_more()

    @always_inline
    fn _get_record_number(ref self) -> Int:
        return self._record_number

    @always_inline
    fn _get_line_number(ref self) -> Int:
        return self.lines.get_line_number()

    @always_inline
    fn _get_file_position(ref self) -> Int64:
        return self.lines.get_file_position()

    fn header(ref self) -> Optional[DelimitedRecord[Self.MAX]]:
        """Copy of the stored header record, if present."""
        return self._header.copy()

    # ------------------------------------------------------------------
    # Hot path: zero-alloc view
    # ------------------------------------------------------------------

    fn next_view(
        mut self,
    ) raises -> DelimitedView[MutExternalOrigin, Self.MAX]:
        """Return the next row as a zero-alloc `DelimitedView`.

        The view borrows from the reader's internal line buffer and is
        invalidated on the next call to any advancing method. Call
        `.to_record()` to obtain an owned `DelimitedRecord`.

        Raises `EOFError` when no more records are available.
        """
        if not self.has_more():
            raise EOFError()

        var line = self._next_data_line()
        var view = DelimitedView[MutExternalOrigin, Self.MAX](
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

        Convenience wrapper around `next_view().to_record()`.
        Raises `EOFError` when no more records are available.
        """
        return self.next_view().to_record()

    # ------------------------------------------------------------------
    # Iterators
    # ------------------------------------------------------------------

    fn views(
        ref self,
    ) -> _DelimitedViewIter[Self.R, Self.P, Self.MAX, origin_of(self)]:
        """Iterator yielding zero-alloc `DelimitedView`s."""
        return _DelimitedViewIter[Self.R, Self.P, Self.MAX, origin_of(self)](
            Pointer(to=self)
        )

    fn records(
        ref self,
    ) -> _DelimitedRecordIter[Self.R, Self.P, Self.MAX, origin_of(self)]:
        """Iterator yielding owned `DelimitedRecord`s."""
        return _DelimitedRecordIter[Self.R, Self.P, Self.MAX, origin_of(self)](
            Pointer(to=self)
        )

    fn __iter__(
        ref self,
    ) -> _DelimitedViewIter[Self.R, Self.P, Self.MAX, origin_of(self)]:
        """Default iteration yields zero-alloc views."""
        return self.views()

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    fn _next_data_line(
        mut self,
    ) raises -> Span[UInt8, MutExternalOrigin]:
        """Return the next line to treat as a data row.

        Dispatches on policy.classify(): YIELD -> return; SKIP -> continue;
        METADATA -> handle_metadata then continue; HEADER -> _parse_header_from
        then continue; STOP -> raise EOFError.
        """
        while True:
            var line = self.lines.next_line()  # raises EOFError at EOF
            var action = self.policy.classify(line)
            if action == LineAction.YIELD:
                return line
            elif action == LineAction.SKIP:
                continue
            elif action == LineAction.METADATA:
                self.policy.handle_metadata(line)
                continue
            elif action == LineAction.HEADER:
                self._parse_header_from(line)
                continue
            else:
                raise EOFError()

    fn _parse_header_from(
        mut self, line: Span[UInt8, MutExternalOrigin]
    ) raises:
        """Parse a line as column names and store as header. Sets _expected_num_fields.
        """
        var view = DelimitedView[MutExternalOrigin, Self.MAX](
            line, self._delimiter
        )
        self._expected_num_fields = view.num_fields()
        self._header = view^.to_record()

    @always_inline
    fn _check_field_count(mut self, n: Int) raises:
        if self._expected_num_fields == 0:
            self._expected_num_fields = n
        elif n != self._expected_num_fields:
            raise Error(
                format_parse_error(
                    "Delimited row has inconsistent number of fields",
                    self._get_record_number() + 1,
                    self._get_line_number(),
                    self._get_file_position(),
                    "",
                )
            )


# ---------------------------------------------------------------------------
# Iterator — views (zero-alloc)
# ---------------------------------------------------------------------------


struct _DelimitedViewIter[
    R: Reader,
    P: LinePolicy,
    MAX: Int,
    origin: Origin,
](Iterator):
    """Yields `DelimitedView` — no heap allocation per row."""

    comptime Element = DelimitedView[MutExternalOrigin, Self.MAX]

    var _src: Pointer[DelimitedReader[Self.R, Self.P, Self.MAX], Self.origin]

    fn __init__(
        out self,
        src: Pointer[DelimitedReader[Self.R, Self.P, Self.MAX], Self.origin],
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
            Pointer[
                DelimitedReader[Self.R, Self.P, Self.MAX], MutExternalOrigin
            ]
        ](self._src)
        try:
            return mut_ptr[].next_view()
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
    P: LinePolicy,
    MAX: Int,
    origin: Origin,
](Iterator):
    """Yields owned `DelimitedRecord`s — use when records must be stored."""

    comptime Element = DelimitedRecord[Self.MAX]

    var _src: Pointer[DelimitedReader[Self.R, Self.P, Self.MAX], Self.origin]

    fn __init__(
        out self,
        src: Pointer[DelimitedReader[Self.R, Self.P, Self.MAX], Self.origin],
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
            Pointer[
                DelimitedReader[Self.R, Self.P, Self.MAX], MutExternalOrigin
            ]
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


