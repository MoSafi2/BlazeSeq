from memory import memcpy, UnsafePointer, Span
from utils import StringSlice
from blazeseq.helpers import get_next_line_index, slice_tensor, cpy_tensor
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


# Implement functionality from: Buffer-Reudx rust cate allowing for BufferedReader that supports partial reading and filling ,
# https://github.com/dignifiedquire/buffer-redux
# Minimial Implementation that support only line iterations

# BUG in resizing buffer: One extra line & bad consumed and file coordinates.


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
        read = self.handle.read(ptr=buf.unsafe_ptr() + buf_pos, size=amt)
        buf._len = Int(read)
        return read

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

    @always_inline
    fn read_next_coord(
        mut self,
    ) raises -> Span[T=Byte, origin=StaticConstantOrigin]:
        var line_coord = self._line_coord()
        var ptr = self.buf.unsafe_ptr() + line_coord.start.or_else(0)
        var length = line_coord.end.or_else(0) - line_coord.start.or_else(0)
        return Span[T=Byte, origin=StaticConstantOrigin](ptr=ptr, length=length)

    # @always_inline
    # fn read_n_coords[lines: Int](mut self) raises -> List[Slice]:
    #     return self._read_n_line[lines]()

    @always_inline
    fn _fill_buffer[check_ascii: Bool = False](mut self) raises -> Int:
        """Returns the number of bytes read into the buffer."""
        self._left_shift()
        var nels = self.uninatialized_space()
        var amt = self.source.read_to_buffer(self.buf, self.head, nels)

        @parameter
        if check_ascii:
            self._check_ascii()

        if amt == 0:
            raise Error("EOF")
        self.end += Int(amt)

        return Int(amt)

    @always_inline
    fn _line_coord(mut self) raises -> Slice:
        if self._check_buf_state():
            _ = self._fill_buffer()

        var coord: Slice
        var line_start = self.head
        var line_end = get_next_line_index(self.buf, self.head)

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

    # # TODO: Handle small Buffers, handle windows seperator, simplify
    @always_inline
    fn _read_n_line[lines: Int](mut self) raises -> List[Slice]:
        var coords = List[Slice](Slice(-1, -1))
        var internal_head = self.head

        # TODO: Provide unrolling later using the @parameter for op
        for i in range(lines):
            if internal_head >= self.end:
                internal_head -= self.head
                # Resetting coordinates for read lines to the new buffer coordinates
                for j in range(i):
                    coords[j] = Slice(
                        coords[j].start.or_else(0) - self.head,
                        coords[j].end.or_else(0) - self.head,
                    )
                _ = self._fill_buffer()  # self.head is reset to 0

            var coord: Slice
            var line_start = internal_head
            var line_end = get_next_line_index(self.buf, internal_head)

            coord = Slice(line_start, line_end)

            # Handle small buffers
            if coord.end == -1 and self.head == 0:
                for i in range(MAX_SHIFT):
                    if coord.end != -1:
                        coords[i] = self._handle_windows_sep(coord)
                        continue
                    else:
                        coord = self._line_coord_missing_line(internal_head)

            # Handle incomplete lines across two chunks
            if coord.end == -1:
                # Restting corrdinates to new buffer
                internal_head -= self.head
                line_start = internal_head
                for j in range(i):
                    coords[j] = Slice(
                        coords[j].start.or_else(0) - self.head,
                        coords[j].end.or_else(0) - self.head,
                    )
                _ = self._fill_buffer()  # self.head is 0

                # Try again to read the complete line
                var completet_line = self._line_coord_incomplete_line(
                    internal_head
                )
                coords[i] = completet_line
                line_end = completet_line.end.or_else(0)

            internal_head = line_end + 1

            coords[i] = self._handle_windows_sep(slice(line_start, line_end))

        self.head = internal_head
        return coords

    @always_inline
    fn _line_coord_incomplete_line(mut self) raises -> Slice:
        if self._check_buf_state():
            _ = self._fill_buffer()
        var line_start = self.head
        var line_end = get_next_line_index(self.buf, self.head)
        self.head = line_end + 1

        if self.buf[line_end] == carriage_return:
            line_end -= 1
        return slice(line_start, line_end)

    # Overload to allow reading missing line from a specific point
    @always_inline
    fn _line_coord_incomplete_line(mut self, pos: Int) raises -> Slice:
        if self._check_buf_state():
            _ = self._fill_buffer()
        var line_start = pos
        var line_end = get_next_line_index(self.buf, pos)
        return slice(line_start, line_end)

    @always_inline
    fn _line_coord_missing_line(mut self) raises -> Slice:
        self._resize_buf(self.capacity(), MAX_CAPACITY)
        _ = self._fill_buffer()
        var line_start = self.head
        var line_end = get_next_line_index(self.buf, self.head)
        self.head = line_end + 1

        return slice(line_start, line_end)

    @always_inline
    fn _line_coord_missing_line(mut self, pos: Int) raises -> Slice:
        self._resize_buf(self.capacity(), MAX_CAPACITY)
        _ = self._fill_buffer()
        var line_start = pos
        var line_end = get_next_line_index(self.buf, pos)
        return slice(line_start, line_end)

    @always_inline
    fn _left_shift(mut self):
        if self.head == 0:
            return
        var no_items = self.len()
        var dest_ptr: UnsafePointer[UInt8] = self.buf.unsafe_ptr() + 0
        var src_ptr: UnsafePointer[UInt8] = self.buf.unsafe_ptr() + self.head
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
        # alias bit_mask = 0xA0  # Between 32 and 127, makes a problems with 10
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
struct BufferedWriter:
    var sink: FileHandle
    var buf: Tensor[U8]
    var cursor: Int
    var written: Int

    fn __init__(out self, out_path: String, buf_size: Int) raises:
        self.sink = open(out_path, "w")
        self.buf = Tensor[U8](buf_size)
        self.cursor = 0
        self.written = 0

    fn ingest(mut self, source: Tensor[U8]) raises -> Bool:
        if source.num_elements() > self.uninatialized_space():
            self.flush_buffer()
        cpy_tensor[U8](self.buf, source, source.num_elements(), self.cursor, 0)
        self.cursor += source.num_elements()
        return True

    fn flush_buffer(mut self) raises:
        var out = Tensor[U8](self.cursor)
        cpy_tensor[U8](out, self.buf, self.cursor, 0, 0)
        var out_string = StringSlice[origin=StaticConstantOrigin](
            ptr=out._steal_ptr(), length=self.cursor
        )
        self.sink.write(out_string)
        self.written += self.cursor
        self.cursor = 0

    fn _resize_buf(mut self, amt: Int, max_capacity: Int = MAX_CAPACITY):
        var new_capacity = 0
        if self.buf.num_elements() + amt > max_capacity:
            new_capacity = max_capacity
        else:
            new_capacity = self.buf.num_elements() + amt
        var new_tensor = Tensor[U8](new_capacity)
        cpy_tensor[U8](new_tensor, self.buf, self.cursor, 0, 0)
        swap(self.buf, new_tensor)

    fn uninatialized_space(self) -> Int:
        return self.capacity() - self.cursor

    fn capacity(self) -> Int:
        return self.buf.num_elements()

    fn close(mut self) raises:
        self.flush_buffer()
        self.sink.close()


fn main() raises:
    var path = Path("data/SRR16012060.fastq")
    var reader = BufferedLineIterator[FileReader](path)

    var n = 0
    t1 = time.perf_counter_ns()
    while True:
        try:
            var line = reader.read_next_coord()
            n += 1
        except:
            break
    print(n)
    t2 = time.perf_counter_ns()
    print("Time taken:", (t2 - t1) / 1e9)
