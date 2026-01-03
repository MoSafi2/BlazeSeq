from memory import memcpy, UnsafePointer, Span, alloc
from blazeseq.CONSTS import DEFAULT_CAPACITY
from blazeseq.utils import _check_ascii, _strip_spaces
from pathlib import Path
from utils import StaticTuple
from blazeseq.utils import memchr


comptime NEW_LINE = 10


trait Reader:
    fn read_to_buffer(
        mut self, mut buf: InnerBuffer, amt: Int, pos: Int
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


struct BufferedReader[R: Reader, check_ascii: Bool = False](
    Movable, Sized, Writable
):
    var source: Self.R
    var buf: InnerBuffer
    var head: Int
    var end: Int
    var IS_EOF: Bool

    fn __init__(
        out self, var reader: Self.R, capacity: Int = DEFAULT_CAPACITY
    ) raises:
        self.source = reader^
        self.buf = InnerBuffer(capacity)
        self.head = 0
        self.end = 0
        self.IS_EOF = False
        _ = self._fill_buffer()

    @always_inline
    fn _left_shift(mut self) raises:
        if self.head == 0:
            return
        var no_items = len(self)
        var dest_ptr = self.buf.ptr
        var src_ptr = self.buf.ptr + self.head
        memcpy(dest=dest_ptr, src=src_ptr, count=no_items)
        self.head = 0
        self.end = no_items

    # @always_inline
    # fn _check_buf_state(mut self) -> Bool:
    #     if self.head >= self.end:
    #         self.head = 0
    #         self.end = 0
    #         return True
    #     else:
    #         return False

    @always_inline
    fn _fill_buffer(mut self) raises -> UInt64:
        """Returns the number of bytes read into the buffer."""
        if self.IS_EOF:
            return 0

        self._left_shift()
        var nels = self.uninatialized_space()
        var amt = self.source.read_to_buffer(self.buf, nels, self.end)
        self.end += Int(amt)
        if amt == 0 or amt < nels:
            self.IS_EOF = True

        @parameter
        if Self.check_ascii:
            var s = self.buf.as_span()
            _check_ascii(s)
        return amt

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
        line_coord = self._line_coord()
        st_line = _strip_spaces(line_coord)
        return String(bytes=st_line)

    fn get_next_line_bytes(mut self) raises -> List[Byte]:
        line_coord = self._line_coord()
        st_line = _strip_spaces(line_coord)
        return List[Byte](st_line)

    @always_inline
    fn get_next_line_span(mut self) raises -> Span[Byte, MutOrigin.external]:
        line = self._line_coord()
        st_line = _strip_spaces(line)
        return st_line

    @always_inline
    fn _line_coord(mut self) raises -> Span[Byte, MutOrigin.external]:
        while True:
            var search_span = self.buf.as_span()[: self.end]
            var line_end = memchr(
                haystack=search_span, chr=NEW_LINE, start=self.head
            )
            if line_end != -1:
                start = self.head
                self.head = line_end + 1
                return self.buf.as_span()[start:line_end]

            if self.IS_EOF:
                if self.head < self.end:
                    start = self.head
                    self.head = self.end
                    return self.buf.as_span()[start : self.end]
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

        _ = self.buf.resize(new_capacity)

    @always_inline
    fn as_span(self) raises -> Span[Byte, MutOrigin.external]:
        return self.buf.as_span()[self.head : self.end]

    # Suggestion from Claude To avoid Error catching when reading till last line
    @always_inline
    fn has_more_lines(self) -> Bool:
        """Returns True if there are more lines available to read."""
        if self.head < self.end:
            return True
        if not self.IS_EOF:
            return True
        return False

    # fn as_span_mut(mut self) raises -> Span[Byte, MutOrigin.external]:
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
        if self.head > index or self.end <= index:
            raise Error("Out of bounds")
        return self.buf[index]

    @always_inline
    fn __getitem__(
        mut self, sl: Slice
    ) raises -> Span[Byte, MutOrigin.external]:
        start = sl.start.or_else(self.head)
        end = sl.end.or_else(self.end)
        step = sl.step.or_else(1)

        if end <= self.end:
            var _slice = self.buf.__getitem__(slice(start, end, step))
            return _slice
        else:
            raise Error("Out of bounds")

    fn write_to[w: Writer](self, mut writer: w):
        try:
            writer.write_bytes(self.as_span())
        except:
            writer.write("")


struct InnerBuffer(Movable, Sized):
    var ptr: UnsafePointer[type=Byte, origin = MutOrigin.external]
    var _len: Int

    fn __init__(out self, length: Int):
        self.ptr: UnsafePointer[Byte, origin = MutOrigin.external] = alloc[
            Byte
        ](length)
        self._len = length

    fn __getitem__(self, index: Int) raises -> Byte:
        if index < self._len:
            return self.ptr[index]
        else:
            raise Error("Out of bounds")

    fn __getitem__(
        mut self, slice: Slice
    ) raises -> Span[Byte, MutOrigin.external]:
        var start = slice.start.or_else(0)
        var end = slice.end.or_else(self._len)
        var step = slice.step.or_else(1)

        if step > 1:
            raise Error("Step loading is not supported")

        if start < 0 or end > self._len:
            raise Error("Out of bounds")
        len = end - start
        ptr = self.ptr + start

        return Span[Byte, MutOrigin.external](ptr=ptr, length=len)

    fn __setitem__(mut self, index: Int, value: Byte) raises:
        if index < self._len:
            self.ptr[index] = value
        else:
            raise Error("Out of bounds")

    fn __len__(self) -> Int:
        return self._len

    fn resize(mut self, new_len: Int) raises -> Bool:
        if new_len < self._len:
            raise Error("New length must be greater than current length")
        var new_ptr = alloc[Byte](new_len)
        memcpy(dest=new_ptr, src=self.ptr, count=self._len)
        self.ptr.free()
        self.ptr = new_ptr
        self._len = new_len
        return True

    fn as_span(self, pos: Int = 0) raises -> Span[Byte, MutOrigin.external]:
        if pos > self._len:
            raise Error("Position is outside the buffer")
        return Span[Byte, MutOrigin.external](
            ptr=self.ptr + pos, length=self._len - pos
        )

    fn __del__(deinit self):
        if self.ptr:
            self.ptr.free()
