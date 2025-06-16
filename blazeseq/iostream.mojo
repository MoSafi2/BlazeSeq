from memory import memcpy, UnsafePointer, Span
from blazeseq.CONSTS import DEFAULT_CAPACITY
from blazeseq.utils import _check_ascii, _get_next_line_index, _strip_spaces
from pathlib import Path
from utils import StaticTuple


alias NEW_LINE = 10

# Implement functionality from: Buffer-Reudx rust cate allowing for BufferedReader that supports partial reading and filling ,
# https://github.com/dignifiedquire/buffer-redux
# Minimial Implementation that support only line iterations


trait Reader:
    fn read_to_buffer(
        mut self, mut buf: InnerBuffer, amt: Int, pos: Int
    ) raises -> UInt64:
        ...

    fn __moveinit__(out self, owned other: Self):
        ...


struct FileReader(Movable, Reader):
    var handle: FileHandle

    fn __init__(out self, path: Path) raises:
        self.handle = open(path, "r")

    @always_inline
    fn read_bytes(mut self, amt: Int = -1) raises -> List[Byte]:
        return self.handle.read_bytes(amt)

    # TODO: Change this to take a mut Span or or UnsafePointer when possible
    @always_inline
    fn read_to_buffer(
        mut self, mut buf: InnerBuffer, amt: Int, pos: Int = 0
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


# TODO: Should be generic over reader
struct BufferedLineIterator[R: Reader, check_ascii: Bool = False](Sized):
    """A poor man's BufferedReader and LineIterator that takes as input a FileHandle or an in-memory Tensor and provides a buffered reader on-top with default capactiy.
    """

    var source: R
    var buf: InnerBuffer
    var head: Int
    var end: Int
    var IS_EOF: Bool

    fn __init__(
        out self, owned reader: R, capacity: Int = DEFAULT_CAPACITY
    ) raises:
        self.source = reader^
        self.buf = InnerBuffer(capacity)
        self.head = 0
        self.end = 0
        self.IS_EOF = False

    @always_inline
    fn _left_shift(mut self) raises:
        if self.head == 0:
            return
        var no_items = self.len()
        var dest_ptr: UnsafePointer[UInt8] = self.buf.ptr
        var src_ptr: UnsafePointer[UInt8] = self.buf.ptr + self.head
        memcpy(dest_ptr, src_ptr, no_items)
        self.head = 0
        self.end = no_items

    @always_inline
    fn _check_buf_state(mut self) -> Bool:
        if self.head >= self.end:
            self.head = 0
            self.end = 0
            return True
        else:
            return False

    @always_inline
    fn _fill_buffer(mut self) raises -> UInt64:
        """Returns the number of bytes read into the buffer."""
        if self.IS_EOF:
            return 0

        self._left_shift()
        var nels = self.uninatialized_space()
        var amt = self.source.read_to_buffer(self.buf, nels, self.end)

        self.end += Int(amt)
        if amt < nels:
            self.IS_EOF = True

        @parameter
        if check_ascii:
            var s = self.buf.as_span()[self.head : self.end]
            _check_ascii(s)

        return amt

    @always_inline
    fn len(self) -> Int:
        return self.end - self.head

    @always_inline
    fn capacity(self) -> Int:
        return self.buf._len

    @always_inline
    fn uninatialized_space(self) -> Int:
        return self.capacity() - self.end

    @always_inline
    fn usable_space(self) -> Int:
        return self.uninatialized_space() + self.head

    @always_inline
    fn get_next_line(mut self) raises -> String:
        var line_coord = self._line_coord()
        st_line = st_line = _strip_spaces(line_coord)
        return String(bytes=st_line)

    fn get_next_line_bytes(mut self) raises -> List[Byte]:
        var line_coord = self._line_coord()
        st_line = st_line = _strip_spaces(line_coord)
        return List[Byte](st_line)

    @always_inline
    fn get_next_line_span(mut self) raises -> Span[Byte, __origin_of(self.buf)]:
        line = self._line_coord()
        st_line = _strip_spaces(line)
        return st_line

    # @always_inline
    # fn _line_coord(mut self) raises -> Span[Byte, __origin_of(self.buf)]:
    #     if self._check_buf_state():
    #         _ = self._fill_buffer()
    #     var line_start = self.head
    #     var line_end = _get_next_line_index(self.as_span_mut(), self.head)

    #     if line_end == -1 and self.IS_EOF and self.head == self.end:
    #         raise Error("EOF")

    #     # EOF with no newline
    #     if line_end == -1 and self.IS_EOF and self.head != self.end:
    #         self.head = self.end
    #         return self[line_start : self.end]

    #     # Handle Broken line
    #     if line_end == -1:
    #         _ = self._fill_buffer()
    #         line_start = self.head
    #         line_end = line_start + _get_next_line_index(
    #             self.as_span_mut(), self.head
    #         )

    #     if line_end == -1:
    #         raise Error(
    #             "can't find the line end, buffer maybe too small. consider"
    #             " increasing buffer size"
    #         )

    #     self.head = line_end + 1
    #     return self[line_start:line_end]

    fn get_next_n_line_spans[
        n: Int
    ](mut self) raises -> StaticTuple[Span[Byte, __origin_of(self.buf)], n]:
        """
        Gets n line spans, ensuring all lines are fully in the buffer upon return.
        This function will attempt to read enough data to contain all 'n' lines.
        If a line is broken, it will attempt to fill the buffer to complete it.
        The returned Spans will point to valid data within the buffer.
        """
        var line_boundaries = StaticTuple[StaticTuple[Int, 2], n]()
        var current_offset = self.head  # Track the current position within the buffer as we scan

        for i in range(n):
            var line_start = current_offset - self.head  # Keeping the line start relative to the internal n line buffer.
            var line_end = -1

            while True:
                var scan_span = self.buf.as_span()[current_offset : self.end]
                line_end = _get_next_line_index(scan_span, line_start)

                if line_end != -1:
                    line_boundaries[i] = StaticTuple[Int, 2](line_start, line_end)
                    break
                else:
                    if self.IS_EOF:
                        if current_offset == self.end and i == 0:
                            raise Error("EOF")
                        elif current_offset < self.end:
                            line_end = self.end
                            break
                        else:
                            break  # No more lines to find, return what we have

                    var line_offset_after_refill = current_offset - self.head
                    _ = self._fill_buffer()

                    current_offset = self.head + line_offset_after_refill
                    line_start = current_offset - self.head

                if not self.IS_EOF and self.len() == 0:
                    raise Error(
                        "Buffer underflow after fill, cannot find line end."
                    )

                if (
                    line_end == -1
                ):  # This means we broke out of the inner loop because of EOF and no more lines
                    break

            # Store the absolute start and end indices of the line within the buffer
            # line_boundaries.append((line_start_temp, ))
            current_offset = (
                line_end + 1
            )  # Move to the start of the next potential line

        # All line boundaries are found relative to the buffer's state *after* the last fill.
        # Now, consume the lines by advancing self.head and construct the actual Span objects.
        result_spans = StaticTuple[Span[Byte, __origin_of(self.buf)], n]()
        for i in range(len(line_boundaries)):
            var start_idx = line_boundaries[i][0]
            var end_idx = line_boundaries[i][1]
            result_spans[i] = self.buf.as_span()[start_idx:end_idx]

        # Advance self.head for the next call to get_next_line or get_next_n_line_spans
        # if len(line_boundaries) > 0:
        #     self.head = line_boundaries[len(line_boundaries) - 1][1] + 1
        # else:
        #     # If no lines were found (e.g., EOF immediately), ensure head is at end
        #     if self.IS_EOF:
        #         self.head = self.end

        # # Ensure that if self.head catches up to self.end, we reset them for the next fill
        # if self.head >= self.end:
        #     self.head = 0
        #     self.end = 0

        # return result_spans
        return line_boundaries

    @always_inline
    fn _line_coord(mut self) raises -> Span[Byte, __origin_of(self.buf)]:
        """
        Retrieves a single line span. This function now operates by finding a line
        and returning its span, handling buffer filling and shifting as needed.
        It advances self.head after finding a line.
        """
        if self._check_buf_state():
            _ = self._fill_buffer()

        var line_start = self.head
        var line_end = -1

        while line_end == -1:
            var current_scan_span = self.buf.as_span()[self.head : self.end]
            line_end = _get_next_line_index(current_scan_span, self.head)

            if line_end != -1:
                break
            else:
                # Newline not found, need to fill buffer
                if self.IS_EOF:
                    if self.head == self.end:
                        raise Error("EOF")
                    else:
                        # This is the last partial line at EOF
                        line_end = self.end
                        break

                _ = self._fill_buffer()
                line_start = self.head

                if (
                    self.IS_EOF
                    and _get_next_line_index(
                        self.buf.as_span()[self.head : self.end], 0
                    )
                    == -1
                ):
                    line_end = self.end
                    break
                elif not self.IS_EOF and self.len() == 0:
                    raise Error(
                        "Buffer underflow after fill, cannot find line end."
                    )

        var final_line_span = self[line_start:line_end]
        self.head = line_end + 1

        return final_line_span

    @always_inline
    fn _resize_buf(mut self, amt: Int, max_capacity: Int) raises:
        if self.capacity() == max_capacity:
            raise Error("Buffer is at max capacity")
        var nels: Int
        if self.capacity() + amt > max_capacity:
            nels = max_capacity
        else:
            nels = self.capacity() + amt
        _ = self.buf.resize(nels)

    @always_inline
    fn as_span(self) raises -> Span[Byte, __origin_of(self.buf)]:
        return self.buf.as_span()[self.head : self.end]

    fn as_span_mut(mut self) raises -> Span[Byte, __origin_of(self.buf)]:
        return self.buf.as_span()[self.head : self.end]

    @always_inline
    fn __len__(self) -> Int:
        return self.end - self.head

    @always_inline
    fn __str__(self) raises -> String:
        var s = self.buf.as_span()
        sl = slice(self.head, self.end)
        return String(bytes=s.__getitem__(sl))

    @always_inline
    fn __getitem__(self, index: Int) raises -> Byte:
        if self.head > index or index >= self.end:
            raise Error("Out of bounds")
        return self.buf[index]

    @always_inline
    fn __getitem__(
        mut self, sl: Slice
    ) raises -> Span[Byte, __origin_of(self.buf)]:
        start = sl.start.or_else(self.head)
        end = sl.end.or_else(self.end)
        step = sl.step.or_else(1)

        if end <= self.end:
            var _slice = self.buf.__getitem__(slice(start, end, step))
            return _slice
        else:
            raise Error("Out of bounds")


struct InnerBuffer(Movable, Copyable):
    var ptr: UnsafePointer[Byte]
    var _len: Int

    fn __init__(out self, length: Int):
        self.ptr = UnsafePointer[Byte].alloc(length)
        self._len = length

    # TODO: Check if this constructor is necessary
    fn __init__(out self, ptr: UnsafePointer[Byte], length: Int):
        self.ptr = ptr
        self._len = length

    fn __getitem__(self, index: Int) raises -> Byte:
        if index < self._len:
            return self.ptr[index]
        else:
            raise Error("Out of bounds")

    fn __getitem__(
        mut self, slice: Slice
    ) raises -> Span[Byte, __origin_of(self)]:
        var start = slice.start.or_else(0)
        var end = slice.end.or_else(self._len)
        var step = slice.step.or_else(1)

        if step > 1:
            raise Error("Step loading is not supported")

        if start < 0 or end > self._len:
            raise Error("Out of bounds")
        len = end - start
        ptr = self.ptr + start
        return Span[Byte, __origin_of(self)](ptr=ptr, length=len)

    fn __setitem__(mut self, index: Int, value: Byte) raises:
        if index < self._len:
            self.ptr[index] = value
        else:
            raise Error("Out of bounds")

    fn resize(mut self, new_len: Int) raises -> Bool:
        if new_len < self._len:
            raise Error("New length must be greater than current length")
        var new_ptr = UnsafePointer[Byte].alloc(new_len)
        memcpy(dest=new_ptr, src=self.ptr, count=self._len)
        self.ptr = new_ptr
        self._len = new_len
        return True

    fn as_span[
        mut: Bool, //, o: Origin[mut]
    ](ref [o]self, pos: Int = 0) raises -> Span[Byte, o]:
        if pos > self._len:
            raise Error("Position is outside the buffer")
        return Span[Byte, o](ptr=self.ptr + pos, length=self._len - pos)

    fn __del__(owned self):
        if self.ptr:
            self.ptr.free()
