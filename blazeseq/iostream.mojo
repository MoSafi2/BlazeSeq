from memory import memcpy, UnsafePointer, Span
from utils import StringSlice
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
from tensor import Tensor
import math


alias NEW_LINE = 10

# Implement functionality from: Buffer-Reudx rust cate allowing for BufferedReader that supports partial reading and filling ,
# https://github.com/dignifiedquire/buffer-redux
# Minimial Implementation that support only line iterations

trait Reader:
    fn read_bytes(mut self, amt: Int) raises -> List[UInt8]:
        ...

    fn read_to_buffer(
        mut self, mut buf: List[UInt8], buf_pos: Int, amt: Int
    ) raises -> Int64:
        ...

    fn __moveinit__(mut self, owned other: Self):
        ...


struct FileReader(Reader):
    var handle: FileHandle

    fn __init__(out self, path: Path) raises:
        self.handle = open(path, "r")

    @always_inline
    fn read_bytes(mut self, amt: Int = -1) raises -> List[UInt8]:
        return self.handle.read_bytes(amt)

    @always_inline
    fn read_to_buffer(
        mut self, mut buf: List[UInt8], buf_pos: Int, amt: Int
    ) raises -> Int64:
        # TODO: Check if this is needed
        if buf.capacity < amt:
            raise Error(
                "The buffer capacity is smaller than the requestd amounts"
            )
        new = self.handle.read_bytes(amt)
        for i in range(len(new)):
            buf.append(new[i])
        #buf.extend(new)
        #read = self.handle.read(ptr=buf.unsafe_ptr() + buf_pos, size=amt)
        #buf._len = Int(read)
        return len(new)

    fn __moveinit__(mut self, owned other: Self):
        self.handle = other.handle^


# struct TensorReader(reader):
#     var pos: Int
#     var source: Tensor[U8]

#     fn __init__(out self, source: Tensor[U8]):
#         self.source = source
#         self.pos = 0

#     @always_inline
#     fn read_bytes(mut self, amt: Int) raises -> Tensor[U8]:
#         var ele = min(amt, self.source.num_elements() - self.pos)

#         if ele == 0:
#             return Tensor[U8](0)
#         var out = Tensor[U8](ele)
#         cpy_tensor[U8](out, self.source, out.num_elements(), 0, self.pos)
#         self.pos += out.num_elements()
#         return out

#     fn read_to_buffer(
#         mut self, mut buf: Tensor[U8], buf_pos: Int, amt: Int
#     ) raises -> Int:
#         var ele = min(amt, self.source.num_elements() - self.pos)
#         if ele == 0:
#             return 0
#         cpy_tensor[U8](buf, self.source, ele, buf_pos, self.pos)
#         self.pos += ele
#         return ele

#     fn __moveinit__(mut self, owned other: Self):
#         self.source = other.source^
#         self.pos = other.pos


# BUG Last line is not returned if the file does not end with line end seperator
# TODO: when in EOF Flush the buffer


