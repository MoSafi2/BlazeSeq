from utils.list import Dim
from math import min, abs
from math.limit import max_finite
from memory import memcpy
from memory.buffer import Buffer
from memory.unsafe import Pointer, DTypePointer
from sys.info import sizeof
from utils.index import Index
from collections.vector import DynamicVector
import testing


alias c_char = UInt8



struct BufReader[BUF_SIZE: Int]:
    var unbuffered_reader: FileHandle
    var data: DTypePointer[DType.uint8]
    var end: Int
    var start: Int

    fn __init__(inout self, owned reader: FileHandle):
        self.unbuffered_reader = reader ^
        self.data = DTypePointer[DType.uint8]().alloc(BUF_SIZE)
        self.end = 0
        self.start = 0

    fn __moveinit__(inout self, owned other: Self):
        self.unbuffered_reader = other.unbuffered_reader ^
        self.data = other.data
        self.end = other.end
        self.start = other.start
        other.unbuffered_reader = File("", "r")
        other.data = DTypePointer[DType.uint8]()

    fn read[D: Dim](inout self, dest: Buffer[D, DType.uint8]) raises -> Int:
        var dest_index = 0
        let buf = Buffer[BUF_SIZE, DType.uint8](self.data)

        while dest_index < len(dest):
            let written = min(len(dest) - dest_index, self.end - self.start)
            memcpy(dest.data.offset(dest_index), self.data.offset(self.start), written)
            if written == 0:
                # buf empty, fill it
                let n = self.unbuffered_reader.read(buf)
                if n == 0:
                    # reading from the unbuffered stream returned nothing
                    # so we have nothing left to read.
                    return dest_index
                self.start = 0
                self.end = n
            self.start += written
            dest_index += written
        return len(dest)

    fn do_nothing(self):
        pass


struct Reader[BUF_SIZE: Int]:
    var context: BufReader[BUF_SIZE]

    fn do_nothing(self):
        pass

    fn __init__(inout self, owned context: BufReader[BUF_SIZE]):
        self.context = context ^

    # Returns the number of bytes read. It may be less than buffer.len.
    # If the number of bytes read is 0, it means end of stream.
    # End of stream is not an error condition.
    fn read[D: Dim](inout self, buffer: Buffer[D, DType.uint8]) raises -> Int:
        return self.context.read(buffer)

    # Returns the number of bytes read. If the number read is smaller than `buffer.len`, it
    # means the stream reached the end. Reaching the end of a stream is not an error
    # condition.
    fn read_all[D: Dim](inout self, buffer: Buffer[D, DType.uint8]) raises -> Int:
        return self.read_at_least(buffer, len(buffer))

    # Returns the number of bytes read, calling the underlying read
    # function the minimal number of times until the buffer has at least
    # `len` bytes filled. If the number read is less than `len` it means
    # the stream reached the end. Reaching the end of the stream is not
    # an error condition.
    fn read_at_least[
        D: Dim
    ](inout self, buffer: Buffer[D, DType.uint8], len: Int) raises -> Int:
        # assert(len <= buffer.len);
        var index: Int = 0
        while index < len:
            let amt = self.read(
                Buffer[Dim(), DType.uint8](
                    buffer.data.offset(index), buffer.__len__() - index
                )
            )
            if amt == 0:
                break
            index += amt
        return index

    # If the number read would be smaller than `buf.len`, `error.EndOfStream` is returned instead.
    fn read_no_eof[D: Dim](inout self, buf: Buffer[D, DType.uint8]) raises:
        let amt_read = self.read_all(buf)
        if amt_read < len(buf):
            raise Error("Unexpected End of Stream.")

    # Appends to the `writer` contents by reading from the stream until `delimiter` is found.
    # Does not write the delimiter itself.
    # If `optional_max_size` is not null and amount of written bytes exceeds `optional_max_size`,
    # returns `error.StreamTooLong` and finishes appending.
    # If `optional_max_size` is null, appending is unbounded.
    fn stream_until_delimiter[
        BuffD: Dim
    ](
        inout self,
        inout writer: FixedBufferStream[BuffD],
        delimiter: UInt8,
        max_size: Int,
    ) raises:
        for i in range(max_size):
            let byte = self.read_byte()
            if byte == delimiter:
                return
            writer.write_byte(byte)
        raise Error("Stream too long")

    # Appends to the `writer` contents by reading from the stream until `delimiter` is found.
    # Does not write the delimiter itself.
    # If `optional_max_size` is not null and amount of written bytes exceeds `optional_max_size`,
    # returns `error.StreamTooLong` and finishes appending.
    # If `optional_max_size` is null, appending is unbounded.
    fn stream_until_delimiter[
        BuffD: Dim
    ](inout self, inout writer: FixedBufferStream[BuffD], delimiter: UInt8) raises:
        while True:
            let byte = self.read_byte()
            if byte == delimiter:
                return
            writer.write_byte(byte)

    # Reads 1 byte from the stream or returns `error.EndOfStream`.
    fn read_byte(inout self) raises -> UInt8:
        let result = Buffer[1, DType.uint8]().stack_allocation()
        let amt_read = self.read(result)
        if amt_read < 1:
            raise Error("End of stream")
        return result[0]


