from memory.memory import memcpy
from MojoFastTrim.helpers import get_next_line_index, slice_tensor, cpy_tensor
from MojoFastTrim.CONSTS import simd_width, I8
from math.math import min
from pathlib import Path
import time

alias DEFAULT_CAPACITY = 64 * 1024

# Implement functionality from: Buffer-Reudx rust cate allowing for BufferedReader that supports partial reading and filling ,
# https://github.com/dignifiedquire/buffer-redux
# Also supports line iterators


trait reader:
    fn read_bytes(inout self, amt: Int) raises -> Tensor[I8]:
        ...

    fn __moveinit__(inout self, owned other: Self):
        ...


struct FileReader(reader):
    var file_handle: FileHandle

    fn __init__(inout self, path: Path) raises:
        self.file_handle = open(path, "r")

    fn read_bytes(inout self, amt: Int) raises -> Tensor[I8]:
        return self.file_handle.read_bytes(amt)

    fn __moveinit__(inout self, owned other: Self):
        self.file_handle = other.file_handle ^


struct TensorReader(reader):
    var pos: Int
    var source: Tensor[I8]

    fn __init__(inout self, source: Tensor[I8]):
        self.source = source
        self.pos = 0

    fn read_bytes(inout self, amt: Int) raises -> Tensor[I8]:
        var ele = min(amt, self.source.num_elements() - self.pos)

        if ele == 0:
            return Tensor[I8](0)

        var out = Tensor[I8](ele)
        cpy_tensor[I8, simd_width](out, self.source, out.num_elements(), 0, self.pos)
        self.pos += out.num_elements()
        return out

    fn __moveinit__(inout self, owned other: Self):
        self.source = other.source ^
        self.pos = other.pos


