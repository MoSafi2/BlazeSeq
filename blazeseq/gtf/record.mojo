"""GTF2.2 record types.

GTF (Gene Transfer Format) uses 9 tab-delimited columns with attribute format:
  gene_id "value"; transcript_id "value"; ...
Coordinates are 1-based inclusive. Mandatory attributes: gene_id, transcript_id.
"""

from std.collections import List
from std.collections.string import String, StringSlice
from std.memory import Span

from blazeseq.byte_string import BString
from blazeseq.io.writers import Writer
from blazeseq.features import Position, Interval
from blazeseq.gtf.attributes import GtfAttributes, parse_gtf_attributes


# ---------------------------------------------------------------------------
# GtfStrand — +, -, or .
# ---------------------------------------------------------------------------


struct GtfStrand(Copyable, Equatable, TrivialRegisterPassable, Writable):
    """Strand of a GTF feature: Plus (+), Minus (-), or Unstranded (.).

    GTF2.2 specification allows + or - only, but . is used in practice
    for features without a defined strand.
    """

    var value: Int8

    @always_inline
    def __init__(out self, value: Int8):
        self.value = value

    comptime Plus       = Self(0)
    comptime Minus      = Self(1)
    comptime Unstranded = Self(2)  # "." — used in practice for unstranded features

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
# GtfView — zero-alloc, NOT to be stored
# ---------------------------------------------------------------------------


struct GtfView[O: Origin](Movable):
    """Zero-copy view over one GTF data line.

    Lifetime: Valid only until the next parser read. Do not store;
    call `.to_record()` when the record must outlive the current iteration.
    Coordinates are 1-based inclusive.
    """

    var _seqid: Span[UInt8, Self.O]
    var _source: Span[UInt8, Self.O]
    var _type: Span[UInt8, Self.O]
    var start: UInt64
    var end: UInt64
    var score: Optional[Float64]
    var strand: Optional[GtfStrand]
    var phase: Optional[UInt8]
    var _attributes: Span[UInt8, Self.O]

    def __init__(
        out self,
        _seqid: Span[UInt8, Self.O],
        _source: Span[UInt8, Self.O],
        _type: Span[UInt8, Self.O],
        start: UInt64,
        end: UInt64,
        score: Optional[Float64],
        strand: Optional[GtfStrand],
        phase: Optional[UInt8],
        _attributes: Span[UInt8, Self.O],
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

    @always_inline
    def seqid(self) -> StringSlice[origin=Self.O]:
        return StringSlice[origin=Self.O](unsafe_from_utf8=self._seqid)

    @always_inline
    def source(self) -> StringSlice[origin=Self.O]:
        return StringSlice[origin=Self.O](unsafe_from_utf8=self._source)

    @always_inline
    def feature_type(self) -> StringSlice[origin=Self.O]:
        return StringSlice[origin=Self.O](unsafe_from_utf8=self._type)

    @always_inline
    def attributes_span(self) -> Span[UInt8, Self.O]:
        return self._attributes

    def start_position(self) -> Position:
        return Position(self.start, True)

    def end_position(self) -> Position:
        return Position(self.end, True)

    def interval(self) -> Interval:
        return Interval(
            Position(self.start, True),
            Position(self.end, True),
            True,
        )

    def to_record(self) raises -> GtfRecord:
        """Materialize an owned GtfRecord by parsing attributes from column 9."""
        return GtfRecord(
            Seqid=BString(self._seqid),
            Source=BString(self._source),
            Type=BString(self._type),
            Start=self.start,
            End=self.end,
            Score=self.score,
            Strand=self.strand,
            Phase=self.phase,
            Attributes=parse_gtf_attributes(self._attributes),
        )


# ---------------------------------------------------------------------------
# GtfRecord — owned, storeable
# ---------------------------------------------------------------------------


@fieldwise_init
struct GtfRecord(Copyable, Movable, Writable):
    """Single GTF2.2 feature (owned). Coordinates 1-based inclusive."""

    var Seqid: BString
    var Source: BString
    var Type: BString
    var Start: UInt64
    var End: UInt64
    var Score: Optional[Float64]
    var Strand: Optional[GtfStrand]
    var Phase: Optional[UInt8]
    var Attributes: GtfAttributes

    @always_inline
    def seqid(ref self) -> String:
        return self.Seqid.to_string()

    @always_inline
    def source(ref self) -> String:
        return self.Source.to_string()

    @always_inline
    def feature_type(ref self) -> String:
        return self.Type.to_string()

    def start_position(self) -> Position:
        return Position(self.Start, True)

    def end_position(self) -> Position:
        return Position(self.End, True)

    def interval(self) -> Interval:
        return Interval(
            Position(self.Start, True),
            Position(self.End, True),
            True,
        )

    def get_attribute(ref self, key: String) -> Optional[BString]:
        return self.Attributes.get(key)

    def write_to[w: Writer](ref self, mut writer: w):
        """Write one tab-delimited GTF line."""
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
        self.Attributes.write_to(writer)
        writer.write("\n")