@value
struct FixedBufferStream[D: Dim]:
    var buffer: Buffer[D, DType.uint8]
    var pos: Int

    @always_inline
    fn __init__(inout self, buffer: Buffer[D, DType.uint8]):
        self.buffer = buffer
        self.pos = 0

    @always_inline
    fn read[
        DestDim: Dim
    ](inout self, destination: Buffer[DestDim, DType.uint8]) raises -> Int:
        let size = min(len(destination), len(self.buffer) - self.pos)
        let end = self.pos + size
        memcpy(destination.data, self.buffer.data.offset(self.pos), size)
        self.pos = end
        return size

    # If the returned number of bytes written is less than requested, the
    # buffer is full. Returns `error.NoSpaceLeft` when no bytes would be written.
    # Note: `error.NoSpaceLeft` matches the corresponding error from
    # `std.fs.File.WriteError`.
    fn write[BuffD: Dim](inout self, bytes: Buffer[BuffD, DType.uint8]) raises -> Int:
        if len(bytes) == 0:
            return 0
        if self.pos >= len(self.buffer):
            raise Error("No space left")

        let n = len(bytes) if self.pos + len(bytes) <= len(self.buffer) else len(
            self.buffer
        ) - self.pos

        memcpy(self.buffer.data.offset(self.pos), bytes.data, n)
        self.pos += n

        if n == 0:
            raise Error("No space left")

        return n

    fn write_all[BuffD: Dim](inout self, bytes: Buffer[BuffD, DType.uint8]) raises:
        var index = 0
        while index != len(bytes):
            index += self.write(
                Buffer[Dim(), DType.uint8](bytes.data.offset(index), len(bytes) - index)
            )

    fn write_byte(inout self, byte: UInt8) raises:
        let arr = Buffer[1, DType.uint8]().stack_allocation()
        self.write_all(arr)

    fn seek_to(inout self, pos: Int) raises:
        self.pos = min(len(self.buffer), pos)

    fn seek_by(inout self, amt: Int) raises:
        if amt < 0:
            let abs_amt = abs(amt)
            if abs_amt > self.pos:
                self.pos = 0
            else:
                self.pos -= abs_amt
        else:
            let new_pos = self.pos + amt
            self.pos = min(len(self.buffer), new_pos)

    @always_inline
    fn get_end_pos(self) -> Int:
        return len(self.buffer)

    @always_inline
    fn get_pos(self) -> Int:
        return self.pos

    @always_inline
    fn get_written(self) -> Buffer[Dim(), DType.uint8]:
        return Buffer[Dim(), DType.uint8](self.buffer.data, self.pos)

    @always_inline
    fn reset(inout self):
        self.pos = 0


