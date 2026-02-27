from memory import memcpy, UnsafePointer, Span, alloc
from pathlib import Path
from utils import StaticTuple
from builtin.builtin_slice import ContiguousSlice
from collections.string import StringSlice, String
from blazeseq.io.readers import Reader
from blazeseq.io.writers import (
    WriterBackend,
    FileWriter,
    MemoryWriter,
    GZWriter,
)
from blazeseq.CONSTS import *
from blazeseq.errors import buffer_capacity_error
from blazeseq.utils import memchr, memchr_scalar


from sys import (
    is_compile_time,
    llvm_intrinsic,
    size_of,
)

@always_inline
fn memmove[
    T: AnyType
](
    *,
    dest: UnsafePointer[mut=True, T],
    src: UnsafePointer[mut=False, T],
    count: Int,
):
    """Copy `count * size_of[T]()` bytes from src to dest.

    Unlike `memcpy`, the memory regions are allowed to overlap.

    Parameters:
        T: The element type.

    Args:
        dest: The destination pointer.
        src: The source pointer.
        count: The number of elements to copy.
    """
    var n = count * size_of[T]()
    if is_compile_time():
        for i in range(n):
            (dest.bitcast[Byte]() + i).store((src.bitcast[Byte]() + i).load())
    else:
        llvm_intrinsic["llvm.memmove", NoneType](
            # <dest>, <src>, <len>, <isvolatile>
            dest.bitcast[Byte](),
            src.bitcast[Byte](),
            n,
            False,
        )



@register_passable("trivial")
@fieldwise_init
@doc_private
struct LineIteratorError(
    Copyable, Equatable, ImplicitlyDestructible, Movable, Writable
):
    """Error type used by `LineIterator.next_complete_line()` to signal conditions without raising.
    
    Values: `EOF` (no more input), `INCOMPLETE_LINE` (no newline in buffer yet),
    `BUFFER_TOO_SMALL` (line exceeds buffer), `OTHER`. Parser uses these to decide
    whether to refill buffer or grow before retrying.
    """
    var value: Int8
    comptime EOF = Self(0)
    comptime INCOMPLETE_LINE = Self(1)
    comptime BUFFER_TOO_SMALL = Self(2)
    comptime OTHER = Self(3)
    comptime EMPTY_BUFFER = Self(4)
    comptime SUCCESS = Self(5)


    fn __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    fn write_to(self, mut writer: Some[Writer]):
        var msg: String
        if self.value == 0:
            msg = "LineIteratorError: EOF"
        elif self.value == 1:
            msg = "LineIteratorError: INCOMPLETE_LINE"
        elif self.value == 2:
            msg = "LineIteratorError: BUFFER_TOO_SMALL"
        elif self.value == 3:
            msg = "LineIteratorError: OTHER"
        else:
            msg = "LineIteratorError: " + String(self.value)
        writer.write(msg)


@register_passable("trivial")
@fieldwise_init
struct EOFError(Writable):
    """Raised when no more input is available (end of file or stream).
    
    `FastqParser` and `LineIterator` raise `EOFError` when `next_ref()/next_record()`
    or `next_line()` is called and there is no more data. Iterators catch it
    and raise StopIteration instead.
    """
    fn write_to(self, mut writer: Some[Writer]):
        writer.write(EOF)


