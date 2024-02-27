from utils import variant
from memory.memory import memcpy
from MojoFastTrim.helpers import get_next_line_index, slice_tensor, cpy_tensor
from MojoFastTrim.CONSTS import simd_width

alias DEFAULT_CAPACITY = 64 * 1024


struct BufferedStream:
    """An IO stream buffer which begins can take an underlying resource an FileHandle, Path, Tensor.
    """

    var buffer: Tensor[DType.int8]
    var reader: FileHandle
    var file_pos: Int
    var search_pos: Int

    fn __init__(inout self, stream: Path, capacity: Int = DEFAULT_CAPACITY) raises:
        self.buffer = Tensor[DType.int8](capacity)
        self.file_pos = 0
        self.search_pos = 0

        if stream.exists():
            let f = open(stream.path, "r")
            self.reader = f ^
            let temp = self.reader.read_bytes(capacity)
            memcpy[DType.int8](self.buffer._ptr, temp._ptr, temp.num_elements())
            self.file_pos = temp.num_elements()
        else:
            raise Error("File does not exist")

    fn fill_buffer(inout self) raises:
        let temp = self.reader.read_bytes(self.buffer.num_elements())
        memcpy[DType.int8](self.buffer._ptr, temp._ptr, temp.num_elements())
        self.file_pos += temp.num_elements()

    fn grow_buffer(inout self, factor: Int = 2) raises:
        var temp = Tensor[DType.int8](self.buffer.num_elements() * factor)
        cpy_tensor[DType.int8, simd_width](
            temp, self.buffer, self.buffer.num_elements(), 0, 0
        )
        self.buffer = temp

    fn get_buffer(self) -> Tensor[DType.int8]:
        return self.buffer

    fn read_line(inout self) -> Tensor[DType.int8]:
        let index = get_next_line_index(self.buffer, self.search_pos)
        if index == -1:
            return Tensor[DType.int8](0)
        let t = slice_tensor(self.buffer, self.search_pos, index)
        self.search_pos = index + 1
        return t


fn main() raises:
    let f = Path("data/fastq_test.fastq")
    var buf = BufferedStream(stream=f, capacity=DEFAULT_CAPACITY)
    print(buf.buffer)
    buf.grow_buffer()
    print(buf.buffer)