struct BufferedLineIterator[reader: Reader, check_ascii: Bool = False](Sized, Stringable):
    """A poor man's BufferedReader and LineIterator that takes as input a FileHandle or an in-memory Tensor and provides a buffered reader on-top with default capactiy.
    """

    var source: FileReader
    var buf: List[UInt8]
    var head: Int
    var end: Int

    fn __init__(out self, path: Path, capacity: Int = DEFAULT_CAPACITY) raises:
        if path.exists():
            self.source = FileReader(path)
        else:
            raise Error("Provided file not found for read")

        self.buf = List[UInt8](capacity=capacity)
        self.head = 0
        self.end = 0
        _ = self._fill_buffer()

    @always_inline
    fn read_next_line(mut self) raises -> List[UInt8]:
        var line_coord = self._line_coord()
        return self.buf[line_coord]

    # @always_inline
    # fn read_next_coord(
    #     mut self,
    # ) raises -> Span[T=Byte, origin=StaticConstantOrigin]:
    #     var line_coord = self._line_coord()
    #     var ptr = self.buf.unsafe_ptr() + line_coord.start.or_else(0)
    #     var length = line_coord.end.or_else(0) - line_coord.start.or_else(0)
    #     return Span[T=Byte, origin=StaticConstantOrigin](ptr=ptr, length=length)

    @always_inline
    fn _fill_buffer[check_ascii: Bool = False](mut self) raises -> Int64:
        """Returns the number of bytes read into the buffer."""
        self._left_shift()
        var nels = self.uninatialized_space()
        var amt = self.source.read_to_buffer(self.buf, self.end, nels)

        @parameter
        if check_ascii:
            self._check_ascii()

        if amt == 0:
            raise Error("EOF")
        self.end += Int(amt)
        return amt

    @always_inline
    fn _line_coord(mut self) raises -> Slice:
        if self._check_buf_state():
            _ = self._fill_buffer()

        var coord: Slice
        var line_start = self.head
        var line_end = self._get_next_line_index(self.head)

        coord = Slice(line_start, line_end)

        # Handle small buffers
        if coord.end == -1 and self.head == 0:
            for _ in range(MAX_SHIFT):
                if coord.end != -1:
                    return self._handle_windows_sep(coord)
                else:
                    coord = self._line_coord_missing_line()

        # Handle incomplete lines across two chunks
        if coord.end == -1:
            _ = self._fill_buffer()
            return self._handle_windows_sep(self._line_coord_incomplete_line())

        self.head = line_end + 1

        # Handling Windows-syle line seperator
        if self.buf[line_end] == carriage_return:
            line_end -= 1

        return slice(line_start, line_end)

    @always_inline
    fn _line_coord_incomplete_line(mut self) raises -> Slice:
        if self._check_buf_state():
            _ = self._fill_buffer()
        var line_start = self.head
        var line_end = self._get_next_line_index(self.head)
        self.head = line_end + 1

        if self.buf[line_end] == carriage_return:
            line_end -= 1
        return slice(line_start, line_end)

    @always_inline
    fn _line_coord_missing_line(mut self) raises -> Slice:
        self._resize_buf(self.capacity(), MAX_CAPACITY)
        _ = self._fill_buffer()
        var line_start = self.head
        var line_end = self._get_next_line_index(self.head)
        self.head = line_end + 1
        return slice(line_start, line_end)


    @always_inline
    fn _left_shift(mut self):
        if self.head == 0:
            return
        var no_items = self.len()
        for i in range(no_items):
            self.buf[i] = self.buf[i + self.head]
        # var dest_ptr: UnsafePointer[UInt8] = self.buf.unsafe_ptr()
        # var src_ptr: UnsafePointer[UInt8] = self.buf.unsafe_ptr() + self.head
        # memcpy(dest_ptr, src_ptr, no_items)
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
    fn _resize_buf(mut self, amt: Int, max_capacity: Int) raises:
        if self.capacity() == max_capacity:
            raise Error("Buffer is at max capacity")

        var nels: Int
        if self.capacity() + amt > max_capacity:
            nels = max_capacity
        else:
            nels = self.capacity() + amt
        self.buf.reserve(nels)

    @always_inline
    fn _check_ascii(self) raises:
        var aligned = math.align_down(
            self.end - self.head, simd_width
        ) + self.head
        alias bit_mask = 0x80  # Non negative
        for i in range(self.head, aligned, simd_width):
            var vec = self.buf.unsafe_ptr().load[width=simd_width](i)
            var mask = vec & bit_mask
            for i in range(len(mask)):
                if mask[i] != 0:
                    raise Error("Non ASCII letters found")

        for i in range(aligned, self.end):
            if self.buf[i] & bit_mask != 0:
                raise Error("Non ASCII letters found")

    @always_inline
    fn _handle_windows_sep(self, in_slice: Slice) -> Slice:
        if self.buf[in_slice.end.or_else(0)] != carriage_return:
            return in_slice
        return Slice(in_slice.start.or_else(0), in_slice.end.or_else(0) - 1)

    

    @always_inline
    fn _get_next_line_index(self, start: Int) -> Int:
        for i in range(self.head, self.end):
            if self.buf[i] == NEW_LINE:
                return i
        # var len = self.len() - start
        # var aligned = start + math.align_down(len, simd_width)
        # for s in range(start, aligned, simd_width):
        #     var v = self.buf.unsafe_ptr().load[width=simd_width](s)
        #     x = v.cast[DType.uint8]()
        #     var mask = x == NEW_LINE
        #     if mask.reduce_or():
        #         return s + arg_true(mask)
        # var y = self.len()
        # for i in range(aligned, y):
        #     if self.buf[i] == NEW_LINE:
        #         return i
        return -1


    ########################## Helpers functions, have no side effects #######################

    @always_inline
    fn len(self) -> Int:
        return self.end - self.head

    @always_inline
    fn capacity(self) -> Int:
        return self.buf.capacity

    @always_inline
    fn uninatialized_space(self) -> Int:
        return self.capacity() - self.end

    @always_inline
    fn usable_space(self) -> Int:
        return self.uninatialized_space() + self.head

    @always_inline
    fn __len__(self) -> Int:
        return self.end - self.head

    @always_inline
    fn __str__(self) -> String:
        return String(
            ptr=self.buf.unsafe_ptr() + self.head, length=self.end - self.head
        )

    fn __getitem__(self, index: Int) raises -> Scalar[U8]:
        if self.head <= index <= self.end:
            return self.buf[index]
        else:
            raise Error("Out of bounds")

    fn __getitem__(self, slice: Slice) raises -> List[UInt8]:
        if (
            slice.start.or_else(0) >= self.head
            and slice.end.or_else(0) <= self.end
        ):
            return self.buf[slice]
        else:
            raise Error("Out of bounds")