struct BufferedReader[R: Reader](
    ImplicitlyDestructible, Movable, Sized, Writable
):
    """
    Buffered reader over a Reader. Fills an internal buffer and exposes
    `view()`, `consume()`, `stream_position()`, etc. Used by `LineIterator` and
    thus by FastqParser. Supports buffer growth for long lines when
    enabled in LineIterator.

    Unsafe, low-level building block: callers must uphold preconditions.
    Misuse (e.g. capacity <= 0, out-of-bounds index, or reading past EOF)
    can lead to undefined behavior.
o    """

    var source: Self.R
    var _ptr: UnsafePointer[Byte, origin=MutExternalOrigin]
    var _len: Int  # Buffer capacity
    var _head: Int
    var _end: Int
    var _is_eof: Bool
    var _stream_position: Int  # Bytes consumed/discarded from stream so far

    fn __init__(
        out self, var reader: Self.R, capacity: Int = DEFAULT_CAPACITY
    ) raises:
        """Wrap a Reader with a buffer of given capacity. Reads once to fill buffer."""
        self.source = reader^
        self._ptr = alloc[Byte](capacity)
        self._len = capacity
        self._head = 0
        self._end = 0
        self._is_eof = False
        self._stream_position = 0
        _ = self._fill_buffer()

    @always_inline
    fn available(self) -> Int:
        """Current number of bytes in the buffer (same as `__len__`)."""
        return self._end - self._head

    @always_inline
    fn consume(mut self, size: Int) -> Int:
        """
        Advance read position by `size`. Must not exceed `available()`.
        Does not compact; caller must call `compact_from()` when needed.
        """
        var cons_size = min(size, self.available())
        self._head += cons_size
        return cons_size

    @always_inline
    fn unconsume(mut self, size: Int):
        """
        Unconsume `size` bytes. `_head` tracks position relative to compacted data;
        must not unconsume past the start (size <= _head). Use debug build with
        ASSERT=all to catch violations.
        """
        debug_assert(size <= self._head, "unconsume exceeds head position")
        self._head -= size

    @always_inline
    fn stream_position(self) -> Int:
        """
        Current logical position in the stream that parser is reading.
        Use for error messages: \"Parse error at byte N\".
        """
        return self._stream_position + self._head

    @always_inline
    fn buffer_position(self) -> Int:
        """Current read offset in the buffer (for parser `compact_from`)."""
        return self._head


    @always_inline
    fn is_eof(self) -> Bool:
        """True when underlying read returned no more data."""
        return self._is_eof

    @always_inline
    fn capacity(self) -> Int:
        """Return the buffer capacity in bytes."""
        return self._len

    @always_inline
    fn grow_buffer(mut self, additional: Int, max_capacity: Int) raises:
        """
        Grow buffer by `additional` bytes, not exceeding max_capacity.
        Compacts first to maximize usable space and avoid unnecessary growth.
        Use case: Parser encounters line longer than buffer, needs more space.
        """
        self._compact_from(self._head)
        var new_capacity = min(self.capacity() + additional, max_capacity)
        _ = self._resize_internal(new_capacity)

    @always_inline
    fn resize_buffer(mut self, additional: Int, max_capacity: Int) raises:
        """
        Resize buffer by `additional` bytes, not exceeding max_capacity.
        Does nott compact the buffer before resizing.
        """
        var new_capacity = min(self.capacity() + additional, max_capacity)
        _ = self._resize_internal(new_capacity)

    @always_inline
    fn view(ref [_]self) -> Span[Byte, MutExternalOrigin]:
        """View of all unconsumed bytes. Valid until next mutating call."""
        return Span[Byte, MutExternalOrigin](
            ptr=self._ptr + self._head, length=self._end - self._head
        )

    fn write_to[w: Writer](self, mut writer: w):
        writer.write_string(StringSlice(unsafe_from_utf8=self.view()))

    @always_inline
    fn peek(ref self, amt: Int) -> Span[Byte, MutExternalOrigin]:
        """
        Peek at the next `amt` bytes in the buffer without consuming them.
        """
        var peek_amt = min(amt, self.available())
        return Span[Byte, MutExternalOrigin](
            ptr=self._ptr + self._head, length=peek_amt
        )

    @always_inline
    fn _compact_from(mut self, from_pos: Int = 0):
        """
        Discard bytes [0, from_pos) and shift remaining data to [0, end - from_pos).
        Resets head if it was before from_pos (parser record-boundary use case).
        """
        if from_pos == 0:
            return
        if from_pos >= self._end:
            self._stream_position += self._end
            self._head = 0
            self._end = 0
            return

        self._stream_position += from_pos
        var remaining = self._end - from_pos
        memmove(dest=self._ptr, src=self._ptr + from_pos, count=remaining)
        if self._head < from_pos:
            self._head = 0
        else:
            self._head -= from_pos
        self._end = remaining

    @always_inline
    fn _fill_buffer(mut self) raises -> UInt64:
        """Returns the number of bytes read into the buffer. Caller must call `compact_from()` when buffer is full to make room."""
        if self._is_eof:
            return 0

        var space = self.capacity() - self._end
        if space == 0:
            return 0

        var buf_span = Span[Byte, MutExternalOrigin](
            ptr=self._ptr + self._end, length=space
        )
        var amt = self.source.read_to_buffer(buf_span, space, 0)
        self._end += Int(amt)
        if amt == 0:
            self._is_eof = True

        return amt

    @always_inline
    fn _resize_internal(mut self, new_len: Int) -> Bool:
        var new_ptr = alloc[Byte](new_len)
        memcpy(dest=new_ptr, src=self._ptr, count=self._len)
        self._ptr.free()
        self._ptr = new_ptr
        self._len = new_len
        return True

    @always_inline
    fn __len__(self) -> Int:
        return self._end - self._head

    @always_inline
    fn __str__(self) raises -> String:
        var x = String(capacity=len(self))
        self.write_to(x)
        return x

    @always_inline
    fn __getitem__(self, index: Int) -> Byte:
        """Index into unconsumed bytes; index is relative to current position (0 = first unconsumed).
        Indices are not validated; out-of-bounds access is undefined behavior.
        """
        return self._ptr[self._head + index]

    @always_inline
    fn __getitem__(ref self, sl: ContiguousSlice) -> Span[Byte, MutExternalOrigin]:
        """
        Slice unconsumed bytes. Indices are relative to current position:
        buf[0] = first unconsumed byte, buf[:] = all unconsumed, buf[0:n] = first n unconsumed.
        """
        var avail = self.available()
        var start_offset = sl.start.or_else(0)
        var end_offset = sl.end.or_else(avail)
        var start = self._head + start_offset
        var end = self._head + end_offset
        return Span[Byte, MutExternalOrigin](
            ptr=self._ptr + start, length=end - start
        )

