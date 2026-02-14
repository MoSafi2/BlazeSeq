# Mojo Zlib binding is copied from ´ish´ https://github.com/BioRadOpenSource/ish/tree/main
"""
Mojo bindings for zlib.

Note that `GZFile` will auto detect compression. If the file is not compressed
it pass through to a normal reader that is quite fast when paired with a
BufferedReader.

"""

from memory import memset_zero, UnsafePointer, Span, memcpy
from memory.legacy_unsafe_pointer import LegacyUnsafePointer
from sys import ffi
from sys.info import CompilationTarget
from pathlib import Path
from collections.string import String, chr


# Constants for zlib return codes
comptime Z_OK = 0
comptime Z_STREAM_END = 1
comptime Z_NEED_DICT = 2
comptime Z_ERRNO = -1
comptime Z_STREAM_ERROR = -2
comptime Z_DATA_ERROR = -3
comptime Z_MEM_ERROR = -4
comptime Z_BUF_ERROR = -5
comptime Z_VERSION_ERROR = -6

# Type aliases for C types
comptime c_void_ptr = LegacyUnsafePointer[mut=False, UInt8]
comptime c_char_ptr = LegacyUnsafePointer[mut=False, Int8]
comptime c_uint = UInt32
comptime c_int = Int32

# Define function signatures for zlib functions
comptime gzopen_fn_type = fn (
    filename: c_char_ptr, mode: c_char_ptr
) -> c_void_ptr
comptime gzclose_fn_type = fn (file: c_void_ptr) -> c_int
comptime gzread_fn_type = fn (
    file: c_void_ptr, buf: c_void_ptr, len: c_uint
) -> c_int


trait Reader(ImplicitlyDestructible):
    fn read_to_buffer(
        mut self, mut buf: Span[Byte, MutExternalOrigin], amt: Int, pos: Int
    ) raises -> UInt64:
        ...

    fn __moveinit__(out self, deinit other: Self):
        ...


# Implement functionality from: Buffer-Reudx rust cate allowing for BufferedReader that supports partial reading and filling ,
# https://github.com/dignifiedquire/buffer-redux


struct FileReader(Movable, Reader):
    var handle: FileHandle

    fn __init__(out self, path: Path) raises:
        self.handle = open(path, "r")

    @always_inline
    fn read_bytes(mut self, amt: Int = -1) raises -> List[Byte]:
        return self.handle.read_bytes(amt)

    @always_inline
    fn read_to_buffer(
        mut self, mut buf: Span[Byte, MutExternalOrigin], amt: Int, pos: Int = 0
    ) raises -> UInt64:
        if pos > len(buf):
            raise Error("Position is outside the buffer")
        var s = Span[Byte, MutExternalOrigin](
            ptr=buf.unsafe_ptr() + pos, length=len(buf) - pos
        )
        if amt > len(s):
            raise Error(
                "Number of elements to read is bigger than the available space"
                " in the buffer"
            )
        if amt < 0:
            raise Error("The amount to be read should be positive")
        read = self.handle.read(buffer=s)
        return UInt64(read)


