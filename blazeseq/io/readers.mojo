# Mojo Zlib binding is copied from ´ish´ https://github.com/BioRadOpenSource/ish/tree/main
"""
Mojo bindings for zlib.

Note that `GZFile` will auto detect compression. If the file is not compressed
it pass through to a normal reader that is quite fast when paired with a
`BufferedReader`.

"""

from std.memory import unsafe_memset_zero, Pointer, unsafe_memcpy
from std.ffi import OwnedDLHandle, c_char
from std.sys.info import CompilationTarget
from std.pathlib import Path
from std.collections.string import String, chr


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

# Type aliases for C types using modern Pointer API.
# These pointers refer to externally managed C memory; we model that
# explicitly with MutUntrackedOrigin so the types are concrete.
comptime c_void_ptr = Pointer[mut=False, UInt8, MutUntrackedOrigin]
comptime c_char_ptr = Pointer[mut=False, c_char, MutUntrackedOrigin]
comptime c_uint = UInt32
comptime c_int = Int32


trait Reader(Deinitable, Movable):
    """Trait for reading bytes from a source (file, memory, gzip, etc.).

    Implement this trait to provide a custom data source to `FastqParser` via
    `BufferedReader`. `read_to_buffer()` fills the given buffer span and returns
    the number of bytes read (0 at EOF). The parser uses this with
    `LineIterator` / `BufferedReader` for efficient line-based parsing.

    Example:
        ```mojo
        from blazeseq.io.readers import Reader
        struct MyReader(Reader):
            def read_to_buffer(mut self, mut buf: Span[Byte, MutUntrackedOrigin], amt: Int, pos: Int) raises -> UInt64:
                # ... copy up to amt bytes from your source into buf starting at pos
                var bytes_read: Int = 0
                return UInt64(bytes_read)
            def __init__(out self, *, deinit move: Self): ...
        ```
    """

    def read_to_buffer(
        mut self, mut buf: Span[Byte, MutUntrackedOrigin], amt: Int, pos: Int
    ) raises -> UInt64:
        """Read up to amt bytes into buf at offset pos. Returns bytes read (0 at EOF).
        """
        ...

    def __init__(out self, *, deinit move: Self):
        ...


# Implement functionality from: Buffer-Reudx rust cate allowing for BufferedReader that supports partial reading and filling ,
# https://github.com/dignifiedquire/buffer-redux


struct FileReader(Movable, Reader):
    """Reader that reads from a file on disk. Use with `FastqParser` for .fastq files.

    Example:
        ```mojo
        from blazeseq import FileReader, FastqParser
        from std.pathlib import Path
        var r = FileReader(Path("data.fastq"))
        var parser = FastqParser[FileReader](r^, "generic")
        for record in parser.records():
            _ = record.id()
        ```
    """

    var handle: FileHandle

    def __init__(out self, path: Path) raises:
        """Open a file for reading.

        Args:
            path: Path to the file (e.g. Path("data.fastq")).

        Raises:
            Error: If the file cannot be opened.
        """
        self.handle = open(path, "r")

    @inline(.always)
    def read_bytes(mut self, amt: Int = -1) raises -> List[Byte]:
        """Read up to amt bytes (or all if amt < 0) as a list of bytes."""
        return self.handle.read_bytes(amt)

    @inline(.always)
    def read_to_buffer(
        mut self,
        mut buf: Span[Byte, MutUntrackedOrigin],
        amt: Int,
        pos: Int = 0,
    ) raises -> UInt64:
        """Read up to amt bytes from the file into buf at offset pos. Returns bytes read.
        """
        if pos > len(buf):
            raise Error("Position is outside the buffer")
        var s = Span[Byte, MutUntrackedOrigin](
            unsafe_ptr=buf.unsafe_ptr().unsafe_offset(pos),
            length=len(buf) - pos,
        )
        if amt > len(s):
            raise Error(
                "Number of elements to read is bigger than the available space"
                " in the buffer"
            )
        if amt < 0:
            raise Error("The amount to be read should be positive")
        var read = self.handle.read(buffer=s)
        return UInt64(read)