struct BufferedWriter[W: WriterBackend](ImplicitlyDestructible, Movable, Writer):
    """Buffered writer for efficient byte writing.

    Works with any `WriterBackend` (`FileWriter`, `MemoryWriter`, `GZWriter`).
    Maintains an internal buffer and flushes automatically when full or on explicit `flush()` call.
    """

    var writer: Self.W
    var _ptr: UnsafePointer[Byte, origin=MutExternalOrigin]
    var _len: Int  # Buffer capacity
    var _pos: Int  # Current write position in buffer
    var _bytes_written: Int  # Total bytes written

    fn __init__(
        out self, var writer: Self.W, capacity: Int = DEFAULT_CAPACITY
    ) raises:
        """Initialize BufferedWriter with a Writer backend.

        Args:
            writer: Writer backend (`FileWriter`, `MemoryWriter`, or `GZWriter`).
            capacity: Size of the write buffer in bytes.

        Raises:
            Error: If capacity is invalid.
        """
        if capacity <= 0:
            raise Error(
                "Can't have BufferedWriter with the following capacity: ",
                capacity,
                " Bytes",
            )
        self.writer = writer^
        self._ptr = alloc[Byte](capacity)
        self._len = capacity
        self._pos = 0
        self._bytes_written = 0

    @always_inline
    fn capacity(self) -> Int:
        """Return the buffer capacity."""
        return self._len

    @always_inline
    fn available_space(self) -> Int:
        """Return available space in buffer."""
        return self._len - self._pos

    @always_inline
    fn bytes_written(self) -> Int:
        """Return total bytes written to file."""
        return self._bytes_written

    @always_inline
    fn write_bytes(mut self, data: List[Byte]) raises:
        """Write bytes from a List to the buffer, flushing if needed.

        Args:
            data: List of bytes to write.

        Raises:
            Error: If writing fails.
        """
        if len(data) == 0:
            return
        #var span = data[:]
        self._write_bytes_impl(data[:])

    @always_inline
    fn write_string(mut self, string: StringSlice):
        """Write a StringSlice to this Writer. Required by the builtin `Writer` trait."""
        try:
            var bytes_span = string.as_bytes()
            var lst = List[Byte](capacity=len(bytes_span))
            lst.extend(bytes_span)
            self._write_bytes_impl(lst[:])
        except:
            pass  # Writer trait does not allow raises; use write_bytes() to handle errors

    fn write[*Ts: Writable](mut self, *args: *Ts):
        """Write a sequence of Writable arguments. Required by the builtin `Writer` trait."""
        @parameter
        for i in range(args.__len__()):
            args[i].write_to(self)

    @always_inline
    fn flush(mut self) raises:
        """Flush the buffer to disk.

        Ensures all buffered data is written to the file.
        """
        self._flush_buffer()

    @always_inline
    fn _flush_buffer(mut self) raises:
        """Internal method to flush buffer to writer backend."""
        if self._pos > 0:
            var span = Span[Byte, MutExternalOrigin](
                ptr=self._ptr, length=self._pos
            )
            var written = self.writer.write_from_buffer(span, self._pos, 0)
            self._bytes_written += Int(written)
            self._pos = 0
    
    @always_inline
    fn _write_bytes_impl(mut self, data: Span[Byte]) raises:
        """Write bytes from a Span to the buffer, flushing if needed.

        Args:
            data: Span of bytes to write.

        Raises:
            Error: If writing fails.
        """

        var remaining = len(data)
        var offset = 0

        while remaining > 0:
            var space = self.available_space()
            if space == 0:
                self._flush_buffer()
                space = self.available_space()
            var to_write = min(remaining, space)
            memcpy(
                dest=self._ptr + self._pos,
                src=data.unsafe_ptr() + offset,
                count=to_write,
            )
            self._pos += to_write
            offset += to_write
            remaining -= to_write


    fn __del__(deinit self):
        """Destructor: flush buffer."""
        try:
            self._flush_buffer()
        except:
            pass
        if self._ptr:
            self._ptr.free()


