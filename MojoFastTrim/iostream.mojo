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
    var head: Int
    var end: Int

    fn __init__(inout self, capacity: Int = DEFAULT_CAPACITY):
        self.buf = Tensor[I8](capacity)
        self.head = 0
        self.end = 0

    fn __getitem__(self, index: Int) raises -> Int8:
        if index <= self.end:
            return self.buf[index]
        else:
            raise Error("out of bounds")

    fn __getitem__(self, slice: Slice) raises -> Tensor[I8]:
        if slice.start >= self.head and slice.end <= self.end:
            var temp = Tensor[I8](slice.end - slice.start)
            cpy_tensor[I8, simd_width](
                temp, self.buf, temp.num_elements(), 0, slice.start
            )
            return temp
        else:
            raise Error("out of bounds")

    fn check_buf_state(inout self) -> Bool:
        if self.head == self.end:
            self.head = 0
            self.end = 0
            return True
        else:
            return False

    fn capacity(self) -> Int:
        return self.buf.num_elements()

    fn usable_space(self) -> Int:
        return self.uninatialized_space() + self.head

    fn uninatialized_space(self) -> Int:
        return self.capacity() - self.end

    fn consume(inout self, amt: Int):
        self.head = min(self.head + amt, self.end)
        _ = self.check_buf_state()

    fn left_shift(inout self):
        """Checks if there is remaining elements in the buffer and copys them to the beginning of buffer to allow for partial reading of new data.
        """
        # The buffer head is still at the beginning
        _ = self.check_buf_state()
        if self.head == 0:
            return

        var no_items = len(self)
        var ptr = self.buf._ptr + self.head
        memcpy[I8](self.buf._ptr, ptr, no_items)  # Would this work?
        self.head = 0
        self.end = no_items

    # This is too complicated, consider simplfiying the logic
    fn store(inout self, data: Tensor[I8]) -> Bool:
        if data.num_elements() > self.usable_space():
            return False
        if data.num_elements() <= self.uninatialized_space():
            cpy_tensor[I8, simd_width](self.buf, data, data.num_elements(), self.end, 0)
            self.end += data.num_elements()
            return True

        self.left_shift()
        cpy_tensor[I8, simd_width](self.buf, data, data.num_elements(), self.end, 0)
        self.end += data.num_elements()
        return True

    fn get_ref_slice(self, slice: Slice) -> Buffer[I8]:
        if slice.start - slice.end <= len(self):
            return Buffer[I8](
                self.buf._ptr + self.head + slice.start, slice.end - slice.start
            )
        else:
            return Buffer[I8]()

    fn __len__(self) -> Int:
        return self.end - self.head

    fn __str__(self) -> String:
        return self.buf.__str__()


struct BufferedReader(Sized):
    """A BufferedReader that takes as input a FileHandle or an in-memory Tensor and provides a buffered reader on-top with default capactiy.
    TODO: Implement the in-memory buffer.
    """

    var inner_buf: InnerBuffer
    var source: FileHandle

    fn __init__(inout self, source: Path, capacity: Int = DEFAULT_CAPACITY) raises:
        if source.exists():
            self.source = open(source, "r")
        else:
            raise Error("Provided file not found for read")

        self.inner_buf = InnerBuffer(capacity)

    fn fill_buffer(inout self) -> Int:
        """Returns the number of bytes read into the buffer."""
        # Buffer is full
        return 0

    fn read(self):
        """Implicity call fill buffer if the whole buffer is consumed."""
        pass

    fn stream_untill_delimeter(self):
        """Implicity call fill buffer if the whole buffer is consumed."""
        pass

    fn capacity(self) -> Int:
        return self.inner_buf.capacity()

    fn uninatialized_space(self) -> Int:
        return self.inner_buf.uninatialized_space()

    fn __len__(self) -> Int:
        return len(self.inner_buf)


fn main() raises:
    var b = InnerBuffer()
    var t = Tensor[I8](10000)
