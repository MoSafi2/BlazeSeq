from std.collections.string import String, StringSlice
from std.memory import Span

from blazeseq.byte_string import BString
from blazeseq.io.writers import Writer


# ---------------------------------------------------------------------------
# FaiView — zero-alloc, NOT to be stored
# ---------------------------------------------------------------------------

#TODO: Add TrivialRegisterPassable when Optional has conditional conformance
struct FaiView[O: Origin](Movable, Sized):
    """Zero-copy view over one FAI index row in the parser's buffer.

    Lifetime: Valid only until the next parser read. Do not store in
    collections; call `.to_record()` to get an owned `FaiRecord` when the
    record must outlive the current iteration step.
    """

    var _name: Span[UInt8, Self.O]
    var _length: Int64
    var _offset: Int64
    var _line_bases: Int64
    var _line_width: Int64
    var _qual_offset: Optional[Int64]

    fn __init__(
        out self,
        _name: Span[UInt8, Self.O],
        _length: Int64,
        _offset: Int64,
        _line_bases: Int64,
        _line_width: Int64,
        _qual_offset: Optional[Int64],
    ):
        self._name = _name
        self._length = _length
        self._offset = _offset
        self._line_bases = _line_bases
        self._line_width = _line_width
        self._qual_offset = _qual_offset

    @always_inline
    fn name(self) -> StringSlice[origin=Self.O]:
        """Return the sequence name (valid only while view is valid)."""
        return StringSlice[origin=Self.O](unsafe_from_utf8=self._name)

    @always_inline
    fn length(self) -> Int64:
        return self._length

    @always_inline
    fn offset(self) -> Int64:
        return self._offset

    @always_inline
    fn line_bases(self) -> Int64:
        return self._line_bases

    @always_inline
    fn line_width(self) -> Int64:
        return self._line_width

    @always_inline
    fn qual_offset(self) -> Optional[Int64]:
        return self._qual_offset

    @always_inline
    fn __len__(self) -> Int:
        """Return the reference length as an Int."""
        return Int(self._length)

    fn to_record(self) -> FaiRecord:
        """Materialize an owned `FaiRecord`. Call when the record must outlive the view.
        """
        return FaiRecord(
            Name=BString(self._name),
            Length=self._length,
            Offset=self._offset,
            LineBases=self._line_bases,
            LineWidth=self._line_width,
            QualOffset=self._qual_offset,
        )


# ---------------------------------------------------------------------------
# FaiRecord — owned, storeable
# ---------------------------------------------------------------------------


@fieldwise_init
struct FaiRecord(Copyable, Movable, Sized, Writable):
    """Single entry from a FASTA/FASTQ .fai index file.

    Columns (TAB-delimited):
        1. NAME        – reference sequence name
        2. LENGTH      – total length of the reference (bases)
        3. OFFSET      – byte offset of the first base in the FASTA/FASTQ file
        4. LINEBASES   – number of bases per sequence line
        5. LINEWIDTH   – number of bytes per sequence line (including newline)
        6. QUALOFFSET  – (FASTQ only) byte offset of first quality character
                         or None for FASTA 5-column indexes.
    """

    var Name: BString
    var Length: Int64
    var Offset: Int64
    var LineBases: Int64
    var LineWidth: Int64
    var QualOffset: Optional[Int64]

    @always_inline
    fn name(ref[_] self) -> String:
        return self.Name.to_string()

    @always_inline
    fn length(self) -> Int64:
        return self.Length

    @always_inline
    fn offset(self) -> Int64:
        return self.Offset

    @always_inline
    fn line_bases(self) -> Int64:
        return self.LineBases

    @always_inline
    fn line_width(self) -> Int64:
        return self.LineWidth

    @always_inline
    fn qual_offset(self) -> Optional[Int64]:
        return self.QualOffset

    @always_inline
    fn __len__(self) -> Int:
        """Return the reference length as an Int."""
        return Int(self.Length)

    fn write_to[w: Writer](self, mut writer: w):
        """Write this record as a single .fai line."""
        writer.write(self.Name.to_string())
        writer.write("\t")
        writer.write(String(self.Length))
        writer.write("\t")
        writer.write(String(self.Offset))
        writer.write("\t")
        writer.write(String(self.LineBases))
        writer.write("\t")
        writer.write(String(self.LineWidth))
        if self.QualOffset:
            writer.write("\t")
            writer.write(String(self.QualOffset.value()))
