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
    """Strand of a GFF feature: Plus (+), Minus (-), Unstranded (.), or Unknown (?)."""

    var value: Int8

    @always_inline
    fn __init__(out self, value: Int8):
        self.value = value

    comptime Plus = Self(0)
    comptime Minus = Self(1)
    comptime Unstranded = Self(2)  # "." — no strand concept
    comptime Unknown = Self(3)     # "?" — strand unknown (GFF3)

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
# SequenceRegion — from ##sequence-region directive
# ---------------------------------------------------------------------------


struct SequenceRegion(Copyable, Movable):
    """Sequence boundary declared by a ##sequence-region directive.

    ##sequence-region seqid start end
    Coordinates are 1-based inclusive, same as GFF feature coordinates.
    """

    var seqid: BString
    var region: Interval  # 1-based closed [start, end]

    def __init__(out self, var seqid: BString, region: Interval):
        self.seqid = seqid^
        self.region = region

    fn __init__(out self, *, copy: Self):
        self.seqid = copy.seqid.copy()
        self.region = copy.region


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

    fn get_all_attributes(ref self, key: String) -> List[BString]:
        """Return all values for key (for multi-value GFF3 attributes like Parent)."""
        return self.Attributes.get_all(key)

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
        writer.write("\n")


# ---------------------------------------------------------------------------
# TargetAttribute — structured form of the GFF3 Target attribute value
# ---------------------------------------------------------------------------


struct TargetAttribute(Copyable, Movable):
    """Structured form of a GFF3 Target attribute value.

    Format: target_id start end [strand]
    Coordinates are 1-based. strand is optional (+/-).
    """

    var target_id: BString
    var start: UInt64
    var end: UInt64
    var strand: Optional[GffStrand]

    def __init__(
        out self,
        var target_id: BString,
        start: UInt64,
        end: UInt64,
        strand: Optional[GffStrand],
    ):
        self.target_id = target_id^
        self.start = start
        self.end = end
        self.strand = strand

    fn __init__(out self, *, copy: Self):
        self.target_id = copy.target_id.copy()
        self.start = copy.start
        self.end = copy.end
        self.strand = copy.strand


fn _parse_uint64_from_bstring(s: BString) raises -> UInt64:
    """Parse a BString as a decimal UInt64."""
    var result: UInt64 = 0
    var n = len(s)
    if n == 0:
        raise Error("Target: empty integer field")
    for i in range(n):
        var digit = s[i] - 48
        if digit > 9:
            raise Error("Target: invalid integer digit")
        result = result * 10 + digit.cast[DType.uint64]()
    return result


fn parse_target_attribute(value: BString) raises -> TargetAttribute:
    """Parse a GFF3 Target attribute value: 'target_id start end [strand]'.

    Coordinates are 1-based. Strand (+ or -) is optional.
    """
    # Collect space-delimited tokens
    var tokens = List[BString]()
    var span = value.as_span()
    var n = len(span)
    var i: Int = 0
    while i < n:
        while i < n and span[i] == UInt8(ord(" ")):
            i += 1
        if i >= n:
            break
        var j = i
        while j < n and span[j] != UInt8(ord(" ")):
            j += 1
        tokens.append(BString(span[i:j]))
        i = j + 1
    if len(tokens) < 3:
        raise Error("GFF3 Target: expected 'target_id start end [strand]', got fewer fields")
    var target_id = tokens[0].copy()
    var start = _parse_uint64_from_bstring(tokens[1])
    var end = _parse_uint64_from_bstring(tokens[2])
    var strand: Optional[GffStrand] = None
    if len(tokens) >= 4:
        var s_span = tokens[3].as_span()
        if len(s_span) == 1:
            if s_span[0] == UInt8(ord("+")):
                strand = Optional(GffStrand.Plus)
            elif s_span[0] == UInt8(ord("-")):
                strand = Optional(GffStrand.Minus)
            else:
                raise Error("GFF3 Target: strand must be + or -")
        else:
            raise Error("GFF3 Target: strand must be a single character + or -")
    if start > end:
        raise Error("GFF3 Target: start must be <= end")
    return TargetAttribute(target_id=target_id^, start=start, end=end, strand=strand)
