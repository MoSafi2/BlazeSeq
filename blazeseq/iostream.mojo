from memory import memcpy, UnsafePointer, Span, alloc
from blazeseq.CONSTS import DEFAULT_CAPACITY
from blazeseq.utils import _check_ascii
from pathlib import Path
from utils import StaticTuple
from builtin.builtin_slice import ContiguousSlice
from blazeseq.readers import Reader


struct BufferedReader[R: Reader, check_ascii: Bool = False](
    Movable, Sized, Writable
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
    fn consume(mut self, size: Int) raises:
        """
        Advance read position by `size`. Must not exceed available().
        Does not compact; caller must call compact_from() when needed.
        """
        if size < 0:
            raise Error(
                "consume size must be non-negative, got " + String(size)
            )
        if size > self.available():
            raise Error(
                "Cannot consume "
                + String(size)
                + " bytes: only "
                + String(self.available())
                + " available"
            )
        self._head += size

    # TODO: Remove if not needed
    @always_inline
    fn ensure_available(mut self, min_bytes: Int) raises -> Bool:
        """
        Refill until available() >= min_bytes or source exhausted.
        Returns False only when no more data can be read.
        """
        while self.available() < min_bytes:
            if self._fill_buffer() == 0:
                return False
        return True

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
        if not self.ensure_available(size):
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
        self.consume(size)
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
        self._compact_from(0)
        var new_capacity = min(self.capacity() + additional, max_capacity)
        _ = self._resize_internal(new_capacity)

    @always_inline
    fn view(ref self) raises -> Span[Byte, MutExternalOrigin]:
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

        @parameter
        if Self.check_ascii:
            var s = self.view()
            _check_ascii(s)
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
