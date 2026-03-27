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
from blazeseq.features import Position, Interval


# ---------------------------------------------------------------------------
# Strand
# ---------------------------------------------------------------------------


struct Strand(Copyable, Equatable, TrivialRegisterPassable, Writable):
    """Strand of a BED feature: Plus (+), Minus (-), or Unknown (.)."""

    var value: Int8

    @always_inline
    def __init__(out self, value: Int8):
        self.value = value

    comptime Plus = Self(0)
    comptime Minus = Self(1)
    comptime Unknown = Self(2)

    @always_inline
    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def write_to[w: Writer](self, mut writer: w):
        if self.value == 0:
            writer.write("+")
        elif self.value == 1:
            writer.write("-")
        else:
            writer.write(".")


# ---------------------------------------------------------------------------
# ItemRgb — display color (0 or r,g,b each 0-255)
# ---------------------------------------------------------------------------


struct ItemRgb(Copyable, Movable, TrivialRegisterPassable, Writable):
    """BED itemRgb: either black (0) or (r,g,b) each 0-255."""

    var r: UInt8
    var g: UInt8
    var b: UInt8

    @always_inline
    def __init__(out self, r: UInt8, g: UInt8, b: UInt8):
        self.r = r
        self.g = g
        self.b = b

    @always_inline
    def is_black(self) -> Bool:
        """True if 0,0,0 (or the single 0 value)."""
        return self.r == 0 and self.g == 0 and self.b == 0

    def write_to[w: Writer](self, mut writer: w):
        writer.write(String(self.r))
        writer.write(",")
        writer.write(String(self.g))
        writer.write(",")
        writer.write(String(self.b))


def position_try_from(value: UInt64) -> Optional[Position]:
    """Create a Position if value >= 1 (1-based), else None (aligned with noodles_core).
    """
    if value < 1:
        return None
    return Optional(Position(value, True))


def interval_try_from_start_end(
    start: UInt64, end: UInt64
) -> Optional[Interval]:
    """Build an Interval from 1-based start and end (closed [start, end]) if valid.
    """
    if start < 1 or end < 1 or start > end:
        return None
    return Optional(Interval(Position(start, True), Position(end, True), True))


# ---------------------------------------------------------------------------
# BedView — zero-alloc, NOT to be stored
# ---------------------------------------------------------------------------


