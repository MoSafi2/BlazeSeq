from std.collections.string import String

from blazeseq.byte_string import BString
from blazeseq.io.writers import Writer


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
    fn name(ref [_]self) -> String:
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

