"""BED (Browser Extensible Data) record types.

BED uses 0-based, half-open coordinates [chromStart, chromEnd).
Standard BED fields: chrom, chromStart, chromEnd (required), then optional
name, score, strand, thickStart, thickEnd, itemRgb, blockCount, blockSizes, blockStarts.
"""

from std.collections import List
from std.collections.string import String, StringSlice
from std.memory import Span

from blazeseq.byte_string import BString
from blazeseq.io.writers import Writer


# ---------------------------------------------------------------------------
# Strand
# ---------------------------------------------------------------------------

struct Strand(Copyable, Equatable, TrivialRegisterPassable, Writable):
    """Strand of a BED feature: Plus (+), Minus (-), or Unknown (.)."""

    var value: Int8

    @always_inline
    fn __init__(out self, value: Int8):
        self.value = value

    comptime Plus = Self(0)
    comptime Minus = Self(1)
    comptime Unknown = Self(2)

    @always_inline
    fn __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    fn write_to[w: Writer](self, mut writer: w):
        if self.value == 0:
            writer.write("+")
        elif self.value == 1:
            writer.write("-")
        else:
            writer.write(".")


# ---------------------------------------------------------------------------
# ItemRgb — display color (0 or r,g,b each 0-255)
# ---------------------------------------------------------------------------

struct ItemRgb(Copyable, Movable, Writable):
    """BED itemRgb: either black (0) or (r,g,b) each 0-255."""

    var r: UInt8
    var g: UInt8
    var b: UInt8

    @always_inline
    fn __init__(out self, r: UInt8, g: UInt8, b: UInt8):
        self.r = r
        self.g = g
        self.b = b

    @always_inline
    fn is_black(self) -> Bool:
        """True if 0,0,0 (or the single 0 value)."""
        return self.r == 0 and self.g == 0 and self.b == 0

    fn write_to[w: Writer](self, mut writer: w):
        writer.write(String(self.r))
        writer.write(",")
        writer.write(String(self.g))
        writer.write(",")
        writer.write(String(self.b))


# ---------------------------------------------------------------------------
# BedRecordView — zero-alloc, NOT to be stored
# ---------------------------------------------------------------------------

struct BedRecordView[O: Origin](Movable):
    """Zero-copy view over one BED data line in the parser's buffer.

    Lifetime: Valid only until the next parser read. Do not store;
    call `.to_record()` when the record must outlive the current iteration.

    Coordinates are 0-based, half-open [chrom_start, chrom_end).
    """

    var _chrom: Span[UInt8, Self.O]
    var _chrom_start: Int64
    var _chrom_end: Int64
    var _name: Optional[Span[UInt8, Self.O]]
    var _score: Optional[Int]
    var _strand: Optional[Strand]
    var _thick_start: Optional[Int64]
    var _thick_end: Optional[Int64]
    var _item_rgb: Optional[ItemRgb]
    var _block_count: Optional[Int]
    var _block_sizes_span: Optional[Span[UInt8, Self.O]]
    var _block_starts_span: Optional[Span[UInt8, Self.O]]
    var _num_fields: Int

    fn __init__(
        out self,
        _chrom: Span[UInt8, Self.O],
        _chrom_start: Int64,
        _chrom_end: Int64,
        _name: Optional[Span[UInt8, Self.O]],
        _score: Optional[Int],
        _strand: Optional[Strand],
        _thick_start: Optional[Int64],
        _thick_end: Optional[Int64],
        _item_rgb: Optional[ItemRgb],
        _block_count: Optional[Int],
        _block_sizes_span: Optional[Span[UInt8, Self.O]],
        _block_starts_span: Optional[Span[UInt8, Self.O]],
        _num_fields: Int,
    ):
        self._chrom = _chrom
        self._chrom_start = _chrom_start
        self._chrom_end = _chrom_end
        self._name = _name
        self._score = _score
        self._strand = _strand
        self._thick_start = _thick_start
        self._thick_end = _thick_end
        if _item_rgb:
            self._item_rgb = Optional(_item_rgb.value().copy())
        else:
            self._item_rgb = None
        self._block_count = _block_count
        self._block_sizes_span = _block_sizes_span
        self._block_starts_span = _block_starts_span
        self._num_fields = _num_fields

    @always_inline
    fn chrom(self) -> StringSlice[origin=Self.O]:
        return StringSlice[origin=Self.O](unsafe_from_utf8=self._chrom)

    @always_inline
    fn chrom_start(self) -> Int64:
        return self._chrom_start

    @always_inline
    fn chrom_end(self) -> Int64:
        return self._chrom_end

    @always_inline
    fn name(self) -> Optional[StringSlice[origin=Self.O]]:
        if not self._name:
            return None
        return StringSlice[origin=Self.O](unsafe_from_utf8=self._name.value())

    @always_inline
    fn score(self) -> Optional[Int]:
        return self._score

    @always_inline
    fn strand(self) -> Optional[Strand]:
        return self._strand

    @always_inline
    fn thick_start(self) -> Optional[Int64]:
        return self._thick_start

    @always_inline
    fn thick_end(self) -> Optional[Int64]:
        return self._thick_end

    @always_inline
    fn item_rgb(self) -> Optional[ItemRgb]:
        return self._item_rgb

    @always_inline
    fn block_count(self) -> Optional[Int]:
        return self._block_count

    @always_inline
    fn num_fields(self) -> Int:
        return self._num_fields

    fn to_record(self) raises -> BedRecord:
        """Materialize an owned BedRecord. Call when the record must outlive the view."""
        var block_sizes: Optional[List[Int64]] = None
        var block_starts: Optional[List[Int64]] = None
        if self._block_sizes_span and self._block_starts_span:
            block_sizes = _parse_comma_sep_int64_list(
                self._block_sizes_span.value()
            )
            block_starts = _parse_comma_sep_int64_list(
                self._block_starts_span.value()
            )
        var name_opt: Optional[BString] = None
        if self._name:
            name_opt = BString(self._name.value())
        return BedRecord(
            Chrom=BString(self._chrom),
            ChromStart=self._chrom_start,
            ChromEnd=self._chrom_end,
            Name=name_opt^ if name_opt else None,
            Score=self._score,
            Strand=self._strand,
            ThickStart=self._thick_start,
            ThickEnd=self._thick_end,
            ItemRgb=self._item_rgb.copy() if self._item_rgb else None,
            BlockSizes=block_sizes^ if block_sizes else None,
            BlockStarts=block_starts^ if block_starts else None,
            NumFields=self._num_fields,
        )


