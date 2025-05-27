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


# trait Reader:
#     pass
#     fn read_bytes(mut self, amt: Int) raises -> List[UInt8]:
#         ...

#     fn read_to_buffer(
#         mut self, mut buf: BufferedLineIterator, buf_pos: Int, amt: Int
#     ) raises -> Int64:
#         ...

#     fn __moveinit__(mut self, owned other: Self):
#         ...


@fieldwise_init
struct FileReader:
    var handle: FileHandle

    fn __init__(out self, path: Path) raises:
        self.handle = open(path, "r")

    @always_inline
    fn read_bytes(mut self, amt: Int = -1) raises -> List[UInt8]:
        return self.handle.read_bytes(amt)

    @always_inline
    fn read_to_buffer(
        mut self, mut buf: InnerBuffer, amt: Int
    ) raises -> UInt64:
        s = buf.as_span[mut=True]()
        read = self.handle.read(buffer=s)
        return read

    fn __moveinit__(out self, owned other: Self):
        self.handle = other.handle^


@value
struct InnerBuffer:
    var ptr: UnsafePointer[UInt8]
    var _len: Int

    fn __init__(out self, length: Int):
        self.ptr = UnsafePointer[UInt8].alloc(length)
        self._len = length

    fn __init__(out self, ptr: UnsafePointer[UInt8], length: Int):
        self.ptr = ptr
        self._len = length

    fn __getitem__(self, index: Int) raises -> UInt8:
        if index < self._len:
            return self.ptr[index]
        else:
            raise Error("Out of bounds")

    fn __getitem__(
        mut self, slice: Slice
    ) raises -> Span[origin = __origin_of(self), T=UInt8]:
        var start = slice.start.or_else(0)
        var end = slice.end.or_else(self._len)

        if start < 0 or end > self._len:
            raise Error("Out of bounds")

        return Span[origin = __origin_of(self), T=UInt8](
            ptr=self.ptr + start, length=end - start
        )

    fn __setitem__(mut self, index: Int, value: UInt8) raises:
        if index < self._len:
            self.ptr[index] = value
        else:
            raise Error("Out of bounds")

    fn resize(mut self, new_len: Int) raises -> Bool:
        if new_len < self._len:
            raise Error("New length must be greater than current length")

        var new_ptr = UnsafePointer[UInt8].alloc(new_len)
        memcpy(dest=new_ptr, src=self.ptr, count=self._len)
        self.ptr = new_ptr
        self._len = new_len
        return True

    fn as_span[
        mut: Bool
    ](mut self) -> Span[mut=mut, T=UInt8, origin = __origin_of(self)]:
        return Span[mut=mut, T=UInt8, origin = __origin_of(self)](
            ptr=self.ptr, length=self._len
        )

    fn __del__(owned self):
        if self.ptr:
            self.ptr.free()

    fn __moveinit__(out self, owned other: Self):
        self.ptr = other.ptr
        self._len = other._len