struct BedView[O: Origin](Movable):
    """Zero-copy view over one BED data line in the parser's buffer.

    Lifetime: Valid only until the next parser read. Do not store;
    call `.to_record()` when the record must outlive the current iteration.

    Coordinates are 0-based, half-open [chrom_start, chrom_end).
    """

    var _chrom: Span[UInt8, Self.O]
    var chrom_start: UInt64
    var chrom_end: UInt64
    var _name: Optional[Span[UInt8, Self.O]]
    var score: Optional[Int]
    var strand: Optional[Strand]
    var thick_start: Optional[UInt64]
    var thick_end: Optional[UInt64]
    var _item_rgb: Optional[ItemRgb]
    var block_count: Optional[Int]
    var _block_sizes_span: Optional[Span[UInt8, Self.O]]
    var _block_starts_span: Optional[Span[UInt8, Self.O]]
    var num_fields: Int

    def __init__(
        out self,
        _chrom: Span[UInt8, Self.O],
        chrom_start: UInt64,
        chrom_end: UInt64,
        _name: Optional[Span[UInt8, Self.O]],
        score: Optional[Int],
        strand: Optional[Strand],
        thick_start: Optional[UInt64],
        thick_end: Optional[UInt64],
        _item_rgb: Optional[ItemRgb],
        block_count: Optional[Int],
        _block_sizes_span: Optional[Span[UInt8, Self.O]],
        _block_starts_span: Optional[Span[UInt8, Self.O]],
        num_fields: Int,
    ):
        self._chrom = _chrom
        self.chrom_start = chrom_start
        self.chrom_end = chrom_end
        self._name = _name
        self.score = score
        self.strand = strand
        self.thick_start = thick_start
        self.thick_end = thick_end
        self._item_rgb = _item_rgb
        self.block_count = block_count
        self._block_sizes_span = _block_sizes_span
        self._block_starts_span = _block_starts_span
        self.num_fields = num_fields

    @always_inline
    def chrom(self) -> StringSlice[origin=Self.O]:
        return StringSlice[origin=Self.O](unsafe_from_utf8=self._chrom)

    def start_position(self) -> Position:
        """1-based start of the feature (aligned with noodles_core; BED chromStart → start+1).
        """
        return Position(self.chrom_start + 1, True)

    def end_position(self) -> Optional[Position]:
        """1-based end position (chromEnd). None for zero-length BED records (chromEnd == 0)."""
        if self.chrom_end == 0:
            return None
        return Optional(Position(self.chrom_end, True))

    def interval(self) -> Optional[Interval]:
        """Feature extent as 1-based closed [chromStart+1, chromEnd].
        Returns None for zero-length BED records (chromEnd == 0).
        BED 0-based half-open [s, e) → 1-based closed [s+1, e].
        """
        if self.chrom_end == 0:
            return None
        return Optional(Interval(
            Position(self.chrom_start + 1, True),
            Position(self.chrom_end, True),
            True,
        ))

    def thick_interval(self) -> Optional[Interval]:
        """Thick (coding) extent if fields 7–8 present; else None (1-based closed).
        """
        if not self.thick_start or not self.thick_end:
            return None
        var opt = interval_try_from_start_end(
            self.thick_start.value() + 1, self.thick_end.value()
        )
        if not opt:
            return None
        return Optional(opt.value())

    @always_inline
    def name(self) -> Optional[StringSlice[origin=Self.O]]:
        if not self._name:
            return None
        return StringSlice[origin=Self.O](unsafe_from_utf8=self._name.value())

    def item_rgb(self) -> Optional[ItemRgb]:
        if not self._item_rgb:
            return None
        return Optional(self._item_rgb.value().copy())

    def to_record(self) raises -> BedRecord:
        """Materialize an owned BedRecord. Call when the record must outlive the view.
        """
        var block_sizes: Optional[List[UInt64]] = None
        var block_starts: Optional[List[UInt64]] = None
        if self._block_sizes_span and self._block_starts_span and self.block_count:
            var bc = self.block_count.value()
            var sizes = _parse_comma_sep_int64_list(self._block_sizes_span.value())
            var starts = _parse_comma_sep_int64_list(self._block_starts_span.value())
            if len(sizes) != bc or len(starts) != bc:
                raise Error("BED: blockSizes/blockStarts length != blockCount")
            if starts[0] != 0:
                raise Error("BED: blockStarts[0] must be 0 (first block at chromStart)")
            if self.chrom_start + starts[bc - 1] + sizes[bc - 1] != self.chrom_end:
                raise Error("BED: last block must end at chromEnd")
            block_sizes = sizes^
            block_starts = starts^
        elif self._block_sizes_span and self._block_starts_span:
            block_sizes = _parse_comma_sep_int64_list(self._block_sizes_span.value())
            block_starts = _parse_comma_sep_int64_list(self._block_starts_span.value())
        var name_opt: Optional[BString] = None
        if self._name:
            name_opt = BString(self._name.value())
        return BedRecord(
            Chrom=BString(self._chrom),
            ChromStart=self.chrom_start,
            ChromEnd=self.chrom_end,
            Name=name_opt^ if name_opt else None,
            Score=self.score,
            Strand=self.strand,
            ThickStart=self.thick_start,
            ThickEnd=self.thick_end,
            ItemRgb=self._item_rgb,
            BlockSizes=block_sizes^ if block_sizes else None,
            BlockStarts=block_starts^ if block_starts else None,
            NumFields=self.num_fields,
        )


def _parse_comma_sep_int64_list(span: Span[UInt8, _]) raises -> List[UInt64]:
    """Parse comma-separated list of integers (e.g. blockSizes, blockStarts)."""
    var out = List[UInt64]()
    var start: Int = 0
    var n = len(span)
    while start < n:
        var end = start
        while end < n and span[end] != UInt8(ord(",")):
            end += 1
        var part = span[start:end]
        if len(part) > 0:
            var s = StringSlice(unsafe_from_utf8=part)
            out.append(UInt64(atol(s)))
        start = end + 1
    return out^


def _strand_to_char(strand: Optional[Strand]) -> String:
    """Format strand as BED character: +, -, or ."""
    if not strand:
        return "."
    if strand.value() == Strand.Plus:
        return "+"
    if strand.value() == Strand.Minus:
        return "-"
    return "."


def _comma_sep_u64_list(values: List[UInt64]) -> String:
    """Format list of UInt64 as comma-separated string."""
    var out = String()
    for i in range(len(values)):
        if i > 0:
            out += ","
        out += String(values[i])
    return out^


# ---------------------------------------------------------------------------
# BedRecord — owned, storeable
# ---------------------------------------------------------------------------


