from utils import variant
from memory.memory import memcpy
from MojoFastTrim.helpers import get_next_line_index, slice_tensor, cpy_tensor
from MojoFastTrim.CONSTS import simd_width
from math.math import min


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

        # TODO: Test this
        let no_items = len(self)
        let ptr = self.buf._ptr + self.pos
        memcpy[I8](self.buf._ptr, ptr, no_items)  # Would this work?
        self.pos = 0
        self.end = no_items

    fn __len__(self) -> Int:
        return self.end - self.pos

    fn __str__(self) -> String:
        return self.buf.__str__()


# struct BufferedReader:
#     """An IO stream buffer which begins can take an underlying resource an FileHandle, Path, Tensor.
#     """

#     var buffer: Tensor[DType.int8]
#     var reader: FileHandle
#     var file_pos: Int
#     var search_pos: Int

#     fn __init__(inout self, stream: Path, capacity: Int = DEFAULT_CAPACITY) raises:
#         self.buffer = Tensor[DType.int8](capacity)
#         self.file_pos = 0
#         self.search_pos = 0

#         if stream.exists():
#             let f = open(stream.path, "r")
#             self.reader = f ^
#             let temp = self.reader.read_bytes(capacity)
#             memcpy[DType.int8](self.buffer._ptr, temp._ptr, temp.num_elements())
#             self.file_pos = temp.num_elements()
#         else:
#             raise Error("File does not exist")

#     fn fill_buffer(inout self) raises:
#         let temp = self.reader.read_bytes(self.buffer.num_elements())
#         memcpy[DType.int8](self.buffer._ptr, temp._ptr, temp.num_elements())
#         self.file_pos += temp.num_elements()

#     fn grow_buffer(inout self, factor: Int = 2) raises:
#         var temp = Tensor[DType.int8](self.buffer.num_elements() * factor)
#         cpy_tensor[DType.int8, simd_width](
#             temp, self.buffer, self.buffer.num_elements(), 0, 0
#         )
#         self.buffer = temp

#     fn get_buffer(self) -> Tensor[DType.int8]:
#         return self.buffer

#     fn read_line(inout self) -> Tensor[DType.int8]:
#         let index = get_next_line_index(self.buffer, self.search_pos)
#         if index == -1:
#             return Tensor[DType.int8](0)
#         let t = slice_tensor(self.buffer, self.search_pos, index)
#         self.search_pos = index + 1
#         return t


fn main() raises:
    var buf = InnerBuffer()
    buf.end = 550
    buf.buf[501] = 5
    buf.consume(500)
    buf.left_shift()
    print(buf)
    print(len(buf))
    print(buf.usable_space())
    print(buf.capacity())
