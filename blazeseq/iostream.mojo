from memory import memcpy, UnsafePointer, Span, alloc
from blazeseq.CONSTS import DEFAULT_CAPACITY
from blazeseq.utils import _check_ascii, _strip_spaces
from pathlib import Path
from utils import StaticTuple
from blazeseq.utils import memchr
from builtin.builtin_slice import ContiguousSlice


comptime NEW_LINE = 10


# Helper struct for Reader trait to access buffer
@fieldwise_init
struct BufferView:
    var ptr: UnsafePointer[Byte, origin=MutExternalOrigin]
    var _len: Int

    fn as_span(self, pos: Int = 0) raises -> Span[Byte, MutExternalOrigin]:
        if pos > self._len:
            raise Error("Position is outside the buffer")
        return Span[Byte, MutExternalOrigin](
            ptr=self.ptr + pos, length=self._len - pos
        )


trait Reader:
    fn read_to_buffer(
        mut self, mut buf: BufferView, amt: Int, pos: Int
    ) raises -> UInt64:
        ...

    fn __moveinit__(out self, deinit other: Self):
        ...


# Implement functionality from: Buffer-Reudx rust cate allowing for BufferedReader that supports partial reading and filling ,
# https://github.com/dignifiedquire/buffer-redux
# Minimial Implementation that support only line iterations


struct FileReader(Movable, Reader):
    var handle: FileHandle

    fn __init__(out self, path: Path) raises:
        self.handle = open(path, "r")

    @always_inline
    fn read_bytes(mut self, amt: Int = -1) raises -> List[Byte]:
        return self.handle.read_bytes(amt)

    @always_inline
    fn read_to_buffer(
        mut self, mut buf: BufferView, amt: Int, pos: Int = 0
    ) raises -> UInt64:
        s = buf.as_span(pos=pos)
        if amt > len(s):
            raise Error(
                "Number of elements to read is bigger than the available space"
                " in the buffer"
            )
        if amt < 0:
            raise Error("The amount to be read should be positive")
        read = self.handle.read(buffer=s)
        return read


