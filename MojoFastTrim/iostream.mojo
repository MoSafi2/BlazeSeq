from utils import variant
from memory.memory import memcpy
from MojoFastTrim.helpers import get_next_line_index, slice_tensor, cpy_tensor
from MojoFastTrim.CONSTS import simd_width
from math.math import min
from utils.variant import Variant
from pathlib import Path
import time

alias DEFAULT_CAPACITY = 64 * 1024

# Implement functionality from: Buffer-Reudx rust cate allowing for BufferedReader that supports partial reading and filling ,
# https://github.com/dignifiedquire/buffer-redux
# Also supports line iterators

alias I8 = DType.int8


struct IOStream(Sized, Stringable):
    """A poor man's BufferedReader that takes as input a FileHandle or an in-memory Tensor and provides a buffered reader on-top with default capactiy.
    TODO: Implement the in-memory buffer.
    """

    var source: FileHandle
    var buf: Tensor[I8]
    var head: Int
    var end: Int
    var EOF: Bool

    fn __init__(inout self, source: Path, capacity: Int = DEFAULT_CAPACITY) raises:
        if source.exists():
            self.source = open(source, "r")
        else:
            raise Error("Provided file not found for read")
        self.buf = Tensor[I8](capacity)
        self.head = 0
        self.end = 0
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
            return self.fill_empty_buffer()

        self.left_shift()
        var nels = self.uninatialized_space()
        try:
            var temp = self.source.read_bytes(nels)
            if temp.num_elements() == 0:
                return -1
            _ = self.store(temp)
            return temp.num_elements()
        except:
            return -1

    @always_inline
    fn fill_empty_buffer(inout self) -> Int:
        try:
            var in_buf = self.source.read_bytes(self.capacity())
            if in_buf.num_elements() == 0:
                return -1
            _ = self.store(in_buf)
            return in_buf.num_elements()
        except Error:
            print(Error)
            return -1

    fn read(inout self, owned ele: Int) raises -> Tensor[I8]:
        """Patial reads from the buffer, if the buffer is empty, calls fill buffer."""

        if self.EOF:
            raise ("EOF")

        var buf = self.get(ele)
        if self.check_buf_state():
            var val = self.fill_buffer()
            if val == -1:
                self.EOF = True
        return buf

    fn read(inout self) raises -> Tensor[I8]:
        """Reads the whole buffer and calls fill buffer again."""
        if self.EOF:
            raise Error("EOF")

        var buf = self.get(self.len())
        var val = self.fill_buffer()
        if val == -1:
            self.EOF = True
        return buf

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
    var buf = IOStream(
        "/home/mohamed/Documents/Projects/Fastq_Parser/data/M_abscessus_HiSeq.fq",
        capacity=64 * 1024,
    )

    var t1 = time.now()
    while True:
        try:
            var s = buf.read()
            var e = s.num_elements()
        except Error:
            break
    var t2 = time.now()
    print((t2 - t1) / 1e9)