struct IOStream[T: reader](Sized, Stringable):
    """A poor man's BufferedReader that takes as input a FileHandle or an in-memory Tensor and provides a buffered reader on-top with default capactiy.
    """

    var source: T
    var buf: Tensor[I8]
    var head: Int
    var end: Int
    var consumed: Int
    var EOF: Bool

    fn __init__(inout self, source: Path, capacity: Int = DEFAULT_CAPACITY) raises:
        if source.exists():
            self.source = FileReader(source)
        else:
            raise Error("Provided file not found for read")
        self.buf = Tensor[I8](capacity)
        self.head = 0
        self.end = 0
        self.consumed = 0
        self.EOF = False
        _ = self.fill_empty_buffer()

    fn __init__(
        inout self, source: Tensor[I8], capacity: Int = DEFAULT_CAPACITY
    ) raises:
        self.source = TensorReader(source)
        self.buf = Tensor[I8](capacity)
        self.head = 0
        self.end = 0
        self.consumed = 0
        self.EOF = False
        _ = self.fill_empty_buffer()

    @always_inline
    fn len(self) -> Int:
        return self.end - self.head

    @always_inline
    fn get(inout self, ele: Int) -> Tensor[I8]:
        # Gets are always in bounds
        var out_buf = Tensor[I8](min(ele, self.len()))
        cpy_tensor[I8, simd_width](
            out_buf, self.buf, out_buf.num_elements(), 0, self.head
        )
        self.head += out_buf.num_elements()
        return out_buf

    fn store(inout self, in_tensor: Tensor[I8]) -> Int:
        # Stores are always in bounds
        var nels = min(in_tensor.num_elements(), self.uninatialized_space())
        cpy_tensor[I8, simd_width](self.buf, in_tensor, nels, self.end, 0)
        self.end += nels
        return nels

    @always_inline
    fn check_buf_state(inout self) -> Bool:
        if self.head == self.end:
            self.head = 0
            self.end = 0
            return True
        else:
            return False

    @always_inline
    fn left_shift(inout self):
        """Checks if there is remaining elements in the buffer and copys them to the beginning of buffer to allow for partial reading of new data.
        """
        if self.head == 0:
            return
        var no_items = self.len()
        var ptr = self.buf._ptr + self.head
        memcpy[I8](self.buf._ptr, ptr, no_items)  # Would this work?
        self.head = 0
        self.end = no_items

    @always_inline
    fn fill_buffer(inout self) -> Int:
        """Returns the number of bytes read into the buf
        fer."""
        if self.check_buf_state():
            var ele = self.fill_empty_buffer()
            self.consumed += ele
            return ele

        self.left_shift()
        var nels = self.uninatialized_space()
        try:
            var temp = self.source.read_bytes(nels)
            if temp.num_elements() == 0:
                raise Error("EOF")
            _ = self.store(temp)
            self.consumed += temp.num_elements()
            return temp.num_elements()
        except:
            return -1

    @always_inline
    fn fill_empty_buffer(inout self) -> Int:
        try:
            var in_buf = self.source.read_bytes(self.capacity())
            if in_buf.num_elements() == 0:
                self.EOF = True
                return -1
            _ = self.store(in_buf)
            return in_buf.num_elements()
        except Error:
            print(Error)
            return -1

    @always_inline
    fn read(inout self, owned ele: Int) raises -> Tensor[I8]:
        """Patial reads from the buffer, if the buffer is empty, calls fill buffer."""
        if self.EOF:
            raise ("EOF")
        var buf = self.get(ele)
        if self.check_buf_state():
            var val = self.fill_buffer()
        return buf

    @always_inline
    fn read(inout self) raises -> Tensor[I8]:
        """Reads the whole buffer and calls fill buffer again."""
        if self.EOF:
            raise Error("EOF")
        var buf = self.get(self.len())
        _ = self.fill_buffer()
        return buf

    # BUG: Can reach into garbage if end is not at the end of the unintailized
    fn read_next_line(inout self) raises -> Tensor[I8]:
        if self.EOF:
            raise Error("EOF")

        if self.check_buf_state():
            _ = self.fill_buffer()

        var line_start = self.head
        var line_end = get_next_line_index(self.buf, line_start)

        # Avoids bugs when there is a partial read at EOF.
        # TODO: Consider trimming the buffer at last chunk before EOF to avoid checks.
        if line_end > self.end:
            _ = self.fill_buffer()
            return self.read_next_line()
        if line_end == -1:
            _ = self.fill_buffer()
            return self.read_next_line()
        self.head = min(self.end, line_end + 1)
        return slice_tensor[I8](self.buf, line_start, line_end)

    fn next_line_index(inout self) raises -> Int:
        if self.EOF:
            raise Error("EOF")

        if self.check_buf_state():
            _ = self.fill_buffer()
        var line_end = get_next_line_index(self.buf, self.head)

        if line_end > self.end:
            _ = self.fill_buffer()
            return self.next_line_index()

        if line_end == -1:
            _ = self.fill_buffer()
            return self.next_line_index()

        self.head = min(self.end, line_end + 1)

        return line_end + self.consumed

    @always_inline
    fn map_pos_2_buf(self, file_pos: Int) -> Int:
        return file_pos - self.consumed

    @always_inline
    fn capacity(self) -> Int:
        return self.buf.num_elements()

    @always_inline
    fn uninatialized_space(self) -> Int:
        return self.capacity() - self.end

    @always_inline
    fn usable_space(self) -> Int:
        return self.uninatialized_space() + self.head

    fn __len__(self) -> Int:
        return self.end - self.head

    fn __str__(self) -> String:
        var out = Tensor[I8](self.len())
        cpy_tensor[I8, simd_width](out, self.buf, self.len(), 0, self.head)
        return String(out._steal_ptr(), self.len())


fn main() raises:
    var t = open(
        "/home/mohamed/Documents/Projects/Fastq_Parser/data/SRR16012060.fastq",
        "r",
    )
    var x = t.read_bytes()

    var buf = IOStream[TensorReader](x, capacity=64 * 1024)
    var t1 = time.now()
    while True:
        try:
            var file_pos = buf.next_line_index()
        except Error:
            print(Error)
            break
    var t2 = time.now()

    print((t2 - t1) / 1e9)