struct MemoryReader(Movable, Reader):
    """Reader that reads from an in-memory buffer.

    Use for testing, benchmarking (without disk I/O), or when FASTQ data is
    already in memory. Implements the same Reader trait as FileReader and GZFile.
    """

    var data: List[Byte]
    var position: Int

    def __init__(out self, var data: List[Byte]):
        """Initialize with an owned List[Byte] buffer. Takes ownership of data.
        """
        self.data = data^
        self.position = 0

    def __init__(out self, data: Span[Byte, _]):
        """Initialize with a Span[Byte]; bytes are copied into an internal list.
        """
        self.data = List[Byte](capacity=len(data))
        self.data.extend(data)
        self.position = 0

    def __init__(out self, var content: String) raises:
        """Initialize from a string; copies its bytes into an internal buffer.
        """
        self.data = List(content.as_bytes())
        self.position = 0

    @inline(.always)
    def read_to_buffer(
        mut self,
        mut buf: Span[Byte, MutUntrackedOrigin],
        amt: Int,
        pos: Int = 0,
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
        var s = Span[Byte, MutUntrackedOrigin](
            unsafe_ptr=buf.unsafe_ptr().unsafe_offset(pos),
            length=len(buf) - pos,
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

        # Copy bytes from data to destination buffer using unsafe_memcpy
        if bytes_to_read > 0:
            unsafe_memcpy(
                dest=s.unsafe_ptr(),
                src=self.data.unsafe_ptr().unsafe_offset(self.position),
                count=bytes_to_read,
            )
            self.position += bytes_to_read

        return UInt64(bytes_to_read)

    def reset(mut self):
        """Reset the read position to the start. Use to re-read the same buffer (e.g. for benchmarking).
        """
        self.position = 0

    def __init__(out self, *, deinit move: Self):
        """Move constructor for Movable trait compliance."""
        self.data = move.data^
        self.position = move.position


@doc_hidden
@fieldwise_init
struct ZLib(Movable):
    """Wrapper for zlib library functions."""

    var lib_handle: OwnedDLHandle

    @staticmethod
    def _get_libname() -> StaticString:
        comptime if CompilationTarget.is_macos():
            return "libz.dylib"
        else:
            return "libz.so"

    def __init__(out self) raises:
        """Initialize zlib wrapper."""
        self.lib_handle = OwnedDLHandle(Self._get_libname())

    def gzopen(
        self, mut filename: String, mut mode: String
    ) raises -> Optional[c_void_ptr]:
        """Open a gzip file."""
        return self.lib_handle.call[
            "gzopen", Optional[c_void_ptr], c_char_ptr, c_char_ptr
        ](
            filename.as_c_string_span()
            .ptr()
            .unsafe_origin_cast[MutUntrackedOrigin](),
            mode.as_c_string_span()
            .ptr()
            .unsafe_origin_cast[MutUntrackedOrigin](),
        )

    def gzclose(self, file: c_void_ptr) -> c_int:
        """Close a gzip file."""
        return self.lib_handle.call["gzclose", c_int, c_void_ptr](file)

    def gzread(
        self, file: c_void_ptr, buffer: c_void_ptr, length: c_uint
    ) -> c_int:
        """Read from a gzip file."""
        return self.lib_handle.call[
            "gzread", c_int, c_void_ptr, c_void_ptr, c_uint
        ](file, buffer, length)

    def gzwrite(
        self, file: c_void_ptr, buffer: c_void_ptr, length: c_uint
    ) -> c_int:
        """Write to a gzip file."""
        return self.lib_handle.call[
            "gzwrite", c_int, c_void_ptr, c_void_ptr, c_uint
        ](file, buffer, length)


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
            _ = record.id()
        ```
    """

    var handle: Optional[c_void_ptr]
    var lib: ZLib
    var filename: String
    var mode: String

    def __init__(out self, filename: String, mode: String) raises:
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
        var handle = self.lib.gzopen(self.filename, self.mode)
        if not handle:
            raise Error("Failed to open gzip file: " + filename)
        self.handle = handle

    def __deinit__(deinit self):
        """Close the file when the object is destroyed."""
        if self.handle:
            _ = self.lib.gzclose(self.handle.value())

    def __init__(out self, *, deinit move: Self):
        self.handle = move.handle
        self.lib = move.lib^
        self.filename = move.filename^
        self.mode = move.mode^

    def read_to_buffer(
        mut self, mut buf: Span[Byte, MutUntrackedOrigin], amt: Int, pos: Int
    ) raises -> UInt64:
        """Read decompressed bytes into buf at offset pos. Returns bytes read (0 at EOF).
        """
        if pos > len(buf):
            raise Error("Position is outside the buffer")
        var s = Span[Byte, MutUntrackedOrigin](
            unsafe_ptr=buf.unsafe_ptr().unsafe_offset(pos),
            length=len(buf) - pos,
        )
        if amt > len(s):
            raise Error(
                "Number of elements to read is bigger than the available space"
                " in the buffer"
            )
        if amt < 0:
            raise Error("The amount to be read should be positive")

        var bytes_read = self.lib.gzread(
            self.handle.value(), s.unsafe_ptr(), c_uint(amt)
        )

        return UInt64(bytes_read)

    @doc_hidden
    def unbuffered_read[](
        mut self, buffer: Span[UInt8, MutUntrackedOrigin]
    ) raises -> Int:
        """Read data from the gzip file.

        Args:
            buffer: The buffer to read data into, attempts to fill the buffer.

        Returns:
            The number of bytes read, or an error code if it's less than zero.
        """

        var bytes_read = self.lib.gzread(
            self.handle.value(), buffer.unsafe_ptr(), c_uint(len(buffer))
        )

        if bytes_read < 0:
            raise Error("Error reading from gzip file: " + String(bytes_read))
        return Int(bytes_read)


struct RapidgzipReader(Movable, Reader):
    """Compatibility gzip reader while the rapidgzip dependency is disabled.

    The public `RapidgzipReader` API is preserved for callers and tests, but it
    currently delegates to `GZFile` instead of the external `rapidgzip`
    package. `parallelism` is accepted for API compatibility and ignored.
    """

    var _fallback: GZFile
    var parallelism: UInt32

    def __init__(out self, path: String, parallelism: UInt32 = 0) raises:
        self._fallback = GZFile(path, "rb")
        self.parallelism = parallelism

    def __init__(out self, path: Path, parallelism: UInt32 = 0) raises:
        self._fallback = GZFile(path.path, "rb")
        self.parallelism = parallelism

    def __init__(out self, *, deinit move: Self):
        self._fallback = move._fallback^
        self.parallelism = move.parallelism

    def read_to_buffer(
        mut self, mut buf: Span[Byte, MutUntrackedOrigin], amt: Int, pos: Int
    ) raises -> UInt64:
        return self._fallback.read_to_buffer(buf, amt, pos)
