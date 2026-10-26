"""Writer trait and implementations for various output backends.

Provides a unified abstraction for writing bytes to files, memory buffers,
or compressed files. Similar to the Reader trait but for writing operations.
"""

from std.memory import Pointer
from std.pathlib import Path
from std.collections.string import String
from blazeseq.io.readers import ZLib, c_void_ptr, c_uint


trait WriterBackend(Deinitable, Movable):
    """Trait for writing bytes to various backends.

    Similar to `Reader` trait but for writing operations.
    Implementations provide `write_from_buffer()` to write bytes
    from a buffer to the underlying storage.
    """

    def write_from_buffer(
        mut self,
        mut buf: Span[Byte, MutUntrackedOrigin],
        amt: Int,
        pos: Int = 0,
    ) raises -> UInt64:
        """Write bytes from a buffer to the underlying storage.

        Args:
            buf: Source buffer containing bytes to write.
            amt: Number of bytes to write (must be <= len(buf) - pos).
            pos: Starting position in buf (default 0).

        Returns:
            Number of bytes actually written.

        Raises:
            Error: If writing fails or parameters are invalid.
        """
        ...

    def __init__(out self, *, deinit move: Self):
        """Move constructor for Movable trait compliance."""
        ...


struct FileWriter(Movable, WriterBackend):
    """Writer that writes to plain files.

    Example:
        ```mojo
        from blazeseq.io.buffered import buffered_writer_for_file
        from std.pathlib import Path
        from std.collections.string import String
        var writer = buffered_writer_for_file(Path("out.fastq"))
        var data = List(String("@read1\nACGT\n+\nIIII\n").as_bytes())
        writer.write_bytes(data)
        writer.flush()
        ```
    """

    var handle: FileHandle

    def __init__(out self, path: Path) raises:
        """Initialize FileWriter with a file path.

        Args:
            path: Path to the output file.

        Raises:
            Error: If the file cannot be opened for writing.
        """
        self.handle = open(path, "w")

    @inline(.always)
    def write_from_buffer(
        mut self,
        mut buf: Span[Byte, MutUntrackedOrigin],
        amt: Int,
        pos: Int = 0,
    ) raises -> UInt64:
        """Write bytes from buffer to file."""
        if pos > len(buf):
            raise Error("Position is outside the buffer")
        var s = Span[Byte, MutUntrackedOrigin](
            unsafe_ptr=buf.unsafe_ptr().unsafe_offset(pos),
            length=len(buf) - pos,
        )
        if amt > len(s):
            raise Error(
                "Number of elements to write is bigger than the available space"
                " in the buffer"
            )
        if amt < 0:
            raise Error("The amount to be written should be positive")

        var write_span = Span[Byte, MutUntrackedOrigin](
            unsafe_ptr=s.unsafe_ptr(), length=amt
        )
        var bytes_list = List[Byte](capacity=amt)
        bytes_list.extend(write_span)
        self.handle.write_bytes(bytes_list)
        return UInt64(amt)

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.handle = move.handle^


struct MemoryWriter(Movable, WriterBackend):
    """Writer that writes to an in-memory buffer.

    Useful for testing, string building, or when you need to
    collect output in memory before writing to a file.
    """

    var data: List[Byte]

    def __init__(out self):
        """Initialize MemoryWriter with an empty buffer."""
        self.data = List[Byte]()

    @inline(.always)
    def write_from_buffer(
        mut self,
        mut buf: Span[Byte, MutUntrackedOrigin],
        amt: Int,
        pos: Int = 0,
    ) raises -> UInt64:
        """Write bytes from buffer to memory."""
        if pos > len(buf):
            raise Error("Position is outside the buffer")
        var s = Span[Byte, MutUntrackedOrigin](
            unsafe_ptr=buf.unsafe_ptr().unsafe_offset(pos),
            length=len(buf) - pos,
        )
        if amt > len(s):
            raise Error(
                "Number of elements to write is bigger than the available space"
                " in the buffer"
            )
        if amt < 0:
            raise Error("The amount to be written should be positive")

        var write_span = Span[Byte, MutUntrackedOrigin](
            unsafe_ptr=s.unsafe_ptr(), length=amt
        )
        self.data.extend(write_span)
        return UInt64(amt)

    def get_data(self) -> List[Byte]:
        """Get a copy of the written data."""
        return self.data.copy()

    def get_data_ref(self) -> Span[Byte, origin_of(self.data)]:
        """Get owned reference to the written data."""
        return Span[Byte, origin_of(self.data)](
            unsafe_ptr=self.data.unsafe_ptr(), length=len(self.data)
        )

    def clear(mut self):
        """Clear the buffer."""
        self.data.clear()

    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.data = move.data^


struct GZWriter(Movable, WriterBackend):
    """Writer for gzip-compressed files."""

    var handle: Optional[c_void_ptr]
    var lib: ZLib
    var filename: String
    var mode: String

    def __init__(out self, filename: String, mode: String = "wb") raises:
        """Initialize GZWriter with a file path.

        Args:
            filename: Path to the output .gz file.
            mode: File mode (default "wb" for write binary).

        Raises:
            Error: If the file cannot be opened for writing.
        """
        self.lib = ZLib()
        self.filename = filename
        self.mode = mode
        var handle = self.lib.gzopen(self.filename, self.mode)
        if not handle:
            raise Error("Failed to open gzip file for writing: " + filename)
        self.handle = handle

    @inline(.always)
    def write_from_buffer(
        mut self,
        mut buf: Span[Byte, MutUntrackedOrigin],
        amt: Int,
        pos: Int = 0,
    ) raises -> UInt64:
        """Write bytes from buffer to compressed file."""
        if pos > len(buf):
            raise Error("Position is outside the buffer")
        var s = Span[Byte, MutUntrackedOrigin](
            unsafe_ptr=buf.unsafe_ptr().unsafe_offset(pos),
            length=len(buf) - pos,
        )
        if amt > len(s):
            raise Error(
                "Number of elements to write is bigger than the available space"
                " in the buffer"
            )
        if amt < 0:
            raise Error("The amount to be written should be positive")

        var write_span = Span[Byte, MutUntrackedOrigin](
            unsafe_ptr=s.unsafe_ptr(), length=amt
        )
        var bytes_written = self.lib.gzwrite(
            self.handle.value(), write_span.unsafe_ptr(), c_uint(amt)
        )

        if bytes_written < 0:
            raise Error("Error writing to gzip file: " + String(bytes_written))

        return UInt64(bytes_written)

    def __deinit__(deinit self):
        """Close the file when the object is destroyed."""
        if self.handle:
            _ = self.lib.gzclose(self.handle.value())

    # Move constructor using unified init naming in Mojo 26.2.
    def __init__(out self, *, deinit move: Self):
        """Move constructor."""
        self.handle = move.handle
        self.lib = move.lib^
        self.filename = move.filename^
        self.mode = move.mode^