struct BufferedReader[R: Reader, check_ascii: Bool = False](
    Movable, Sized, Writable
):
    var source: Self.R
    var ptr: UnsafePointer[Byte, origin=MutExternalOrigin]
    var _len: Int  # Buffer capacity
    var head: Int
    var end: Int
    var IS_EOF: Bool

    fn __init__(
        out self, var reader: Self.R, capacity: Int = DEFAULT_CAPACITY
    ) raises:
        self.source = reader^
        self.ptr = alloc[Byte](capacity)
        self._len = capacity
        self.head = 0
        self.end = 0
        self.IS_EOF = False
        _ = self._fill_buffer()

    fn __del__(deinit self):
        if self.ptr:
            self.ptr.free()

    @always_inline
    fn _get_buffer_view(mut self) -> BufferView:
        return BufferView(ptr=self.ptr, _len=self._len)

    @always_inline
    fn _left_shift(mut self) raises:
        if self.head == 0:
            return
        var no_items = len(self)
        var dest_ptr = self.ptr
        var src_ptr = self.ptr + self.head
        memcpy(dest=dest_ptr, src=src_ptr, count=no_items)
        self.head = 0
        self.end = no_items

    @always_inline
    fn _left_shift_from(mut self, from_pos: Int) raises:
        """Shifts buffer data starting from `from_pos` to position 0.
        Updates `head` and `end` accordingly to maintain correct buffer state.
        """
        if from_pos >= self.end:
            # Nothing to shift
            self.head = 0
            self.end = 0
            return
        if from_pos == 0:
            # Already at start, do regular left shift from head
            self._left_shift()
            return

        var no_items = self.end - from_pos
        var dest_ptr = self.ptr
        var src_ptr = self.ptr + from_pos
        memcpy(dest=dest_ptr, src=src_ptr, count=no_items)
        # Update head relative to the shift
        self.head = self.head - from_pos
        if self.head < 0:
            self.head = 0
        self.end = no_items

    @always_inline
    fn _fill_buffer(mut self) raises -> UInt64:
        """Returns the number of bytes read into the buffer."""
        if self.IS_EOF:
            return 0

        self._left_shift()
        var nels = self.uninatialized_space()
        var buf_view = self._get_buffer_view()
        var amt = self.source.read_to_buffer(buf_view, nels, self.end)
        self.end += Int(amt)
        if amt == 0 or amt < nels:
            self.IS_EOF = True

        @parameter
        if Self.check_ascii:
            var s = self._as_span_internal()
            _check_ascii(s)
        return amt

    @always_inline
    fn capacity(self) -> Int:
        return self._len

    @always_inline
    fn uninatialized_space(self) -> Int:
        return self.capacity() - self.end

    @always_inline
    fn usable_space(self) -> Int:
        return self.uninatialized_space() + self.head

    @always_inline
    fn get_next_line(mut self) raises -> String:
        line_coord = self._line_coord()
        st_line = _strip_spaces(line_coord)
        return String(unsafe_from_utf8=st_line)

    fn get_next_line_bytes(mut self) raises -> List[Byte]:
        line_coord = self._line_coord()
        st_line = _strip_spaces(line_coord)
        return List[Byte](st_line)

    @always_inline
    fn get_next_line_span(mut self) raises -> Span[Byte, MutExternalOrigin]:
        line = self._line_coord()
        st_line = _strip_spaces(line)
        return st_line

    fn get_n_lines[
        n: Int
    ](mut self) raises -> InlineArray[Span[Byte, MutExternalOrigin], n]:
        """Returns exactly n lines from the buffer.

        All lines are guaranteed to be in the buffer until the method is called again.
        The buffer is not left-shifted so that earlier lines remain accessible.
        If buffer runs out before getting all n lines, performs a left-shift
        starting from the first line of the batch (not from head).

        Returns:
            List of spans referencing the lines in the buffer.

        Raises:
            Error: If EOF is reached before getting all requested lines.
            Error: If a line is longer than buffer capacity.
        """
        if n == 0:
            return InlineArray[Span[Byte, MutExternalOrigin], n](
                uninitialized=True
            )

        var batch_start = self.head  # Start of first line in batch

        while True:
            var results = InlineArray[Span[Byte, MutExternalOrigin], n](
                uninitialized=True
            )
            var current_pos = batch_start  # Start from batch_start (first line)
            var need_refill = False

            for i in range(n):
                # Find the end of the current line
                while True:
                    var search_span = self._as_span_internal()[: self.end]
                    var line_end = memchr(
                        haystack=search_span, chr=NEW_LINE, start=current_pos
                    )

                    if line_end != -1:
                        # Found newline, add line to results
                        var line_span = self._as_span_internal()[
                            current_pos:line_end
                        ]
                        results[i] = line_span
                        current_pos = line_end + 1
                        break

                    # No newline found, check if we're at EOF
                    if self.IS_EOF:
                        if current_pos < self.end:
                            # Last line without newline
                            var line_span = self._as_span_internal()[
                                current_pos : self.end
                            ]
                            results[i] = line_span
                            current_pos = self.end
                            # Check if we got enough lines
                            if len(results) < n:
                                raise Error(
                                    "EOF reached before getting all requested"
                                    " lines"
                                )
                            # Successfully got all n lines
                            self.head = current_pos
                            return results^
                        else:
                            # EOF and no more data
                            raise Error(
                                "EOF reached before getting all requested lines"
                            )

                    # Need more buffer space - mark that we need to refill and restart
                    need_refill = True
                    # Check if we have enough space after shifting from batch_start
                    var data_to_preserve = self.end - batch_start
                    if data_to_preserve > self.capacity():
                        raise Error(
                            "Batch of lines is longer than the buffer capacity."
                        )

                    # Shift buffer from batch_start to preserve all lines in batch
                    self._left_shift_from(batch_start)
                    batch_start = 0  # After shift, batch starts at 0

                    # Fill buffer with more data
                    if self.IS_EOF:
                        raise Error(
                            "EOF reached before getting all requested lines"
                        )

                    var nels = self.uninatialized_space()
                    var buf_view = self._get_buffer_view()
                    var amt = self.source.read_to_buffer(
                        buf_view, nels, self.end
                    )
                    self.end += Int(amt)
                    if amt == 0 or amt < nels:
                        self.IS_EOF = True

                    # Break inner while loop - we'll restart reading all n lines from batch_start
                    break

                # If we need refill, break from for loop to restart
                if need_refill:
                    break

            # If we successfully read all n lines without needing refill, return results
            if not need_refill:
                self.head = current_pos
                return results^
            # Otherwise, loop continues and we restart reading all n lines from batch_start

    @always_inline
    fn _line_coord(mut self) raises -> Span[Byte, MutExternalOrigin]:
        while True:
            var search_span = self._as_span_internal()[: self.end]
            var line_end = memchr(
                haystack=search_span, chr=NEW_LINE, start=self.head
            )
            if line_end != -1:
                start = self.head
                self.head = line_end + 1
                return self._as_span_internal()[start:line_end]

            if self.IS_EOF:
                if self.head < self.end:
                    start = self.head
                    self.head = self.end
                    return self._as_span_internal()[start : self.end]
                else:
                    raise Error("EOF")

            if self.usable_space() == 0:
                raise Error("Line is longer than the buffer capacity.")
            _ = self._fill_buffer()

    @always_inline
    fn _resize_buf(mut self, amt: Int, max_capacity: Int) raises:
        """Resizes Buffer by adding specific amount to the end of the buffer"""
        if self.capacity() == max_capacity:
            raise Error("Buffer is at max capacity")

        var new_capacity: Int

        if self.capacity() + amt > max_capacity:
            new_capacity = max_capacity
        else:
            new_capacity = self.capacity() + amt

        _ = self._resize_internal(new_capacity)

    @always_inline
    fn as_span(ref self) raises -> Span[Byte, MutExternalOrigin]:
        # Return span with MutExternalOrigin - lifetime tracked through ref self
        return Span[Byte, MutExternalOrigin](
            ptr=self.ptr + self.head, length=self.end - self.head
        )

    @always_inline
    fn _as_span_internal(ref self) -> Span[Byte, MutExternalOrigin]:
        # Helper to get full buffer span
        return Span[Byte, MutExternalOrigin](ptr=self.ptr, length=self._len)

    # Suggestion from Claude To avoid Error catching when reading till last line
    @always_inline
    fn has_more_lines(self) -> Bool:
        """Returns True if there are more lines available to read."""
        if self.head < self.end:
            return True
        if not self.IS_EOF:
            return True
        return False

    # fn as_span_mut(mut self) raises -> Span[Byte, MutExternalOrigin]:
    #     return self.buf.as_span()[self.head : self.end]

    @always_inline
    fn __len__(self) -> Int:
        return self.end - self.head

    @always_inline
    fn __str__(self) raises -> String:
        var x = String(capacity=len(self))
        self.write_to(x)
        return x

    @always_inline
    fn __getitem__(self, index: Int) raises -> Byte:
        if index < self.head or index >= self.end:
            raise Error("Out of bounds")
        return self.ptr[index]


    @always_inline
    fn __getitem__(mut self, sl: Slice) raises -> Span[Byte, MutExternalOrigin]:
        start = sl.start.or_else(self.head)
        end = sl.end.or_else(self.end)
        step = sl.step.or_else(1)

        if step > 1:
            raise Error("Step loading is not supported")

        if start < self.head or end > self.end:
            raise Error("Out of bounds")

        var len = end - start
        var ptr = self.ptr + start
        return Span[Byte, MutExternalOrigin](ptr=ptr, length=len)

    fn write_to[w: Writer](self, mut writer: w):
        try:
            writer.write_bytes(self.as_span())
        except:
            writer.write("")

    @always_inline
    fn _resize_internal(mut self, new_len: Int) raises -> Bool:
        if new_len < self._len:
            raise Error("New length must be greater than current length")
        var new_ptr = alloc[Byte](new_len)
        memcpy(dest=new_ptr, src=self.ptr, count=self._len)
        self.ptr.free()
        self.ptr = new_ptr
        self._len = new_len
        return True