struct MemoryReader(Movable, Reader):
    """Reader that reads from an in-memory buffer.

    Allows BufferedReader to read from memory instead of disk I/O,
    enabling disk I/O independent performance testing.
    """

    var data: List[Byte]
    var position: Int

    fn __init__(out self, var data: List[Byte]):
        """Initialize with a List[Byte] buffer.

        Args:
            data: The source data buffer (owned).
        """
        self.data = data^
        self.position = 0

    fn __init__(out self, data: Span[Byte]):
        """Initialize with a Span[Byte] buffer (copies into owned list).

        Args:
            data: The source data buffer (will be copied).
        """
        self.data = List[Byte](capacity=len(data))
        for i in range(len(data)):
            self.data.append(data[i])
        self.position = 0

    fn __init__(out self, var content: String) raises:
        self.data = List(content.as_bytes())
        self.position = 0

    @always_inline
    fn read_to_buffer(
        mut self, mut buf: Span[Byte, MutExternalOrigin], amt: Int, pos: Int = 0
    ) raises -> UInt64:
        """Read bytes from the memory buffer into the destination buffer.

        Args:
            buf: The destination buffer to write into.
            amt: The number of bytes to read.
            pos: The position in the destination buffer to start writing.

        Returns:
            The number of bytes actually read (0 if EOF).
        """
        if pos > len(buf):
            raise Error("Position is outside the buffer")
        var s = Span[Byte, MutExternalOrigin](
            ptr=buf.unsafe_ptr() + pos, length=len(buf) - pos
        )
        if amt > len(s):
            raise Error(
                "Number of elements to read is bigger than the available space"
                " in the buffer"
            )
        if amt < 0:
            raise Error("The amount to be read should be positive")

        # Check if we've reached EOF
        if self.position >= len(self.data):
            return 0

        # Calculate how many bytes we can actually read
        var available = len(self.data) - self.position
        var bytes_to_read = min(amt, available)

        # Copy bytes from data to destination buffer
        if bytes_to_read > 0:
            for i in range(bytes_to_read):
                s[i] = self.data[self.position + i]
            self.position += bytes_to_read

        return UInt64(bytes_to_read)

    fn __moveinit__(out self, deinit other: Self):
        """Move constructor for Movable trait compliance."""
        self.data = other.data^
        self.position = other.position


struct SyntheticFastqReader(Movable, Reader):
    """
    Reader that generates synthetic FASTQ data on demand.
    Takes num_reads and read_len; each read has sequence ACGT-repeated and
    quality scores in Sanger range (33–73). Use with BatchedParser to get
    FastqBatch iterators that can be processed on CPU or uploaded for GPU.
    """

    var num_reads: Int
    var read_len: Int
    var current_read: Int
    var _pending: List[Byte]

    fn __init__(out self, num_reads: Int, read_len: Int = 100):
        """Initialize with number of reads to generate and length per read."""
        self.num_reads = num_reads
        self.read_len = read_len
        self.current_read = 0
        self._pending = List[Byte]()

    fn _generate_one_record(mut self) raises:
        """Append one FASTQ record (4 lines) to _pending."""
        if self.current_read >= self.num_reads:
            return
        var r = self.current_read
        self.current_read += 1
        var bases = ["A", "C", "G", "T"]
        var header = "@read_" + String(r) + "\n"
        var seq = String(capacity=self.read_len)
        var qual = String(capacity=self.read_len)
        for p in range(self.read_len):
            seq += bases[r % 4]
            var q_ascii = 33 + (r + p) % 41
            qual += chr(q_ascii)
        var record_str = header + seq + "\n+\n" + qual
        var record_bytes = record_str.as_bytes()
        for i in range(len(record_bytes)):
            self._pending.append(record_bytes[i])

    fn read_to_buffer(
        mut self, mut buf: Span[Byte, MutExternalOrigin], amt: Int, pos: Int = 0
    ) raises -> UInt64:
        """Read generated FASTQ bytes into the buffer. Returns 0 when all reads consumed."""
        if pos > len(buf):
            raise Error("Position is outside the buffer")
        var s = Span[Byte, MutExternalOrigin](
            ptr=buf.unsafe_ptr() + pos, length=len(buf) - pos
        )
        if amt > len(s):
            raise Error(
                "Number of elements to read is bigger than the available space"
                " in the buffer"
            )
        if amt < 0:
            raise Error("The amount to be read should be positive")

        var written: Int = 0
        while written < amt and (len(self._pending) > 0 or self.current_read < self.num_reads):
            if len(self._pending) == 0:
                self._generate_one_record()
            if len(self._pending) == 0:
                break
            var to_copy = min(amt - written, len(self._pending))
            for i in range(to_copy):
                s[written + i] = self._pending[i]
            written += to_copy
            var new_pending = List[Byte](capacity=len(self._pending) - to_copy)
            for i in range(to_copy, len(self._pending)):
                new_pending.append(self._pending[i])
            self._pending = new_pending^
        return UInt64(written)

    fn __moveinit__(out self, deinit other: Self):
        self.num_reads = other.num_reads
        self.read_len = other.read_len
        self.current_read = other.current_read
        self._pending = other._pending^


