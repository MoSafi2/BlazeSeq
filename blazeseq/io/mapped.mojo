"""Zero-copy memory-mapped file access.

Maps a file read-only into the address space so parsers can scan the bytes
in place without the kernel copying them into a user-space buffer. On the
buffered `read()` path that copy dominates wall time for local files; an
mmap-backed reader eliminates it entirely.

POSIX only (Linux/macOS). C symbols are resolved through a dynamic-libraries
handle so they cannot collide with stdlib extern declarations.
"""

from std.ffi import OwnedDLHandle
from std.memory import Pointer
from std.pathlib import Path
from std.sys.info import CompilationTarget


comptime PROT_READ = 1
comptime MAP_PRIVATE = 2
comptime MADV_SEQUENTIAL = 2
comptime SEEK_END = 2
comptime O_RDONLY = 0

comptime c_void_ptr = Pointer[mut=False, UInt8, MutUntrackedOrigin]
comptime c_char_ptr = Pointer[mut=False, Int8, MutUntrackedOrigin]


@doc_hidden
struct _Libc:
    """Lazy dlopen handle over the system C library."""

    var handle: OwnedDLHandle

    @staticmethod
    def _get_libname() -> StaticString:
        comptime if CompilationTarget.is_macos():
            return "libSystem.dylib"
        else:
            return "libc.so.6"

    def __init__(out self) raises:
        self.handle = OwnedDLHandle(Self._get_libname())


struct MappedFile(Movable, Deinitable):
    """Read-only memory map of a file.

    Example:
        ```mojo
        var mapped = MappedFile(Path("data.fastq"))
        var view = mapped.view()  # Span[Byte] over the whole file
        ```

    The mapping lives for the lifetime of the struct; `__deinit__` unmaps and
    closes the descriptor. Keep the struct alive while any view into it is
    used — views do not extend the mapping's lifetime.
    """

    var _ptr: c_void_ptr
    var _length: Int
    var _fd: Int
    var _libc: _Libc

    def __init__(out self, path: Path) raises:
        self._libc = _Libc()
        self._ptr = c_void_ptr(unsafe_from_address=1)
        self._length = 0
        var path_str = String(path)
        var cpath = path_str.as_c_string_slice()
        self._fd = self._libc.handle.call["open", Int, c_char_ptr, Int](
            cpath.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin](),
            O_RDONLY,
        )
        if self._fd < 0:
            raise Error("MappedFile: cannot open '" + String(path) + "'")
        self._length = self._libc.handle.call[
            "lseek", Int, Int, Int, Int
        ](self._fd, 0, SEEK_END)
        if self._length <= 0:
            if self._length < 0:
                raise Error("MappedFile: cannot seek '" + String(path) + "'")
            return  # empty file; ptr stays sentinel, length 0
        self._ptr = self._libc.handle.call[
            "mmap",
            c_void_ptr,
            Int,
            Int,
            Int,
            Int,
            Int,
            Int,
        ](
            0,
            self._length,
            PROT_READ,
            MAP_PRIVATE,
            self._fd,
            0,
        )
        if Int(self._ptr) == -1:
            raise Error("MappedFile: mmap failed for '" + String(path) + "'")
        _ = self._libc.handle.call[
            "madvise", Int, c_void_ptr, Int, Int
        ](self._ptr, self._length, MADV_SEQUENTIAL)


    @always_inline
    def _close_fd(mut self):
        _ = self._libc.handle.call["close", Int, Int](self._fd)

    def __init__(out self, *, deinit move: Self):
        self._ptr = move._ptr
        self._length = move._length
        self._fd = move._fd
        self._libc = move._libc^

    def __deinit__(deinit self):
        if self._length > 0:
            _ = self._libc.handle.call[
                "munmap", Int, c_void_ptr, Int
            ](self._ptr, self._length)
        self._close_fd()

    @always_inline
    def size(self) -> Int:
        return self._length

    @always_inline
    def view(self) -> Span[Byte, MutUntrackedOrigin]:
        """Whole-file byte span. Empty file yields a zero-length span."""
        return Span[Byte, MutUntrackedOrigin](
            unsafe_ptr=Pointer[Byte, MutUntrackedOrigin](
                unsafe_from_address=Int(self._ptr)
            ),
            length=self._length,
        )