@doc_private
fn buffered_writer_for_file(
    path: Path, capacity: Int = DEFAULT_CAPACITY
) raises -> BufferedWriter[FileWriter]:
    """Create BufferedWriter for a file."""
    return BufferedWriter[FileWriter](FileWriter(path), capacity)


@doc_private
fn buffered_writer_for_memory(
    capacity: Int = DEFAULT_CAPACITY,
) raises -> BufferedWriter[MemoryWriter]:
    """Create BufferedWriter for memory."""
    return BufferedWriter[MemoryWriter](MemoryWriter(), capacity)


@doc_private
fn buffered_writer_for_gzip(
    filename: String, capacity: Int = DEFAULT_CAPACITY
) raises -> BufferedWriter[GZWriter]:
    """Create BufferedWriter for a gzipped file."""
    return BufferedWriter[GZWriter](GZWriter(filename), capacity)

@doc_private
@always_inline
fn _trim_trailing_cr(view: Span[Byte, MutExternalOrigin], end: Int) -> Int:
    """
    Return the exclusive end index for line content, trimming a single trailing \\r.
    Use when the line may end with \\r (e.g. before \\n or at EOF).
    """
    if end > 0 and view[end - 1] == carriage_return:
        return end - 1
    return end


struct LineIterator[R: Reader](Iterable, Movable):
    """
    Iterates over newline-separated lines from a `BufferedReader`.
    Owns the buffer; parsers hold `LineIterator` and use `next_line` / `next_n_lines`.

    Supports the Mojo Iterator protocol: `for line in line_iterator` works.
    Each `line` is a `Span[Byte, MutExternalOrigin]` invalidated by the
    next iteration or any buffer mutation (same contract as `next_line()`).
    """

    comptime IteratorType[
        mut: Bool, origin: Origin[mut=mut]
    ] = _LineIteratorIter[Self.R, origin]

    var buffer: BufferedReader[Self.R]
    var _growth_enabled: Bool
    var _max_capacity: Int
    var _current_line_number: Int  # Track current line number (1-indexed)
    var _file_position: Int64  # Track byte position in file

    fn __init__(
        out self,
        var reader: Self.R,
        capacity: Int = DEFAULT_CAPACITY,
        growth_enabled: Bool = False,
        max_capacity: Int = MAX_CAPACITY,
    ) raises:
        """Build a line iterator over a `Reader`. Optionally allow buffer growth for long lines.
        
        Args:
            reader: Source (e.g. `FileReader`, `MemoryReader`).
            capacity: Initial buffer size in bytes.
            growth_enabled: If True, buffer can grow up to max_capacity for long lines.
            max_capacity: Maximum buffer size when growth is enabled.
        """
        self.buffer = BufferedReader(reader^, capacity)
        self._growth_enabled = growth_enabled
        self._max_capacity = max_capacity
        self._current_line_number = 0
        self._file_position = 0

    @always_inline
    fn position(self) -> Int:
        """Logical byte position of next line start (for errors and compaction).
        """
        return self.buffer.stream_position()

    @always_inline
    fn get_line_number(self) -> Int:
        """Return the current line number (1-indexed).

        Returns:
            The line number of the last line returned by `next_line()`, or 0 if no lines have been read yet.
        """
        return self._current_line_number

    @always_inline
    fn get_file_position(self) -> Int64:
        """Return the current byte position in the file.

        Returns:
            The byte position corresponding to the start of the current line, or 0 if unknown.
        """
        return self._file_position

    @always_inline
    fn has_more(self) -> Bool:
        """True if there is at least one more line (data in buffer or more can be read).
        """
        return self.buffer.available() > 0 or not self.buffer.is_eof()

    @always_inline
    fn next_line(mut self) raises -> Span[Byte, MutExternalOrigin]:
        """
        Next line as span excluding newline (and trimming trailing \\r). None at EOF.
        Invalidated by next `next_line()` or any buffer mutation.
        """
        # Update file position before reading line
        self._file_position = Int64(self.buffer.stream_position())

        while True:
            if self.buffer.available() == 0:
                if self.buffer.is_eof():
                    raise EOFError()

                self.buffer._compact_from(self.buffer.buffer_position())
            _ = self.buffer._fill_buffer()
            if self.buffer.available() == 0:
                raise EOFError()

            var view = self.buffer.view()
            var newline_at = memchr(haystack=view, chr=new_line)
            if newline_at >= 0:
                var end = _trim_trailing_cr(view, newline_at)
                var span = view[0:end]
                _ = self.buffer.consume(newline_at + 1)
                # Increment line number after successfully reading a line
                self._current_line_number += 1
                return span

            if self.buffer.is_eof():
                var result = self._handle_eof_line(view)
                # Increment line number for EOF line
                self._current_line_number += 1
                return result

            if len(view) >= self.buffer.capacity():
                self._handle_line_exceeds_capacity()
                continue

            self.buffer._compact_from(self.buffer.buffer_position())





    @always_inline
    fn next_complete_line(
        mut self,
    ) raises LineIteratorError -> Span[Byte, MutExternalOrigin]:
        """
        Return the next line only if a complete line (ending with newline) is in
        the current buffer. Does not compact. When the buffer is empty, refills
        once to distinguish EOF from EMPTY_BUFFER.
        If no newline is found, raise LineIteratorError.INCOMPLETE_LINE and do not consume;
        if the buffer is empty after a refill, raise LineIteratorError.EMPTY_BUFFER.
        Caller can fall back to `next_line()` to refill. Invalidated by next
        `next_line` or any buffer grow/compact/resize.
        """
        if self.buffer.available() == 0:
            if self.buffer.is_eof():
                raise LineIteratorError.EOF
            try:
                _ = self.buffer._fill_buffer()
            except Error:
                raise LineIteratorError.OTHER
            if self.buffer.available() == 0:
                if self.buffer.is_eof():
                    raise LineIteratorError.EOF
                raise LineIteratorError.EMPTY_BUFFER

        view = self.buffer.view()
        var newline_at = memchr(haystack=view, chr=new_line)
    
        if newline_at == -1:
            if self.buffer.is_eof():
                self._current_line_number += 1
                return self._handle_eof_line(view)
            raise LineIteratorError.INCOMPLETE_LINE

        var end = _trim_trailing_cr(view, newline_at)
        var span = view[0:end]
        _ = self.buffer.consume(newline_at + 1)
        self._current_line_number += 1
        return span

    fn peek(self, amt: Int) raises -> Span[Byte, MutExternalOrigin]:
        """
        Peek at the next `amt` bytes in the buffer without consuming them.
        """
        return self.buffer.peek(amt)

    # Does not support buffer growth yet.
    @always_inline
    fn read_exact(mut self, size: Int) raises -> Span[Byte, MutExternalOrigin]:
        """
        Read exactly `size` bytes. Refills and compacts the buffer as needed.
        Raises EOFError if the stream ends before `size` bytes are available.
        Returns a span over the buffer; valid only until the next mutating call.
        """
        if size == 0:
            return self.buffer.view()[0:0]
        
        if self.buffer.available() < size:
            if self.buffer.is_eof():
                raise EOFError()
            if self.buffer.available() >= self.buffer.capacity():
                self.buffer._compact_from(self.buffer.buffer_position())
            _ = self.buffer._fill_buffer()
        var result = self.buffer.view()[0:size]
        _ = self.buffer.consume(size)
        return result

    @always_inline
    fn consume_line_scalar(mut self) raises LineIteratorError -> Span[Byte, MutExternalOrigin]:
        """
        Consume the next line (plus line) using scalar memchr to find newline.
        Validates line starts with '+'. Does not refill; raises INCOMPLETE_LINE if
        newline not in current buffer. Raises OTHER if line does not start with '+'.
        """
        if self.buffer.available() == 0:
            if self.buffer.is_eof():
                raise LineIteratorError.EOF
            try:
                _ = self.buffer._fill_buffer()
            except Error:
                raise LineIteratorError.OTHER
            if self.buffer.available() == 0:
                if self.buffer.is_eof():
                    raise LineIteratorError.EOF
                else:
                    raise LineIteratorError.INCOMPLETE_LINE

        var view = self.buffer.view()
        var newline_at = memchr_scalar(haystack=view, chr=new_line)
        if newline_at == -1:
            raise LineIteratorError.INCOMPLETE_LINE
        
        var end = _trim_trailing_cr(view, newline_at)
        var span = view[0:end]
        _ = self.buffer.consume(newline_at + 1)
        self._current_line_number += 1
        return span
    
    @always_inline
    fn _handle_line_exceeds_capacity(mut self) raises:
        """
        Line does not fit in current buffer. Either raise (no growth or at max)
        or grow the buffer so the caller can retry.
        """
        # Buffer growth disabled until more stable; always raise.
        # if not self._growth_enabled:
        #     raise Error(buffer_capacity_error(self.buffer.capacity()))
        # if self.buffer.capacity() >= self._max_capacity:
        #     raise Error(buffer_capacity_error(self.buffer.capacity(),self._max_capacity,at_max=True))
        # var current_cap = self.buffer.capacity()
        # var growth_amount = min(current_cap, self._max_capacity - current_cap)
        # self.buffer.grow_buffer(growth_amount, self._max_capacity)
        # _ = self.buffer._fill_buffer()
        raise Error(
            buffer_capacity_error(
                self.buffer.capacity(),
                self._max_capacity,
                at_max=(self._max_capacity > 0 and self.buffer.capacity() >= self._max_capacity),
            )
        )

    @always_inline
    fn _handle_eof_line(
        mut self, view: Span[Byte, MutExternalOrigin]
    ) raises LineIteratorError -> Span[Byte, MutExternalOrigin]:
        """
        Handle EOF case: return remaining data with trailing \\r trimmed, or None if no data.
        Assumes buffer.is_eof() is True when called.
        """
        if len(view) > 0:
            var end = _trim_trailing_cr(view, len(view))
            var span = view[0:end]
            _ = self.buffer.consume(len(view))
            return span
        raise LineIteratorError.EOF

    fn __iter__(
        ref self,
    ) -> _LineIteratorIter[Self.R, origin_of(self)]:
        """Return an iterator for use in `for line in self`."""
        return _LineIteratorIter[Self.R, origin_of(self)](Pointer(to=self))


# ---------------------------------------------------------------------------
# Iterator adapter for LineIterator so that ``for line in line_iter`` works.
# ---------------------------------------------------------------------------

struct _LineIteratorIter[R: Reader, origin: Origin](Iterator):
    """Iterator over lines; yields Span[Byte, MutExternalOrigin] per line."""

    comptime Element = Span[Byte, MutExternalOrigin]

    var _src: Pointer[LineIterator[Self.R], Self.origin]

    fn __init__(
        out self,
        src: Pointer[LineIterator[Self.R], Self.origin],
    ):
        self._src = src

    fn __has_next__(self) -> Bool:
        return self._src[].has_more()

    fn __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[Pointer[LineIterator[Self.R], MutExternalOrigin]](
            self._src
        )
        try:
            var opt = mut_ptr[].next_line()
            if not opt:
                raise StopIteration()
            return opt
        except Error:
            if String(Error) == String(EOFError()):
                raise StopIteration()
            else:
                print(String(Error))
                raise StopIteration()
