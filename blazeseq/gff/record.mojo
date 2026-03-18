"""GFF/GTF/GFF3 record types.

All three formats share 9 tab-delimited columns: seqid, source, type, start, end,
score, strand, phase, attributes. Coordinates are 1-based inclusive.
"""

from std.collections import List
from std.collections.string import String, StringSlice
from std.memory import Span

from blazeseq.byte_string import BString
from blazeseq.io.writers import Writer
from blazeseq.features import Position, Interval
from blazeseq.gff.attributes import (
    GffAttributes,
    parse_gtf_attributes,
    parse_gff3_attributes,
)


# ---------------------------------------------------------------------------
# GffStrand — +, -, ., or ? (GFF3)
# ---------------------------------------------------------------------------


struct GffStrand(Copyable, Equatable, TrivialRegisterPassable, Writable):
    """Strand of a GFF feature: Plus (+), Minus (-), Unknown (.), or Unstranded (?)."""

    var value: Int8

    @always_inline
    fn __init__(out self, value: Int8):
        self.value = value

    comptime Plus = Self(0)
    comptime Minus = Self(1)
    comptime Unknown = Self(2)
    comptime Unstranded = Self(3)  # GFF3 "?"

    @always_inline
    fn __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    fn write_to[w: Writer](self, mut writer: w):
        if self.value == 0:
            writer.write("+")
        elif self.value == 1:
            writer.write("-")
        elif self.value == 2:
            writer.write(".")
        else:
            writer.write("?")


# ---------------------------------------------------------------------------
# GffView — zero-alloc, NOT to be stored
# ---------------------------------------------------------------------------


struct GffView[O: Origin](Movable):
    """Zero-copy view over one GFF/GTF/GFF3 data line.

    Lifetime: valid only until the next parser read. Call `.to_record()` to own.
    Coordinates are 1-based inclusive. _format_gtf: True for GTF, False for GFF3.
    """

    var _seqid: Span[UInt8, Self.O]
    var _source: Span[UInt8, Self.O]
    var _type: Span[UInt8, Self.O]
    var start: UInt64
    var end: UInt64
    var score: Optional[Float64]
    var strand: Optional[GffStrand]
    var phase: Optional[UInt8]
    var _attributes: Span[UInt8, Self.O]
    var _format_gtf: Bool

    fn __init__(
        out self,
        _seqid: Span[UInt8, Self.O],
        _source: Span[UInt8, Self.O],
        _type: Span[UInt8, Self.O],
        start: UInt64,
        end: UInt64,
        score: Optional[Float64],
        strand: Optional[GffStrand],
        phase: Optional[UInt8],
        _attributes: Span[UInt8, Self.O],
        _format_gtf: Bool,
    ):
        self._seqid = _seqid
        self._source = _source
        self._type = _type
        self.start = start
        self.end = end
        self.score = score
        self.strand = strand
        self.phase = phase
        self._attributes = _attributes
        self._format_gtf = _format_gtf

    @always_inline
    fn seqid(self) -> StringSlice[origin=Self.O]:
        return StringSlice[origin=Self.O](unsafe_from_utf8=self._seqid)

    @always_inline
    fn source(self) -> StringSlice[origin=Self.O]:
        return StringSlice[origin=Self.O](unsafe_from_utf8=self._source)

    @always_inline
    fn feature_type(self) -> StringSlice[origin=Self.O]:
        return StringSlice[origin=Self.O](unsafe_from_utf8=self._type)

    @always_inline
    fn attributes_span(self) -> Span[UInt8, Self.O]:
        return self._attributes

    fn start_position(self) -> Position:
        return Position(self.start, True)

    fn end_position(self) -> Position:
        return Position(self.end, True)

    fn interval(self) -> Interval:
        return Interval(
            Position(self.start, True),
            Position(self.end, True),
            True,
        )

    fn to_record(self) raises -> GffRecord:
        """Materialize an owned GffRecord by parsing attributes from column 9."""
        var attrs: GffAttributes
        if self._format_gtf:
            attrs = parse_gtf_attributes(self._attributes)
        else:
            attrs = parse_gff3_attributes(self._attributes)
        return GffRecord(
            Seqid=BString(self._seqid),
            Source=BString(self._source),
            Type=BString(self._type),
            Start=self.start,
            End=self.end,
            Score=self.score,
            Strand=self.strand,
            Phase=self.phase,
            Attributes=attrs^,
        )


# ---------------------------------------------------------------------------
# GffRecord — owned, storeable
# ---------------------------------------------------------------------------


@fieldwise_init
struct GffRecord(Copyable, Movable, Writable):
    """Single GFF/GTF/GFF3 feature (owned). Coordinates 1-based inclusive."""

    var Seqid: BString
    var Source: BString
    var Type: BString
    var Start: UInt64
    var End: UInt64
    var Score: Optional[Float64]
    var Strand: Optional[GffStrand]
    var Phase: Optional[UInt8]
    var Attributes: GffAttributes

    @always_inline
    fn seqid(ref self) -> String:
        return self.Seqid.to_string()

    @always_inline
    fn source(ref self) -> String:
        return self.Source.to_string()

    @always_inline
    fn feature_type(ref self) -> String:
        return self.Type.to_string()

    fn start_position(self) -> Position:
        return Position(self.Start, True)

    fn end_position(self) -> Position:
        return Position(self.End, True)

    fn interval(self) -> Interval:
        return Interval(
            Position(self.Start, True),
            Position(self.End, True),
            True,
        )

    fn get_attribute(ref self, key: String) -> Optional[BString]:
        return self.Attributes.get(key)

    fn write_to[w: Writer](ref self, mut writer: w, format_gtf: Bool = False):
        """Write one tab-delimited line. format_gtf: True = GTF attribute style."""
        writer.write(self.Seqid.to_string())
        writer.write("\t")
        writer.write(self.Source.to_string())
        writer.write("\t")
        writer.write(self.Type.to_string())
        writer.write("\t")
        writer.write(String(self.Start))
        writer.write("\t")
        writer.write(String(self.End))
        writer.write("\t")
        if self.Score:
            writer.write(String(self.Score.value()))
        else:
            writer.write(".")
        writer.write("\t")
        if self.Strand:
            self.Strand.value().write_to(writer)
        else:
            writer.write(".")
        writer.write("\t")
        if self.Phase:
            writer.write(String(self.Phase.value()))
        else:
            writer.write(".")
        writer.write("\t")
        self.Attributes.write_to(writer, format_gtf=format_gtf)