struct BufferedLineIterator(Sized):
    """A poor man's BufferedReader and LineIterator that takes as input a FileHandle or an in-memory Tensor and provides a buffered reader on-top with default capactiy.
    """

    var source: FileReader
    var buf: InnerBuffer
    var head: Int
    var end: Int

    fn __init__(out self, path: Path, capacity: Int = DEFAULT_CAPACITY) raises:
        if path.exists():
            self.source = FileReader(path)
        else:
            raise Error("Provided file not found for read")

        self.buf = InnerBuffer(capacity)
        self.head = 0
        self.end = 0

    #         _ = self._fill_buffer()

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
        self._left_shift()
        var nels = self.uninatialized_space()
        var amt = self.source.read_to_buffer(self.buf, nels)
        # @parameter
        # if check_ascii:
        #     self._check_ascii()
        self.end += Int(amt)
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

    #     @always_inline
    #     fn read_next_line(mut self) raises -> List[UInt8]:
    #         var line_coord = self._line_coord()
    #         line_span = self.buf[line_coord]
    #         return List[UInt8](
    #             ptr=line_span.unsafe_ptr(),
    #             length=len(line_span),
    #             capacity=len(line_span),
    #         )

    #     @always_inline
    #     fn read_next_coord(
    #         mut self,
    #     ) raises -> Span[T=Byte, origin=StaticConstantOrigin]:
    #         var line_coord = self._line_coord()
    #         var ptr = self.buf.ptr + line_coord.start.or_else(0)
    #         var length = line_coord.end.or_else(0) - line_coord.start.or_else(0)
    #         return Span[T=Byte, origin=StaticConstantOrigin](ptr=ptr, length=length)

    #     @always_inline
    #     fn _line_coord(mut self) raises -> Slice:
    #         if self._check_buf_state():
    #             _ = self._fill_buffer()

    #         var coord: Slice
    #         var line_start = self.head
    #         var line_end = self._get_next_line_index()
    #         coord = Slice(line_start, line_end)

    #         # if coord.end == -1 and self.head == 0:
    #         #     for _ in range(MAX_SHIFT):
    #         #         if coord.end != -1:
    #         #             return self._handle_windows_sep(coord)
    #         #         else:
    #         #             coord = self._line_coord_missing_line()

    #         if coord.end == -1:
    #             _ = self._fill_buffer()
    #             return self._line_coord_incomplete_line()

    #         self.head = line_end + 1

    #         # # Handling Windows-syle line seperator
    #         # if self.buf[line_end] == carriage_return:
    #         #     line_end -= 1

    #         return slice(line_start, line_end)

    #     @always_inline
    #     fn _line_coord_incomplete_line(mut self) raises -> Slice:
    #         if self._check_buf_state():
    #             _ = self._fill_buffer()
    #         var line_start = self.head
    #         var line_end = self._get_next_line_index()
    #         self.head = line_end + 1

    #         if self.buf[line_end] == carriage_return:
    #             line_end -= 1
    #         return slice(line_start, line_end)

    #     @always_inline
    #     fn _line_coord_missing_line(mut self) raises -> Slice:

    #         self._resize_buf(self.capacity(), MAX_CAPACITY)
    #         _ = self._fill_buffer()
    #         var line_start = self.head
    #         var line_end = self._get_next_line_index()
    #         self.head = line_end + 1
    #         return slice(line_start, line_end)

    #     @always_inline
    #     fn _resize_buf(mut self, amt: Int, max_capacity: Int) raises:
    #         if self.capacity() == max_capacity:
    #             raise Error("Buffer is at max capacity")
    #         var nels: Int
    #         if self.capacity() + amt > max_capacity:
    #             nels = max_capacity
    #         else:
    #             nels = self.capacity() + amt
    #         self.buf.ptr = UnsafePointer[UInt8].alloc(nels)

    #     @always_inline
    #     fn _check_ascii(self) raises:
    #         var aligned = math.align_down(
    #             self.end - self.head, simd_width
    #         ) + self.head
    #         alias bit_mask = 0x80  # Non negative
    #         for i in range(self.head, aligned, simd_width):
    #             var vec = self.buf.ptr.load[width=simd_width](i)
    #             var mask = vec & bit_mask
    #             for i in range(len(mask)):
    #                 if mask[i] != 0:
    #                     raise Error("Non ASCII letters found")

    #         for i in range(aligned, self.end):
    #             if self.buf[i] & bit_mask != 0:
    #                 raise Error("Non ASCII letters found")

    #     @always_inline
    #     fn _handle_windows_sep(self, in_slice: Slice) raises -> Slice:
    #         if self.buf[in_slice.end.or_else(0)] != carriage_return:
    #             return in_slice
    #         return Slice(in_slice.start.or_else(0), in_slice.end.or_else(0) - 1)

    @always_inline
    fn _get_next_line_index(self) raises -> Int:
        var aligned_range = math.align_down(self.len(), simd_width) + self.head
        for s in range(self.head, aligned_range, simd_width):
            var v = self.buf.ptr.load[width=simd_width](s)
            var mask = v == NEW_LINE
            if mask.reduce_or():
                return s + arg_true(mask)
        
        for i in range(aligned_range, self.end):
            if self.buf[i] == NEW_LINE:
                return i
        for i in range(self.head, self.end):
            if self.buf[i] == NEW_LINE:
                return i
        return -1

    #    ########################## Helpers functions, have no side effects #######################

    @always_inline
    fn __len__(self) -> Int:
        return self.end - self.head

    @always_inline
    fn __str__(mut self) -> String:
        var s = self.buf.as_span[mut=False]()
        sl = slice(self.head, self.end)
        return String(bytes=s.__getitem__(sl))

    fn __getitem__(self, index: Int) raises -> UInt8:
        if self.head > index or index >= self.end:
            raise Error("Out of bounds")
        return self.buf[index]

    fn __getitem__(mut self, sl: Slice) raises -> List[UInt8]:
        start = sl.start.or_else(self.head)
        end = sl.end.or_else(self.end)
        step = sl.step.or_else(1)

        if start >= self.head and end <= self.end:
            var _slice = self.buf.__getitem__(slice(start, end, step))
            return List(_slice)
        else:
            raise Error("Out of bounds")


@always_inline
fn arg_true[simd_width: Int](v: SIMD[DType.bool, simd_width]) -> Int:
    for i in range(simd_width):
        if v[i]:
            return i
    return -1


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
