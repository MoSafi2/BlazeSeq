# Mojo Zlib binding is copied from ´ish´ https://github.com/BioRadOpenSource/ish/tree/main
"""
Mojo bindings for zlib.

Note that `GZFile` will auto detect compression. If the file is not compressed
it pass through to a normal reader that is quite fast when paired with a
`BufferedReader`.

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
comptime gzwrite_fn_type = fn (
    file: c_void_ptr, buf: c_void_ptr, len: c_uint
) -> c_int


trait Reader(ImplicitlyDestructible):
    """Trait for reading bytes from a source (file, memory, gzip, etc.).
    
    Implement this trait to provide a custom data source to `FastqParser` via
    `BufferedReader`. `read_to_buffer()` fills the given buffer span and returns
    the number of bytes read (0 at EOF). The parser uses this with
    `LineIterator` / `BufferedReader` for efficient line-based parsing.
    
    Example:
        ```mojo
        struct MyReader(Reader):
            fn read_to_buffer(mut self, mut buf: Span[Byte, MutExternalOrigin], amt: Int, pos: Int) raises -> UInt64:
                # ... copy up to amt bytes from your source into buf starting at pos
                return bytes_read
            fn __moveinit__(out self, deinit other: Self): ...
        ```
    """
    fn read_to_buffer(
        mut self, mut buf: Span[Byte, MutExternalOrigin], amt: Int, pos: Int
    ) raises -> UInt64:
        """Read up to amt bytes into buf at offset pos. Returns bytes read (0 at EOF)."""
        ...

    fn __moveinit__(out self, deinit other: Self):
        ...


# Implement functionality from: Buffer-Reudx rust cate allowing for BufferedReader that supports partial reading and filling ,
# https://github.com/dignifiedquire/buffer-redux


struct FileReader(Movable, Reader):
    """Reader that reads from a file on disk. Use with `FastqParser` for .fastq files.

    Example:
        ```mojo
        from blazeseq import FileReader, FastqParser
        from pathlib import Path
        var r = FileReader(Path("data.fastq"))
        var parser = FastqParser[FileReader](r^, "generic")
        for record in parser.records():
            _ = record.id_slice()
        ```
    """

    var handle: FileHandle

    fn __init__(out self, path: Path) raises:
        """Open a file for reading.
        
        Args:
            path: Path to the file (e.g. Path("data.fastq")).
        
        Raises:
            Error: If the file cannot be opened.
        """
        self.handle = open(path, "r")

    @always_inline
    fn read_bytes(mut self, amt: Int = -1) raises -> List[Byte]:
        """Read up to amt bytes (or all if amt < 0) as a list of bytes."""
        return self.handle.read_bytes(amt)

    @always_inline
    fn read_to_buffer(
        mut self, mut buf: Span[Byte, MutExternalOrigin], amt: Int, pos: Int = 0
    ) raises -> UInt64:
        """Read up to amt bytes from the file into buf at offset pos. Returns bytes read."""
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
    
    Use for testing, benchmarking (without disk I/O), or when FASTQ data is
    already in memory. Implements the same Reader trait as FileReader and GZFile.
    """

    var data: List[Byte]
    var position: Int

    fn __init__(out self, var data: List[Byte]):
        """Initialize with an owned List[Byte] buffer. Takes ownership of data."""
        self.data = data^
        self.position = 0

    fn __init__(out self, data: Span[Byte]):
        """Initialize with a Span[Byte]; bytes are copied into an internal list."""
        self.data = List[Byte](capacity=len(data))
        self.data.extend(data)
        self.position = 0

    fn __init__(out self, var content: String) raises:
        """Initialize from a string; copies its bytes into an internal buffer."""
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

        # Copy bytes from data to destination buffer using memcpy
        if bytes_to_read > 0:
            memcpy(
                dest=s.unsafe_ptr(),
                src=self.data.unsafe_ptr() + self.position,
                count=bytes_to_read,
            )
            self.position += bytes_to_read

        return UInt64(bytes_to_read)

    fn reset(mut self):
        """Reset the read position to the start. Use to re-read the same buffer (e.g. for benchmarking)."""
        self.position = 0

    fn __moveinit__(out self, deinit other: Self):
        """Move constructor for Movable trait compliance."""
        self.data = other.data^
        self.position = other.position


@doc_private
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

    fn gzwrite(
        self, file: c_void_ptr, buffer: c_void_ptr, length: c_uint
    ) -> c_int:
        """Write to a gzip file."""
        var func = self.lib_handle.get_function[gzwrite_fn_type]("gzwrite")
        return func(file, buffer, length)


struct GZFile(Movable, Reader):
    """Reader for gzip-compressed files (.gz). Implements the `Reader` trait like `FileReader`.
    
    Use for .fastq.gz files with `FastqParser`. Some builds auto-detect uncompressed
    files and pass through; see module docstring. Same interface as `FileReader`
    for drop-in use with parsers.

    Example:
        ```mojo
        from blazeseq import GZFile, FastqParser
        var r = GZFile("data.fastq.gz", "rb")
        var parser = FastqParser[GZFile](r^, "illumina_1.8")
        for record in parser.records():
            _ = record.id_slice()
        ```
    """

    var handle: c_void_ptr
    var lib: ZLib
    var filename: String
    var mode: String

    fn __init__(out self, filename: String, mode: String) raises:
        """Open a gzip file (e.g. mode "rb" for read binary).
        
        Args:
            filename: Path to the .gz file.
            mode: Open mode (e.g. "rb").
        
        Raises:
            Error: If the file cannot be opened.
        """
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
        """Read decompressed bytes into buf at offset pos. Returns bytes read (0 at EOF)."""
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

    @doc_private
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
