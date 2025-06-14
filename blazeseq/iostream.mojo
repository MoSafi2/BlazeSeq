from memory import memcpy, UnsafePointer, Span
from blazeseq.CONSTS import (
    simd_width,
    U8,
    DEFAULT_CAPACITY,
    MAX_CAPACITY,
    MAX_SHIFT,
    carriage_return,
)
from pathlib import Path
import time
import math


alias NEW_LINE = 10

# Implement functionality from: Buffer-Reudx rust cate allowing for BufferedReader that supports partial reading and filling ,
# https://github.com/dignifiedquire/buffer-redux
# Minimial Implementation that support only line iterations


trait Reader:
    pass

    fn read_bytes(mut self, amt: Int) raises -> List[Byte]:
        ...

    fn read_to_buffer(
        mut self, mut buf: BufferedLineIterator, buf_pos: Int, amt: Int
    ) raises -> Int64:
        ...

    fn __moveinit__(out self, owned other: Self):
        ...


struct FileReader(Movable):
    var handle: FileHandle

    fn __init__(out self, path: Path) raises:
        self.handle = open(path, "r")

    @always_inline
    fn read_bytes(mut self, amt: Int = -1) raises -> List[Byte]:
        return self.handle.read_bytes(amt)

    # TODO: Change this to take a mut Span or or UnsafePointer
    @always_inline
    fn read_to_buffer(
        mut self, mut buf: InnerBuffer, amt: Int, pos: Int = 0
    ) raises -> UInt64:
        s = buf.as_span_mut(pos=pos)
        if amt > len(s):
            raise Error(
                "Number of elements to read is bigger than the available space"
                " in the buffer"
            )
        if amt < 0:
            raise Error("The amount to be read should be positive")
        read = self.handle.read(buffer=s)
        return read


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

    fn as_span(self, pos: Int = 0) raises -> Span[Byte, __origin_of(self)]:
        if pos > self._len:
            raise Error("Position is outside the buffer")
        return Span[Byte, __origin_of(self)](
            ptr=self.ptr + pos, length=self._len - pos
        )

    fn as_span_mut(
        mut self, pos: Int = 0
    ) raises -> Span[Byte, __origin_of(self)]:
        if pos > self._len:
            raise Error("Position is outside the buffer")
        return Span[Byte, __origin_of(self)](
            ptr=self.ptr + pos, length=self._len - pos
        )

    fn __del__(owned self):
        if self.ptr:
            self.ptr.free()


# TODO: Should be generic over reader
struct BufferedLineIterator[check_ascii: Bool = False](Sized):
    """A poor man's BufferedReader and LineIterator that takes as input a FileHandle or an in-memory Tensor and provides a buffered reader on-top with default capactiy.
    """

    var source: FileReader
    var buf: InnerBuffer
    var head: Int
    var end: Int
    var IS_EOF: Bool

    fn __init__(out self, path: Path, capacity: Int = DEFAULT_CAPACITY) raises:
        if path.exists():
            self.source = FileReader(path)
        else:
            raise Error("Provided file not found for read")

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
            self._check_ascii()

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

    # TODO: Check how safe this function is and if it can return null buffer
    @always_inline
    fn _line_coord(mut self) raises -> Span[Byte, __origin_of(self.buf)]:
        if self._check_buf_state():
            _ = self._fill_buffer()
        var line_start = self.head
        var line_end = self._get_next_line_index()

        # EOF with no newline
        if line_end == -1 and self.IS_EOF and self.head != self.end:
            return self[line_start : self.end]

        # Handle Broken line
        if line_end == -1:
            _ = self._fill_buffer()
            line_end = self._get_next_line_index()

        if line_end == -1:
            raise Error(
                "can't find the line end, buffer maybe too small. consider"
                " increasing buffer size"
            )

        # sl = Slice(line_start, line_end)
        # sl_stripped = self._strip_spaces(sl)
        self.head = line_end + 1
        return self[line_start:line_end]

    # @always_inline
    # fn _line_coord_missing_line(mut self) raises -> Slice:
    #     self._resize_buf(self.capacity(), MAX_CAPACITY)
    #     _ = self._fill_buffer()
    #     var line_start = self.head
    #     var line_end = self._get_next_line_index()
    #     self.head = line_end + 1
    #     return slice(line_start, line_end)

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
    fn _check_ascii(self) raises:
        var aligned_end = math.align_down(self.len(), simd_width) + self.head
        alias bit_mask: UInt8 = 0x80  # Non negative
        for i in range(self.head, aligned_end, simd_width):
            var vec = self.buf.ptr.load[width=simd_width](i)
            if (vec & bit_mask).reduce_or():
                raise Error("Non ASCII letters found")

        for i in range(aligned_end, self.end):
            if self.buf[i] & bit_mask != 0:
                raise Error("Non ASCII letters found")

    # TODO: Should be free-standing function to find a haystack in a buffer and return an Index, sliceing should be done some where else.
    # TODO: Benchmark this implementation agaist ExtraMojo implementation
    @always_inline
    fn _get_next_line_index(self) raises -> Int:
        var aligned_end = math.align_down(self.len(), simd_width) + self.head
        for i in range(self.head, aligned_end, simd_width):
            var v = self.buf.ptr.load[width=simd_width](i)
            var mask = v == NEW_LINE
            if mask.reduce_or():
                return i + arg_true(mask)

        for i in range(aligned_end, self.end):
            if self.buf[i] == NEW_LINE:
                return i
        return -1

    # TODO: Should be free-standing function to find a haystack in a buffer and return an Index, sliceing should be done some where else.
    # TODO: Should get a Span instead of a slice
    @always_inline
    fn _strip_spaces(self, in_slice: Slice) raises -> Slice:
        var start = in_slice.start.or_else(0)
        var end = in_slice.end.or_else(0)
        len = end - start
        for i in range(len):
            if not is_posix_space(self.buf[i]):
                start = i
                break
        for i in range(len, 0):
            if not is_posix_space(self.buf[i]):
                end = i
                break
        return Slice(start, end)

    @always_inline
    fn __len__(self) -> Int:
        return self.end - self.head

    @always_inline
    fn __str__(self) raises -> String:
        var s = self.buf.as_span()
        sl = slice(self.head, self.end)
        return String(bytes=s.__getitem__(sl))

    fn __getitem__(self, index: Int) raises -> Byte:
        if self.head > index or index >= self.end:
            raise Error("Out of bounds")
        return self.buf[index]

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


