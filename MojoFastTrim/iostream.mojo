from utils import variant
from memory.memory import memcpy
from MojoFastTrim.helpers import get_next_line_index, slice_tensor, cpy_tensor
from MojoFastTrim.CONSTS import simd_width
from math.math import min
from utils.variant import Variant
from pathlib import Path

alias DEFAULT_CAPACITY = 64 * 1024

# Implement functionality from: Buffer-Reudx rust cate allowing for BufferedReader that supports partial reading and filling ,
# https://github.com/dignifiedquire/buffer-redux
# Also supports line iterators


alias I8 = DType.int8


struct InnerBuffer(Sized, Stringable):
    var buf: Tensor[I8]
    var pos: Int
    var end: Int

    fn __init__(inout self, capacity: Int = DEFAULT_CAPACITY):
        self.buf = Tensor[I8](capacity)
        self.pos = 0
        self.end = 0

    fn check_buf_state(inout self) -> Bool:
        if self.pos == self.end:
            self.pos = 0
            self.end = 0
            return True
        else:
            return False

    fn consume(inout self, amt: Int):
        self.pos = min(self.pos + amt, self.end)
        _ = self.check_buf_state()

    fn capacity(self) -> Int:
        return self.buf.num_elements()

    fn usable_space(self) -> Int:
        return self.capacity() - self.end

    fn left_shift(inout self):
        """Checks if there is remaining elements in the buffer and copys them to the beginning of buffer to allow for partial reading of new data.
        """
        # The buffer head is still at the beginning
        _ = self.check_buf_state()
        if self.pos == 0:
            return

        var no_items = len(self)
        var ptr = self.buf._ptr + self.pos
        memcpy[I8](self.buf._ptr, ptr, no_items)  # Would this work?
        self.pos = 0
        self.end = no_items

    fn __len__(self) -> Int:
        return self.end - self.pos

    fn __str__(self) -> String:
        return self.buf.__str__()


struct BufferedReader(Sized):
    """A BufferedReader that takes as input a FileHandle or an in-memory Tensor and provides a buffered reader on-top with default capactiy.
    TODO: Implement the in-memory buffer.
    """

    var buf: InnerBuffer
    var source: FileHandle

    fn __init__(inout self, source: Path, capacity: Int = DEFAULT_CAPACITY) raises:
        if source.exists():
            self.source = open(source, "r")
        else:
            raise Error("Provided file not found for read")

        self.buf = InnerBuffer(capacity)

    fn fill_buffer(inout self) -> Int:
        """Returns the number of bytes read into the buffer."""
        # Buffer is full
        if len(self) == self.capacity():
            return 0
        
        self.left_shift()
        try:
            self.source.read_bytes(self.usable_space())
            

    fn consume(inout self, amt: Int):
        var amt_inner = min(amt, len(self))
        self.buf.consume(amt)

    fn left_shift(inout self):
        self.buf.left_shift()

    fn capacity(self) -> Int:
        return self.buf.capacity()

    
    fn usable_space(self) -> Int:
        return self.buf.usable_space()

    fn __len__(self) -> Int:
        return len(self.buf)


fn main() raises:
    var b = "/home/mohamed/Documents/Projects/Fastq_Parser/data/fastq_test.fastq"
    var buf = BufferedReader(b)
