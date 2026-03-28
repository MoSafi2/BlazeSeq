"""GTF2.2 attribute parsing.

GTF attributes format: tag "value"; tag "value"; ...
gene_id and transcript_id are mandatory in GTF2.2 (empty for inter/inter_CNS).
All other attributes are optional single-value pairs.
"""

from std.collections import List
from std.collections.string import String, StringSlice
from std.memory import Span

from blazeseq.byte_string import BString
from blazeseq.io.writers import Writer


# ---------------------------------------------------------------------------
# GtfAttributes — gene_id + transcript_id as first-class fields
# ---------------------------------------------------------------------------


struct GtfAttributes(Copyable, Movable, Sized, Writable):
    """Parsed GTF column 9 attributes.

    gene_id and transcript_id are mandatory GTF2.2 fields stored directly.
    All other attributes are in _extras as single-value key-value pairs.
    """

    var gene_id: BString
    var transcript_id: BString
    var _extras: List[Tuple[BString, BString]]

    def __init__(out self, var gene_id: BString, var transcript_id: BString):
        self.gene_id = gene_id^
        self.transcript_id = transcript_id^
        self._extras = List[Tuple[BString, BString]]()

    def __init__(out self, *, copy: Self):
        self.gene_id = copy.gene_id.copy()
        self.transcript_id = copy.transcript_id.copy()
        var extras = List[Tuple[BString, BString]]()
        for i in range(len(copy._extras)):
            extras.append((copy._extras[i][0].copy(), copy._extras[i][1].copy()))
        self._extras = extras^

    def get(ref self, key: String) -> Optional[BString]:
        """Return the value for the given attribute key, if any."""
        if key == "gene_id":
            return Optional(self.gene_id.copy())
        if key == "transcript_id":
            return Optional(self.transcript_id.copy())
        for i in range(len(self._extras)):
            if self._extras[i][0].to_string() == key:
                return Optional(self._extras[i][1].copy())
        return None

    def __len__(self) -> Int:
        return 2 + len(self._extras)

    def write_to[w: Writer](ref self, mut writer: w):
        """Emit attributes in GTF format: gene_id "..."; transcript_id "..."; ..."""
        writer.write("gene_id \"")
        writer.write(self.gene_id.to_string())
        writer.write("\"; transcript_id \"")
        writer.write(self.transcript_id.to_string())
        writer.write("\"")
        for i in range(len(self._extras)):
            writer.write("; ")
            writer.write(self._extras[i][0].to_string())
            writer.write(" \"")
            writer.write(self._extras[i][1].to_string())
            writer.write("\"")


# ---------------------------------------------------------------------------
# GTF attributes parser: tag "value"; tag "value"; ...
# ---------------------------------------------------------------------------


def parse_gtf_attributes(span: Span[UInt8, _]) raises -> GtfAttributes:
    """Parse GTF column 9: semicolon-separated 'tag "value"' pairs.

    Extracts gene_id and transcript_id as first-class fields.
    All other attributes go into _extras.
    """
    var gene_id = BString()
    var transcript_id = BString()
    var attrs = GtfAttributes(gene_id^, transcript_id^)
    if len(span) == 0:
        return attrs^
    var start: Int = 0
    var n = len(span)
    while start < n:
        # Skip leading spaces/semicolons
        while start < n and (
            span[start] == UInt8(ord(" ")) or span[start] == UInt8(ord(";"))
        ):
            start += 1
        if start >= n:
            break
        # Find end of this pair (next semicolon or end)
        var end = start
        while end < n and span[end] != UInt8(ord(";")):
            end += 1
        var part = span[start:end]
        start = end + 1
        # part is 'tag "value"' — find first space
        var i: Int = 0
        var part_len = len(part)
        while i < part_len and part[i] != UInt8(ord(" ")):
            i += 1
        if i >= part_len:
            continue
        var key_span = part[0:i]
        # Skip space, expect quote
        i += 1
        if i < part_len and part[i] == UInt8(ord("\"")):
            i += 1
            var value_start = i
            while i < part_len and part[i] != UInt8(ord("\"")):
                i += 1
            var value_span = part[value_start:i]
            var key_str = StringSlice(unsafe_from_utf8=key_span)
            if String(key_str) == "gene_id":
                attrs.gene_id = BString(value_span)
            elif String(key_str) == "transcript_id":
                attrs.transcript_id = BString(value_span)
            else:
                attrs._extras.append((BString(key_span), BString(value_span)))
    return attrs^
