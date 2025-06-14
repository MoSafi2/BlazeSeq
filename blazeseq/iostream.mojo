from memory import memcpy, UnsafePointer, Span
from blazeseq.CONSTS import DEFAULT_CAPACITY
from blazeseq.utils import _check_ascii, _get_next_line_index, _strip_spaces
from pathlib import Path


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

    @always_inline
    fn get_next_line_span(mut self) raises -> Span[Byte, __origin_of(self.buf)]:
        line = self._line_coord()
        st_line = _strip_spaces(line)
        return st_line

    @always_inline
    fn _line_coord(mut self) raises -> Span[Byte, __origin_of(self.buf)]:
        if self._check_buf_state():
            _ = self._fill_buffer()
        var line_start = self.head
        var line_end = _get_next_line_index(self.as_span_mut(), self.head)

        if line_end == -1 and self.IS_EOF and self.head == self.end:
            raise Error("EOF")

        # EOF with no newline
        if line_end == -1 and self.IS_EOF and self.head != self.end:
            self.head = self.end
            return self[line_start : self.end]

        # Handle Broken line
        if line_end == -1:
            _ = self._fill_buffer()
            line_start = self.head
            line_end = line_start + _get_next_line_index(
                self.as_span_mut(), self.head
            )

        if line_end == -1:
            raise Error(
                "can't find the line end, buffer maybe too small. consider"
                " increasing buffer size"
            )

        self.head = line_end + 1
        return self[line_start:line_end]

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