@always_inline
fn arg_true[simd_width: Int](v: SIMD[DType.bool, simd_width]) -> Int:
    for i in range(simd_width):
        if v[i]:
            return i
    return -1


@always_inline
fn _strip_spaces[
    mut: Bool, //, o: Origin[mut]
](in_slice: Span[Byte, o]) raises -> Span[Byte, o]:

    var start = 0
    var end = len(in_slice)
    for i in range(len(in_slice)):
        if not is_posix_space(in_slice[i]):
            start = i
            break
    for i in range(len(in_slice), -1, -1):
        if not is_posix_space(in_slice[i]):
            end = i
            break
    out_span = Span[Byte, o](
        ptr=in_slice.unsafe_ptr() + start, length=end - start
    )

    print(String(bytes=out_span))
    return out_span


# Ported from the is_posix_space() in Mojo Stdlib
@always_inline
fn is_posix_space(c: Byte) -> Bool:
    alias SPACE = Byte(ord(" "))
    alias HORIZONTAL_TAB = Byte(ord("\t"))
    alias NEW_LINE = Byte(ord("\n"))
    alias CARRIAGE_RETURN = Byte(ord("\r"))
    alias FORM_FEED = Byte(ord("\f"))
    alias VERTICAL_TAB = Byte(ord("\v"))
    alias FILE_SEP = Byte(ord("\x1c"))
    alias GROUP_SEP = Byte(ord("\x1d"))
    alias RECORD_SEP = Byte(ord("\x1e"))

    # This compiles to something very clever that's even faster than a LUT.
    return (
        c == SPACE
        or c == HORIZONTAL_TAB
        or c == NEW_LINE
        or c == CARRIAGE_RETURN
        or c == FORM_FEED
        or c == VERTICAL_TAB
        or c == FILE_SEP
        or c == GROUP_SEP
        or c == RECORD_SEP
    )


# fn main() raises:
#     var path = Path(
#         "/home/mohamed/Documents/Projects/BlazeSeq/data/SRR4381933_1.fastq"
#     )
#     var reader = BufferedLineIterator(path, capacity=256)

#     var n = 0
#     t1 = time.perf_counter_ns()
#     while True:
#         try:
#             var line = reader.read_next_coord()
#             print(StringSlice[origin=StaticConstantOrigin](
#                 ptr=line.unsafe_ptr(), length=len(line)
#             ))
#             n += 1
#             if n == 50:
#                 break
#         except Error:
#             print(Error)
#             break
#     print(n)
#     t2 = time.perf_counter_ns()
#     print("Time taken:", (t2 - t1) / 1e9)