fn _parse_comma_sep_int64_list(span: Span[UInt8, _]) raises -> List[Int64]:
    """Parse comma-separated list of integers (e.g. blockSizes, blockStarts)."""
    var out = List[Int64]()
    var start: Int = 0
    var n = len(span)
    while start < n:
        var end = start
        while end < n and span[end] != UInt8(ord(",")):
            end += 1
        var part = span[start:end]
        if len(part) > 0:
            var s = StringSlice(unsafe_from_utf8=part)
            out.append(Int64(atol(s)))
        start = end + 1
    return out^


# ---------------------------------------------------------------------------
# BedRecord — owned, storeable
# ---------------------------------------------------------------------------

@fieldwise_init
struct BedRecord(Copyable, Movable, Writable):
    """Single BED feature (owned). Coordinates are 0-based, half-open."""

    var Chrom: BString
    var ChromStart: Int64
    var ChromEnd: Int64
    var Name: Optional[BString]
    var Score: Optional[Int]
    var Strand: Optional[Strand]
    var ThickStart: Optional[Int64]
    var ThickEnd: Optional[Int64]
    var ItemRgb: Optional[ItemRgb]
    var BlockSizes: Optional[List[Int64]]
    var BlockStarts: Optional[List[Int64]]
    var NumFields: Int

    @always_inline
    fn chrom(ref[_] self) -> String:
        return self.Chrom.to_string()

    @always_inline
    fn chrom_start(self) -> Int64:
        return self.ChromStart

    @always_inline
    fn chrom_end(self) -> Int64:
        return self.ChromEnd

    @always_inline
    fn name(ref[_] self) -> Optional[String]:
        if not self.Name:
            return None
        return self.Name.value().to_string()

    @always_inline
    fn score(self) -> Optional[Int]:
        return self.Score

    @always_inline
    fn strand(self) -> Optional[Strand]:
        return self.Strand

    @always_inline
    fn thick_start(self) -> Optional[Int64]:
        return self.ThickStart

    @always_inline
    fn thick_end(self) -> Optional[Int64]:
        return self.ThickEnd

    @always_inline
    fn item_rgb(self) -> Optional[ItemRgb]:
        return self.ItemRgb

    fn block_sizes(ref self) -> Optional[List[Int64]]:
        if self.BlockSizes:
            return Optional(self.BlockSizes.value().copy())
        return None

    fn block_starts(ref self) -> Optional[List[Int64]]:
        if self.BlockStarts:
            return Optional(self.BlockStarts.value().copy())
        return None

    @always_inline
    fn num_fields(self) -> Int:
        return self.NumFields

    fn write_to[w: Writer](ref self, mut writer: w):
        """Write this record as one TAB-delimited line (same column count as parsed)."""
        writer.write(self.Chrom.to_string())
        writer.write("\t")
        writer.write(String(self.ChromStart))
        writer.write("\t")
        writer.write(String(self.ChromEnd))
        if self.NumFields >= 4:
            writer.write("\t")
            writer.write(
                self.Name.value().to_string() if self.Name else "."
            )
        if self.NumFields >= 5:
            writer.write("\t")
            writer.write(
                String(self.Score.value()) if self.Score else "0"
            )
        if self.NumFields >= 6:
            var c: String
            if self.Strand:
                if self.Strand.value() == Strand.Plus:
                    c = "+"
                elif self.Strand.value() == Strand.Minus:
                    c = "-"
                else:
                    c = "."
            else:
                c = "."
            writer.write("\t")
            writer.write(c)
        if self.NumFields >= 7:
            writer.write("\t")
            writer.write(
                String(self.ThickStart.value())
                if self.ThickStart
                else String(self.ChromStart)
            )
        if self.NumFields >= 8:
            writer.write("\t")
            writer.write(
                String(self.ThickEnd.value())
                if self.ThickEnd
                else String(self.ChromEnd)
            )
        if self.NumFields >= 9:
            writer.write("\t")
            if self.ItemRgb:
                var rgb = self.ItemRgb.value().copy()
                writer.write(String(rgb.r))
                writer.write(",")
                writer.write(String(rgb.g))
                writer.write(",")
                writer.write(String(rgb.b))
            else:
                writer.write("0")
        if self.NumFields >= 12 and self.BlockSizes and self.BlockStarts:
            writer.write("\t")
            writer.write(String(len(self.BlockSizes.value())))
            writer.write("\t")
            var sizes = self.BlockSizes.value().copy()
            for i in range(len(sizes)):
                if i > 0:
                    writer.write(",")
                writer.write(String(sizes[i]))
            writer.write("\t")
            var starts = self.BlockStarts.value().copy()
            for i in range(len(starts)):
                if i > 0:
                    writer.write(",")
                writer.write(String(starts[i]))