@fieldwise_init
struct BedRecord(Copyable, Movable, Writable):
    """Single BED feature (owned). Coordinates are 0-based, half-open."""

    var Chrom: BString
    var ChromStart: UInt64
    var ChromEnd: UInt64
    var Name: Optional[BString]
    var Score: Optional[Int]
    var Strand: Optional[Strand]
    var ThickStart: Optional[UInt64]
    var ThickEnd: Optional[UInt64]
    var ItemRgb: Optional[ItemRgb]
    var BlockSizes: Optional[List[UInt64]]
    var BlockStarts: Optional[List[UInt64]]
    var NumFields: Int

    @always_inline
    def chrom(ref[_] self) -> String:
        return self.Chrom.to_string()

    def start_position(self) -> Position:
        """1-based start of the feature (aligned with noodles_core; BED chromStart → start+1).
        """
        return Position(self.ChromStart + 1, True)

    def end_position(self) -> Optional[Position]:
        """1-based end position (ChromEnd). None for zero-length BED records (ChromEnd == 0)."""
        if self.ChromEnd == 0:
            return None
        return Optional(Position(self.ChromEnd, True))

    def interval(self) -> Optional[Interval]:
        """Feature extent as 1-based closed [ChromStart+1, ChromEnd].
        Returns None for zero-length BED records (ChromEnd == 0).
        BED 0-based half-open [s, e) → 1-based closed [s+1, e].
        """
        if self.ChromEnd == 0:
            return None
        return Optional(Interval(
            Position(self.ChromStart + 1, True),
            Position(self.ChromEnd, True),
            True,
        ))

    def thick_interval(ref self) -> Optional[Interval]:
        """Thick (coding) extent if fields 7–8 present; else None (1-based closed).
        """
        if not self.ThickStart or not self.ThickEnd:
            return None
        var opt = interval_try_from_start_end(
            self.ThickStart.value() + 1, self.ThickEnd.value()
        )
        if not opt:
            return None
        return Optional(opt.value())

    @always_inline
    def name(ref[_] self) -> Optional[String]:
        if not self.Name:
            return None
        return self.Name.value().to_string()

    def item_rgb(ref self) -> Optional[ItemRgb]:
        if not self.ItemRgb:
            return None
        return Optional(self.ItemRgb.value().copy())

    def block_sizes(ref self) -> Optional[List[UInt64]]:
        if self.BlockSizes:
            return Optional(self.BlockSizes.value().copy())
        return None

    def block_starts(ref self) -> Optional[List[UInt64]]:
        if self.BlockStarts:
            return Optional(self.BlockStarts.value().copy())
        return None

    def write_to[w: Writer](ref self, mut writer: w):
        """Write this record as one TAB-delimited line (same column count as parsed).
        """
        self._write_core_fields(writer)
        self._write_name_field(writer)
        self._write_score_field(writer)
        self._write_strand_field(writer)
        self._write_thick_fields(writer)
        self._write_item_rgb_field(writer)
        self._write_block_fields(writer)
        writer.write("\n")

    def _write_core_fields[w: Writer](ref self, mut writer: w):
        writer.write(
            t"{self.Chrom.to_string()}\t{String(self.ChromStart)}\t{String(self.ChromEnd)}"
        )

    def _write_name_field[w: Writer](ref self, mut writer: w):
        if self.NumFields < 4:
            return
        var name_str = self.Name.value().to_string() if self.Name else "."
        writer.write(t"\t{name_str}")

    def _write_score_field[w: Writer](ref self, mut writer: w):
        if self.NumFields < 5:
            return
        var score_str = String(self.Score.value()) if self.Score else "0"
        writer.write(t"\t{score_str}")

    def _write_strand_field[w: Writer](ref self, mut writer: w):
        if self.NumFields < 6:
            return
        var c = _strand_to_char(self.Strand)
        writer.write(t"\t{c}")

    def _write_thick_fields[w: Writer](ref self, mut writer: w):
        if self.NumFields >= 7:
            var thick_start_str = String(
                self.ThickStart.value()
            ) if self.ThickStart else String(self.ChromStart)
            writer.write(t"\t{thick_start_str}")
        if self.NumFields >= 8:
            var thick_end_str = String(
                self.ThickEnd.value()
            ) if self.ThickEnd else String(self.ChromEnd)
            writer.write(t"\t{thick_end_str}")

    def _write_item_rgb_field[w: Writer](ref self, mut writer: w):
        if self.NumFields < 9:
            return
        if self.ItemRgb:
            var rgb = self.ItemRgb.value().copy()
            writer.write(t"\t{String(rgb.r)},{String(rgb.g)},{String(rgb.b)}")
        else:
            writer.write("\t0")

    def _write_block_fields[w: Writer](ref self, mut writer: w):
        if self.NumFields < 12 or not self.BlockSizes or not self.BlockStarts:
            return
        var sizes = self.BlockSizes.value().copy()
        var starts = self.BlockStarts.value().copy()
        writer.write(t"\t{String(len(sizes))}")
        writer.write(t"\t{_comma_sep_u64_list(sizes)}")
        writer.write(t"\t{_comma_sep_u64_list(starts)}")
