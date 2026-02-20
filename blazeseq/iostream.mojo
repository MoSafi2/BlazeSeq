from memory import memcpy, UnsafePointer, Span, alloc
from pathlib import Path
from utils import StaticTuple
from builtin.builtin_slice import ContiguousSlice
from blazeseq.readers import Reader
from blazeseq.writers import (
    Writer as WriterTrait,
    FileWriter,
    MemoryWriter,
    GZWriter,
)
from blazeseq.CONSTS import *
from blazeseq.utils import memchr


@register_passable("trivial")
@fieldwise_init
struct LineIteratorError(
    Copyable, Equatable, ImplicitlyDestructible, Movable, Writable
):
    var value: Int8
    comptime EOF = Self(0)
    comptime INCOMPLETE_LINE = Self(1)
    comptime BUFFER_TOO_SMALL = Self(2)
    comptime OTHER = Self(3)

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
    fn write_to(self, mut writer: Some[Writer]):
        writer.write(EOF)


struct BufferedReader[R: Reader](
    ImplicitlyDestructible, Movable, Sized, Writable
):
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
        if capacity <= 0:
            raise Error(
                "Can't have BufferedReader with the follwing capacity: ",
                capacity,
                " Bytes",
            )

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
        """Current number of bytes in the buffer (same as __len__)."""
        return self._end - self._head

    @always_inline
    fn consume(mut self, size: Int) -> Int:
        """
        Advance read position by `size`. Must not exceed available().
        Does not compact; caller must call compact_from() when needed.
        """
        var cons_size = min(size, self.available())
        self._head += cons_size
        return cons_size

    @always_inline
    fn unconsume(mut self, size: Int) raises:
        """
        Unconsume `size` bytes. Must not exceed available().
        """
        if size > self._head:
            raise Error("Cannot unconsume more than available")
        self._head -= size

    @always_inline
    fn read_exact(mut self, size: Int) raises -> List[Byte]:
        """
        Read exactly `size` bytes. Raises if EOF is reached before that many bytes.
        Returns owned bytes (safe to use after further mutating calls).
        """
        if size < 0:
            raise Error(
                "read_exact size must be non-negative, got " + String(size)
            )
        # Ensure buffer is not full and has enough bytes available
        while self.available() < size:
            if not self._fill_buffer():
                raise Error(
                    "Unexpected EOF: needed "
                    + String(size)
                    + " bytes, only "
                    + String(self.available())
                    + " available"
                )
        var v = self.view()
        var result = List[Byte](capacity=size)
        for i in range(size):
            result.append(v[i])
        var consumed = self.consume(size)
        # Since we ensured size bytes are available, consumed should equal size
        if consumed != size:
            raise Error(
                "Internal error: consume() returned "
                + String(consumed)
                + " but expected "
                + String(size)
            )
        return result^

    @always_inline
    fn stream_position(self) -> Int:
        """
        Current logical position in the stream that parser is reading.
        Use for error messages: \"Parse error at byte N\".
        """
        return self._stream_position + self._head

    @always_inline
    fn buffer_position(self) -> Int:
        """Current read offset in the buffer (for parser compact_from)."""
        return self._head

    @always_inline
    fn buffer_base(ref self) -> UnsafePointer[Byte, MutExternalOrigin]:
        """Base pointer of the buffer. Used by parser to rebase spans after resize.
        """
        return self._ptr

    @always_inline
    fn span_at(
        ref self, offset: Int, length: Int
    ) -> Span[Byte, MutExternalOrigin]:
        """Span over buffer at given offset from buffer base and length. Used after resize+compact to rebase SearchResults.
        """
        return Span[Byte, MutExternalOrigin](
            ptr=self._ptr + offset, length=length
        )

    @always_inline
    fn is_eof(self) -> Bool:
        """True when underlying read returned no more data."""
        return self._is_eof

    @always_inline
    fn capacity(self) -> Int:
        return self._len

    @always_inline
    fn grow_buffer(mut self, additional: Int, max_capacity: Int) raises:
        """
        Grow buffer by `additional` bytes, not exceeding max_capacity.
        Compacts first to maximize usable space and avoid unnecessary growth.
        Use case: Parser encounters line longer than buffer, needs more space.
        """
        if self.capacity() >= max_capacity:
            raise Error("Buffer already at max capacity")
        self._compact_from(self._head)
        var new_capacity = min(self.capacity() + additional, max_capacity)
        _ = self._resize_internal(new_capacity)

    @always_inline
    fn resize_buffer(mut self, additional: Int, max_capacity: Int) raises:
        """
        Resize buffer by `additional` bytes, not exceeding max_capacity.
        Does nott compact the buffer before resizing.
        """
        if self.capacity() >= max_capacity:
            raise Error("Buffer already at max capacity")
        var new_capacity = min(self.capacity() + additional, max_capacity)
        _ = self._resize_internal(new_capacity)

    @always_inline
    fn view(ref [_]self) raises -> Span[Byte, MutExternalOrigin]:
        """View of all unconsumed bytes. Valid until next mutating call."""
        return Span[Byte, MutExternalOrigin](
            ptr=self._ptr + self._head, length=self._end - self._head
        )

    fn write_to[w: Writer](self, mut writer: w):
        try:
            writer.write_string(StringSlice(unsafe_from_utf8=self.view()))
        except:
            writer.write("")

    @always_inline
    fn peek(ref self, amt: Int) raises -> Span[Byte, MutExternalOrigin]:
        """
        Peek at the next `amt` bytes in the buffer without consuming them.
        """
        var peek_amt = min(amt, self.available())
        return Span[Byte, MutExternalOrigin](
            ptr=self._ptr + self._head, length=peek_amt
        )

    @always_inline
    fn _compact_from(mut self, from_pos: Int = 0) raises:
        """
        Discard bytes [0, from_pos) and shift remaining data to [0, end - from_pos).
        Resets head if it was before from_pos (parser record-boundary use case).
        """
        if from_pos >= self._end:
            self._stream_position += self._end
            self._head = 0
            self._end = 0
            return

        self._stream_position += from_pos
        var remaining = self._end - from_pos
        memcpy(dest=self._ptr, src=self._ptr + from_pos, count=remaining)
        if self._head < from_pos:
            self._head = 0
        else:
            self._head -= from_pos
        self._end = remaining

    @always_inline
    fn _fill_buffer(mut self) raises -> UInt64:
        """Returns the number of bytes read into the buffer. Caller must call compact_from() when buffer is full to make room.
        """
        if self._is_eof:
            return 0

        var space = self.capacity() - self._end
        if space == 0:
            return 0

        var buf_span = Span[Byte, MutExternalOrigin](
            ptr=self._ptr, length=self._len
        )
        var amt = self.source.read_to_buffer(buf_span, space, self._end)
        self._end += Int(amt)
        if amt == 0:
            self._is_eof = True

        return amt

    @always_inline
    fn _resize_internal(mut self, new_len: Int) raises -> Bool:
        if new_len < self._len:
            raise Error("New length must be greater than current length")
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
    fn __getitem__(self, index: Int) raises -> Byte:
        """Index into unconsumed bytes; index is relative to current position (0 = first unconsumed).
        """
        if index < 0 or index >= self.available():
            raise Error(
                "Out of bounds: index "
                + String(index)
                + " not in valid range [0, "
                + String(self.available())
                + ")"
            )
        return self._ptr[self._head + index]

    @always_inline
    fn __getitem__(ref self, sl: Slice) raises -> Span[Byte, MutExternalOrigin]:
        """
        Slice unconsumed bytes. Indices are relative to current position:
        buf[0] = first unconsumed byte, buf[:] = all unconsumed, buf[0:n] = first n unconsumed.
        """
        var avail = self.available()
        var start_offset = sl.start.or_else(0)
        var end_offset = sl.end.or_else(avail)
        var step = sl.step.or_else(1)

        if step != 1:
            raise Error("Step loading is not supported")

        if start_offset < 0 or start_offset > avail:
            raise Error(
                "Slice start "
                + String(start_offset)
                + " out of valid range [0, "
                + String(avail)
                + "]"
            )
        if end_offset < start_offset or end_offset > avail:
            raise Error(
                "Out of bounds: slice end "
                + String(end_offset)
                + " not in valid range ["
                + String(start_offset)
                + ", "
                + String(avail)
                + "]"
            )

        var start = self._head + start_offset
        var end = self._head + end_offset
        return Span[Byte, MutExternalOrigin](
            ptr=self._ptr + start, length=end - start
        )

    fn __del__(deinit self):
        if self._ptr:
            self._ptr.free()


