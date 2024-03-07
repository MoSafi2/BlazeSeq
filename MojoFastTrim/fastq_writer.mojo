from tensor import Tensor
from MojoFastTrim import FastqRecord
from MojoFastTrim.helpers import cpy_tensor
from MojoFastTrim.CONSTS import I8


struct BufferedWriter:
    var sink: FileHandle
    var buf: Tensor[DType.int8]
    var cursor: Int
    var written: Int

    fn __init__(inout self, out_path: String, buf_size: Int) raises:
        self.sink = open(out_path, "w")
        self.buf = Tensor[I8](buf_size)
        self.cursor = 0
        self.written = 0

    fn ingest(inout self, source: Tensor[I8]) raises -> Bool:
        if source.num_elements() > self.uninatialized_space():
            self.flush_buffer()
        cpy_tensor[I8](self.buf, source, source.num_elements(), self.cursor, 0)
        return True

    fn flush_buffer(inout self) raises:
        var out = Tensor[I8](self.cursor)
        cpy_tensor[I8](out, self.buf, self.cursor, 0, 0)
        var out_string = String(out._steal_ptr(), self.cursor)
        self.sink.write(out_string)
        self.written += self.cursor
        self.cursor = 0

    fn uninatialized_space(self) -> Int:
        return self.capacity() - self.cursor

    fn capacity(self) -> Int:
        return self.buf.num_elements()

    fn close(inout self) raises:
        self.flush_buffer()
        self.sink.close()
