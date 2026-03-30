"""GTF2.2 attribute parsing.

GTF attributes format: tag "value"; tag "value"; ...
gene_id and transcript_id are mandatory in GTF2.2 (empty for inter/inter_CNS).
All other attributes are optional single-value pairs. Quoted values support
backslash escapes (\" \\ \n \t \r). Unquoted values are also accepted.
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
    Duplicate keys in _extras are preserved; use get_all() to retrieve all.
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
            extras.append(
                (copy._extras[i][0].copy(), copy._extras[i][1].copy())
            )
        self._extras = extras^

    def get(ref self, key: String) -> Optional[BString]:
        """Return the first value for the given attribute key, if any."""
        if key == "gene_id":
            return Optional(self.gene_id.copy())
        if key == "transcript_id":
            return Optional(self.transcript_id.copy())
        for i in range(len(self._extras)):
            if self._extras[i][0].as_string_slice() == key:
                return Optional(self._extras[i][1].copy())
        return None

    def get_all(ref self, key: String) -> List[BString]:
        """Return all values for key in encounter order (supports duplicate keys).
        """
        var out = List[BString]()
        if key == "gene_id":
            out.append(self.gene_id.copy())
            return out^
        if key == "transcript_id":
            out.append(self.transcript_id.copy())
            return out^
        for i in range(len(self._extras)):
            if self._extras[i][0].as_string_slice() == key:
                out.append(self._extras[i][1].copy())
        return out^

    def __len__(self) -> Int:
        """Return count of non-empty attributes (gene_id, transcript_id, and extras).
        """
        var count = len(self._extras)
        if len(self.gene_id) > 0:
            count += 1
        if len(self.transcript_id) > 0:
            count += 1
        return count

    def write_to[w: Writer](ref self, mut writer: w):
        """Emit attributes in GTF format: gene_id "..."; transcript_id "..."; ...
        """
        writer.write('gene_id "')
        _write_gtf_escaped(self.gene_id, writer)
        writer.write('"; transcript_id "')
        _write_gtf_escaped(self.transcript_id, writer)
        writer.write('"')
        for i in range(len(self._extras)):
            writer.write("; ")
            writer.write(self._extras[i][0].to_string())
            writer.write(' "')
            _write_gtf_escaped(self._extras[i][1], writer)
            writer.write('"')


# ---------------------------------------------------------------------------
# Key comparison helper — avoids BString.to_string() allocation
# ---------------------------------------------------------------------------


@always_inline


# ---------------------------------------------------------------------------
# GTF value unescaping — Issue 5
# ---------------------------------------------------------------------------


def _gtf_unescape_value(span: Span[UInt8, _]) -> BString:
    """Decode GTF backslash escape sequences in a value span.

    Recognised sequences: \\" → ", \\\\ → \\, \\n → newline, \\t → tab, \\r → CR.
    Unknown sequences emit both the backslash and the following byte literally.
    """
    var bytes = List[UInt8]()
    var i: Int = 0
    var n = len(span)
    while i < n:
        var b = span[i]
        if b == UInt8(92):  # backslash
            if i + 1 < n:
                var next = span[i + 1]
                if next == UInt8(34):  # \"  → "
                    bytes.append(UInt8(34))
                elif next == UInt8(92):  # \\ → backslash
                    bytes.append(UInt8(92))
                elif next == UInt8(110):  # \n → newline
                    bytes.append(UInt8(10))
                elif next == UInt8(116):  # \t → tab
                    bytes.append(UInt8(9))
                elif next == UInt8(114):  # \r → carriage return
                    bytes.append(UInt8(13))
                else:  # unknown — emit both bytes literally
                    bytes.append(UInt8(92))
                    bytes.append(next)
                i += 2
            else:
                # Trailing backslash — emit literally
                bytes.append(UInt8(92))
                i += 1
        else:
            bytes.append(b)
            i += 1
    return BString(Span(bytes))


# ---------------------------------------------------------------------------
# GTF value escaping (inverse of _gtf_unescape_value) — for write_to
# ---------------------------------------------------------------------------


def _write_gtf_escaped[w: Writer](value: BString, mut writer: w):
    """Write a GTF attribute value with backslash escaping applied.

    Buffers unescaped runs and emits them as single StringSlice writes,
    so the only per-character overhead is for bytes that need escaping.
    """
    var span = value.as_span()
    var n = len(span)
    var run_start = 0
    for i in range(n):
        var b = span[i]
        var needs_escape = (
            b == UInt8(34)  # "
            or b == UInt8(92)  # \
            or b == UInt8(10)  # newline
            or b == UInt8(9)  # tab
            or b == UInt8(13)  # CR
        )
        if needs_escape:
            if i > run_start:
                writer.write(StringSlice(unsafe_from_utf8=span[run_start:i]))
            if b == UInt8(34):
                writer.write('\\"')
            elif b == UInt8(92):
                writer.write("\\\\")
            elif b == UInt8(10):
                writer.write("\\n")
            elif b == UInt8(9):
                writer.write("\\t")
            else:
                writer.write("\\r")
            run_start = i + 1
    if run_start < n:
        writer.write(StringSlice(unsafe_from_utf8=span[run_start:n]))


# ---------------------------------------------------------------------------
# GTF attributes parser: tag "value"; tag "value"; ...
# ---------------------------------------------------------------------------


def parse_gtf_attributes(span: Span[UInt8, _]) raises -> GtfAttributes:
    """Parse GTF column 9: semicolon-separated 'tag "value"' pairs.

    Extracts gene_id and transcript_id as first-class fields.
    All other attributes go into _extras. Supports:
    - Quoted values with backslash escapes (Issue 5)
    - Unquoted values such as exon_number 3 (Issue 3)
    - Duplicate keys (all values stored; use get_all() to retrieve them)
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
        # Find end of this pair (next semicolon not inside quotes, or end)
        var end = start
        var in_quote = False
        while end < n:
            var b = span[end]
            if b == UInt8(92) and in_quote and end + 1 < n:  # backslash escape
                end += 2
                continue
            if b == UInt8(ord('"')):
                in_quote = not in_quote
            if b == UInt8(ord(";")) and not in_quote:
                break
            end += 1
        var part = span[start:end]
        start = end + 1
        # part is 'tag "value"' or 'tag value' — find first space
        var i: Int = 0
        var part_len = len(part)
        while i < part_len and part[i] != UInt8(ord(" ")):
            i += 1
        if i >= part_len:
            continue
        var key_span = part[0:i]
        # Skip space
        i += 1
        var value: BString
        if i < part_len and part[i] == UInt8(ord('"')):
            # Quoted value — scan to closing quote, honouring backslash escapes
            i += 1
            var value_start = i
            while i < part_len:
                var b = part[i]
                if b == UInt8(92) and i + 1 < part_len:  # backslash — skip pair
                    i += 2
                    continue
                if b == UInt8(ord('"')):
                    break
                i += 1
            value = _gtf_unescape_value(part[value_start:i])
        else:
            # Unquoted value — take remaining bytes, trim trailing whitespace
            var v_end = part_len
            while v_end > i and (
                part[v_end - 1] == UInt8(ord(" "))
                or part[v_end - 1] == UInt8(13)  # \r
                or part[v_end - 1] == UInt8(10)  # \n
                or part[v_end - 1] == UInt8(9)  # \t
            ):
                v_end -= 1
            if v_end <= i:
                continue  # empty value — skip
            value = _gtf_unescape_value(part[i:v_end])
        # A7: Compare key bytes directly to avoid String allocation
        if len(key_span) == 7 and _span_eq_literal(key_span, "gene_id"):
            attrs.gene_id = value^
        elif len(key_span) == 13 and _span_eq_literal(
            key_span, "transcript_id"
        ):
            attrs.transcript_id = value^
        else:
            attrs._extras.append((BString(key_span), value^))
    return attrs^


@always_inline
def _span_eq_literal(span: Span[UInt8, _], lit: StringLiteral) -> Bool:
    """True if span bytes equal the literal (caller must pre-check length)."""
    var s = StringSlice(lit)
    var b = s.as_bytes()
    for i in range(len(b)):
        if span[i] != b[i]:
            return False
    return True