# TODO: Add a resize if the buffer is too small
# struct BufferedWriter:
#     var sink: FileHandle
#     var buf: Tensor[U8]
#     var cursor: Int
#     var written: Int

#     fn __init__(out self, out_path: String, buf_size: Int) raises:
#         self.sink = open(out_path, "w")
#         self.buf = Tensor[U8](buf_size)
#         self.cursor = 0
#         self.written = 0

#     fn ingest(mut self, source: Tensor[U8]) raises -> Bool:
#         if source.num_elements() > self.uninatialized_space():
#             self.flush_buffer()
#         cpy_tensor[U8](self.buf, source, source.num_elements(), self.cursor, 0)
#         self.cursor += source.num_elements()
#         return True

#     fn flush_buffer(mut self) raises:
#         var out = Tensor[U8](self.cursor)
#         cpy_tensor[U8](out, self.buf, self.cursor, 0, 0)
#         var out_string = StringSlice[origin=StaticConstantOrigin](
#             ptr=out._steal_ptr(), length=self.cursor
#         )
#         self.sink.write(out_string)
#         self.written += self.cursor
#         self.cursor = 0

#     fn _resize_buf(mut self, amt: Int, max_capacity: Int = MAX_CAPACITY):
#         var new_capacity = 0
#         if self.buf.num_elements() + amt > max_capacity:
#             new_capacity = max_capacity
#         else:
#             new_capacity = self.buf.num_elements() + amt
#         var new_tensor = Tensor[U8](new_capacity)
#         cpy_tensor[U8](new_tensor, self.buf, self.cursor, 0, 0)
#         swap(self.buf, new_tensor)

#     fn uninatialized_space(self) -> Int:
#         return self.capacity() - self.cursor

#     fn capacity(self) -> Int:
#         return self.buf.num_elements()

#     fn close(mut self) raises:
#         self.flush_buffer()
#         self.sink.close()




@always_inline
fn arg_true[simd_width: Int](v: SIMD[DType.bool, simd_width]) -> Int:
    for i in range(simd_width):
        if v[i]:
            return i
    return -1


# @always_inline
# fn find_chr_next_occurance(in_buf: List[UInt8], chr: Int, start: Int = 0) -> Int:
#     """
#     Function to find the next occurance of character using SIMD instruction.
#     Checks are in-bound. no-risk of overflowing the tensor.
#     """
#     var len = len(in_buf) - start
#     var aligned = start + math.align_down(len, simd_width)

#     for s in range(start, aligned, simd_width):
#         var v = in_buf.unsafe_ptr().load[width=simd_width](s)
#         x = v.cast[DType.uint8]()
#         var mask = x == chr
#         if mask.reduce_or():
#             return s + arg_true(mask)
#     var y = in_buf.__len__()
#     for i in range(aligned, y):
#         if in_buf[i] == chr:
#             return i
#     return -1





fn main() raises:
    var path = Path("/home/mohamed/Documents/Projects/BlazeSeq/data/fastq_test.fastq")
    var reader = BufferedLineIterator[FileReader](path)

    var n = 0
    t1 = time.perf_counter_ns()
    while True:
        try:
            var line = reader.read_next_line()
            print(String(buffer = line))
            n += 1
        except:
            break
    print(n)
    t2 = time.perf_counter_ns()
    print("Time taken:", (t2 - t1) / 1e9)
