# Mojo Zlib binding is copied from ´ish´ https://github.com/BioRadOpenSource/ish/tree/main
"""
Mojo bindings for zlib.

Note that `GZFile` will auto detect compression. If the file is not compressed
it pass through to a normal reader that is quite fast when paired with a
BufferedReader.

"""

from memory import memset_zero, UnsafePointer
from sys import ffi
from sys.info import CompilationTarget
from blazeseq.iostream import Reader, InnerBuffer


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
comptime c_void_ptr = UnsafePointer[UInt8, MutExternalOrigin]
comptime c_char_ptr = UnsafePointer[Int8]
comptime c_uint = UInt32
comptime c_int = Int32

# Define function signatures for zlib functions
comptime gzopen_fn_type = fn (filename: c_char_ptr, mode: c_char_ptr) -> c_void_ptr
comptime gzclose_fn_type = fn (file: c_void_ptr) -> c_int
comptime gzread_fn_type = fn (
    file: c_void_ptr, buf: c_void_ptr, len: c_uint
) -> c_int


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
        var result = func(filename.as_c_string_slice(), mode.as_c_string_slice())

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
        mut self, mut buf: InnerBuffer, amt: Int, pos: Int
    ) raises -> UInt64:
        s = buf.as_span(pos=pos)
        if amt > len(s):
            raise Error(
                "Number of elements to read is bigger than the available space"
                " in the buffer"
            )
        if amt < 0:
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