struct BufferedWriter[W: WriterTrait](ImplicitlyDestructible, Movable):
    """Buffered writer for efficient byte writing.

    Works with any Writer backend (FileWriter, MemoryWriter, GZWriter).
    Maintains an internal buffer and flushes automatically when full or on explicit flush() call.
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
            writer: Writer backend (FileWriter, MemoryWriter, or GZWriter).
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

    fn write_bytes(mut self, data: Span[Byte]) raises:
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

    fn write_bytes(mut self, data: List[Byte]) raises:
        """Write bytes from a List to the buffer, flushing if needed.

        Args:
            data: List of bytes to write.

        Raises:
            Error: If writing fails.
        """
        if len(data) == 0:
            return
        var span = Span[Byte](ptr=data.unsafe_ptr(), length=len(data))
        self.write_bytes(span)

    fn flush(mut self) raises:
        """Flush the buffer to disk.

        Ensures all buffered data is written to the file.
        """
        self._flush_buffer()

    fn _flush_buffer(mut self) raises:
        """Internal method to flush buffer to writer backend."""
        if self._pos > 0:
            var span = Span[Byte, MutExternalOrigin](
                ptr=self._ptr, length=self._pos
            )
            var written = self.writer.write_from_buffer(span, self._pos, 0)
            self._bytes_written += Int(written)
            self._pos = 0

    fn __del__(deinit self):
        """Destructor: flush buffer."""
        try:
            self._flush_buffer()
        except:
            pass
        if self._ptr:
            self._ptr.free()


fn buffered_writer_for_file(
    path: Path, capacity: Int = DEFAULT_CAPACITY
) raises -> BufferedWriter[FileWriter]:
    """Create BufferedWriter for a file."""
    return BufferedWriter[FileWriter](FileWriter(path), capacity)


fn buffered_writer_for_memory(
    capacity: Int = DEFAULT_CAPACITY,
) raises -> BufferedWriter[MemoryWriter]:
    """Create BufferedWriter for memory."""
    return BufferedWriter[MemoryWriter](MemoryWriter(), capacity)


fn buffered_writer_for_gzip(
    filename: String, capacity: Int = DEFAULT_CAPACITY
) raises -> BufferedWriter[GZWriter]:
    """Create BufferedWriter for a gzipped file."""
    return BufferedWriter[GZWriter](GZWriter(filename), capacity)


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
    Iterates over newline-separated lines from a BufferedReader.
    Owns the buffer; parsers hold LineIterator and use next_line/next_n_lines.

    Supports the Mojo Iterator protocol: ``for line in line_iterator`` works.
    Each ``line`` is a ``Span[Byte, MutExternalOrigin]`` invalidated by the
    next iteration or any buffer mutation (same contract as ``next_line()``).
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
            The line number of the last line returned by next_line(), or 0 if no lines have been read yet.
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
        Invalidated by next next_line() or any buffer mutation.
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
        the current buffer. Does not refill or compact (except for initial empty buffer).
        If no newline is found, raise Error("INCOMPLETE_LINE") and do not consume;
        caller can fall back to next_line() to refill. Invalidated by next
        next_line/next_complete_line or any buffer mutation.
        """
        if self.buffer.available() == 0:
            if self.buffer.is_eof():
                raise LineIteratorError.EOF
            # Allow one initial fill if buffer is empty but not EOF
            # This handles the case where buffer wasn't filled during initialization
            try:
                _ = self.buffer._fill_buffer()
            except Error:
                raise LineIteratorError.OTHER
            if self.buffer.available() == 0:
                if self.buffer.is_eof():
                    raise LineIteratorError.EOF
                else:
                    raise LineIteratorError.INCOMPLETE_LINE

        var view: Span[Byte, MutExternalOrigin]
        try:
            view = self.buffer.view()
        except Error:
            raise LineIteratorError.OTHER

        var newline_at = memchr(haystack=view, chr=new_line)
        if newline_at == -1:
            raise LineIteratorError.INCOMPLETE_LINE

        var end = _trim_trailing_cr(view, newline_at)
        var span = view[0:end]
        _ = self.buffer.consume(newline_at + 1)
        return span

    fn peek(self, amt: Int) raises -> Span[Byte, MutExternalOrigin]:
        """
        Peek at the next `amt` bytes in the buffer without consuming them.
        """
        return self.buffer.peek(amt)

    @always_inline
    fn _handle_line_exceeds_capacity(mut self) raises:
        """
        Line does not fit in current buffer. Either raise (no growth or at max)
        or grow the buffer so the caller can retry.
        """
        if not self._growth_enabled:
            raise Error(
                "Line exceeds buffer capacity of "
                + String(self.buffer.capacity())
                + " bytes"
            )
        if self.buffer.capacity() >= self._max_capacity:
            raise Error(
                "Line exceeds max buffer capacity of "
                + String(self._max_capacity)
                + " bytes"
            )
        var current_cap = self.buffer.capacity()
        var growth_amount = min(current_cap, self._max_capacity - current_cap)
        self.buffer.grow_buffer(growth_amount, self._max_capacity)

    @always_inline
    fn _handle_eof_line(
        mut self, view: Span[Byte, MutExternalOrigin]
    ) raises -> Span[Byte, MutExternalOrigin]:
        """
        Handle EOF case: return remaining data with trailing \\r trimmed, or None if no data.
        Assumes buffer.is_eof() is True when called.
        """
        if len(view) > 0:
            var end = _trim_trailing_cr(view, len(view))
            var span = view[0:end]
            _ = self.buffer.consume(len(view))
            return span
        raise EOFError()

    fn __iter__(
        ref self,
    ) -> _LineIteratorIter[Self.R, origin_of(self)]:
        """Return an iterator for use in ``for line in self``."""
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