@fieldwise_init
struct ZLib(Movable):
    """Wrapper for zlib library functions."""

    var lib_handle: ffi.OwnedDLHandle

    @staticmethod
    fn _get_libname() -> StaticString:
        @parameter
        if CompilationTarget.is_macos():
            return "libz.dylib"
        else:
            return "libz.so"

    fn __init__(out self) raises:
        """Initialize zlib wrapper."""
        self.lib_handle = ffi.OwnedDLHandle(Self._get_libname())

    fn gzopen(
        self, mut filename: String, mut mode: String
    ) raises -> c_void_ptr:
        """Open a gzip file."""
        # Get function pointer
        var func = self.lib_handle.get_function[gzopen_fn_type]("gzopen")

        # Call the function
        var result = func(
            filename.as_c_string_slice().unsafe_ptr(),
            mode.as_c_string_slice().unsafe_ptr(),
        )

        return result

    fn gzclose(self, file: c_void_ptr) -> c_int:
        """Close a gzip file."""
        var func = self.lib_handle.get_function[gzclose_fn_type]("gzclose")
        return func(file)

    fn gzread(
        self, file: c_void_ptr, buffer: c_void_ptr, length: c_uint
    ) -> c_int:
        """Read from a gzip file."""
        var func = self.lib_handle.get_function[gzread_fn_type]("gzread")
        return func(file, buffer, length)


struct GZFile(Movable, Reader):
    """Helper class for gzip file operations."""

    var handle: c_void_ptr
    var lib: ZLib
    var filename: String
    var mode: String

    fn __init__(out self, filename: String, mode: String) raises:
        """Open a gzip file."""
        self.lib = ZLib()
        # Note: must keep filename and mode because gzopen takes a ref to them and they need to live as long as the file is open.
        self.filename = filename
        self.mode = mode
        self.handle = self.lib.gzopen(self.filename, self.mode)
        if self.handle == c_void_ptr():
            raise Error("Failed to open gzip file: " + filename)

    fn __del__(deinit self):
        """Close the file when the object is destroyed."""
        if self.handle != c_void_ptr():
            _ = self.lib.gzclose(self.handle)

    fn __moveinit__(out self, deinit other: Self):
        self.handle = other.handle
        self.lib = other.lib^
        self.filename = other.filename^
        self.mode = other.mode^

    fn read_to_buffer(
        mut self, mut buf: Span[Byte, MutExternalOrigin], amt: Int, pos: Int
    ) raises -> UInt64:
        if pos > len(buf):
            raise Error("Position is outside the buffer")
        var s = Span[Byte, MutExternalOrigin](
            ptr=buf.unsafe_ptr() + pos, length=len(buf) - pos
        )
        if amt > len(s):
            raise Error(
                "Number of elements to read is bigger than the available space"
                " in the buffer"
            )
        if amt < 0:
            raise Error("The amount to be read should be positive")

        var bytes_read = self.lib.gzread(
            self.handle, s.unsafe_ptr(), c_uint(len(s))
        )

        return UInt64(bytes_read)

    fn unbuffered_read[](
        mut self, buffer: Span[UInt8, MutExternalOrigin]
    ) raises -> Int:
        """Read data from the gzip file.

        Args:
            buffer: The buffer to read data into, attempts to fill the buffer.

        Returns:
            The number of bytes read, or an error code if it's less than zero.
        """

        var bytes_read = self.lib.gzread(
            self.handle, buffer.unsafe_ptr(), c_uint(len(buffer))
        )

        if bytes_read < 0:
            raise Error("Error reading from gzip file: " + String(bytes_read))
        return Int(bytes_read)
