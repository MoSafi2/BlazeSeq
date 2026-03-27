"""GFF/GTF/GFF3 attribute parsing and GFF3 percent-encoding."""

from std.collections import List
from std.collections.string import String, StringSlice
from std.memory import Span

from blazeseq.byte_string import BString
from blazeseq.io.writers import Writer


# ---------------------------------------------------------------------------
# GffAttributes — key -> list of values (supports GFF3 multi-value)
# ---------------------------------------------------------------------------


struct GffAttributes(Copyable, Movable, Sized, Writable):
    """Parsed attributes: list of (key, list of values)."""

    var _pairs: List[Tuple[BString, List[BString]]]

    fn __init__(out self):
        self._pairs = List[Tuple[BString, List[BString]]]()

    fn __init__(out self, *, copy: Self):
        var new_pairs = List[Tuple[BString, List[BString]]]()
        for i in range(len(copy._pairs)):
            var kv = copy._pairs[i].copy()
            var vals = List[BString]()
            for j in range(len(kv[1])):
                vals.append(kv[1][j].copy())
            new_pairs.append((kv[0].copy(), vals^))
        self._pairs = new_pairs^

    fn add(mut self, key: BString, value: BString):
        """Append a key-value pair."""
        var vals = List[BString]()
        vals.append(value.copy())
        var t = (key.copy(), vals^)
        self._pairs.append(t^)

    fn add_multi(mut self, key: BString, values: List[BString]):
        """Append a key with multiple values (GFF3)."""
        var vals = List[BString]()
        for i in range(len(values)):
            vals.append(values[i].copy())
        var t = (key.copy(), vals^)
        self._pairs.append(t^)

    fn get(ref self, key: String) -> Optional[BString]:
        """Return first value for key, if any."""
        for i in range(len(self._pairs)):
            if self._pairs[i][0].to_string() == key:
                if len(self._pairs[i][1]) > 0:
                    return Optional(self._pairs[i][1][0].copy())
                return None
        return None

    fn get_all(ref self, key: String) -> List[BString]:
        """Return all values for key (GFF3 multi-value)."""
        var out = List[BString]()
        for i in range(len(self._pairs)):
            if self._pairs[i][0].to_string() == key:
                for j in range(len(self._pairs[i][1])):
                    out.append(self._pairs[i][1][j].copy())
        return out^

    fn __len__(self) -> Int:
        return len(self._pairs)

    fn write_to[w: Writer](ref self, mut writer: w, format_gtf: Bool):
        """Emit attributes in GTF (tag \"value\") or GFF3 (key=value) format."""
        for i in range(len(self._pairs)):
            if i > 0:
                if format_gtf:
                    writer.write("; ")
                else:
                    writer.write(";")
            var k = self._pairs[i][0].to_string()
            if format_gtf:
                if len(self._pairs[i][1]) > 0:
                    writer.write(k)
                    writer.write(" \"")
                    writer.write(self._pairs[i][1][0].to_string())
                    writer.write("\"")
            else:
                writer.write(k)
                writer.write("=")
                for j in range(len(self._pairs[i][1])):
                    if j > 0:
                        writer.write(",")
                    writer.write(self._pairs[i][1][j].to_string())


# ---------------------------------------------------------------------------
# RFC 3986 percent-decode (GFF3)
# ---------------------------------------------------------------------------


fn _hex_digit(b: UInt8) -> Int:
    """Return 0-15 for hex digit, -1 otherwise."""
    if b >= 48 and b <= 57:  # '0'-'9'
        return Int(b - 48)
    if b >= 65 and b <= 70:  # 'A'-'F'
        return Int(b - 65 + 10)
    if b >= 97 and b <= 102:  # 'a'-'f'
        return Int(b - 97 + 10)
    return -1


fn percent_decode(span: Span[UInt8, _]) -> String:
    """Decode RFC 3986 percent-encoding. Used for GFF3 attributes and seqid."""
    var out = String()
    var i: Int = 0
    var n = len(span)
    while i < n:
        if span[i] == UInt8(ord("%")) and i + 2 < n:
            var hi = _hex_digit(span[i + 1])
            var lo = _hex_digit(span[i + 2])
            if hi >= 0 and lo >= 0:
                var byte = UInt8(hi * 16 + lo)
                out += chr(Int(byte))
                i += 3
                continue
        out += chr(Int(span[i]))
        i += 1
    return out^


fn percent_decode_to_bstring(span: Span[UInt8, _]) -> BString:
    """Decode RFC 3986 percent-encoding into BString."""
    var s = percent_decode(span)
    return BString(s)


# ---------------------------------------------------------------------------
# GTF attributes: tag "value"; tag "value"; ...
# ---------------------------------------------------------------------------


fn parse_gtf_attributes(span: Span[UInt8, _]) raises -> GffAttributes:
    """Parse GTF column 9: semicolon-separated 'tag \"value\"' pairs."""
    var attrs = GffAttributes()
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
        # part is "tag \"value\"" - find first space
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
            var key = BString(key_span)
            var value = BString(value_span)
            attrs.add(key, value)
    return attrs^


# ---------------------------------------------------------------------------
# GFF3 attributes: key=value; key=val1,val2; ...
# ---------------------------------------------------------------------------


fn parse_gff3_attributes(span: Span[UInt8, _]) raises -> GffAttributes:
    """Parse GFF3 column 9: semicolon-separated key=value; multi-value: key=val1,val2."""
    var attrs = GffAttributes()
    if len(span) == 0:
        return attrs^
    var start: Int = 0
    var n = len(span)
    while start < n:
        while start < n and (
            span[start] == UInt8(ord(" ")) or span[start] == UInt8(ord(";"))
        ):
            start += 1
        if start >= n:
            break
        var end = start
        while end < n and span[end] != UInt8(ord(";")):
            end += 1
        var part = span[start:end]
        start = end + 1
        # part is "key=value" or "key=val1,val2"
        var eq: Int = 0
        while eq < len(part) and part[eq] != UInt8(ord("=")):
            eq += 1
        if eq >= len(part):
            continue
        var key_span = part[0:eq]
        var value_span = part[eq + 1 : len(part)]
        var key = percent_decode_to_bstring(key_span)
        # Multi-value: split value on comma (each part percent-decoded)
        var values = List[BString]()
        var v_start: Int = 0
        var v_n = len(value_span)
        while v_start < v_n:
            var v_end = v_start
            while v_end < v_n and value_span[v_end] != UInt8(ord(",")):
                v_end += 1
            var one = value_span[v_start:v_end]
            if len(one) > 0:
                values.append(percent_decode_to_bstring(one))
            v_start = v_end + 1
        if len(values) > 0:
            attrs.add_multi(key, values)
    return attrs^
