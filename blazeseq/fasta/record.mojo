from std.hashlib.hasher import default_hasher, Hasher
from blazeseq.byte_string import BString
from blazeseq.fasta.definition import Definition
from std.collections.string import StringSlice, String
from std.memory import Span
from blazeseq.io.writers import Writer
from blazeseq.utils import _strip_spaces


struct FastaRecord(
    Copyable,
    Hashable,
    Movable,
    Sized,
    Writable,
):
    """A single FASTA record (two logical parts: >id, sequence).

    Multi-line sequences are stored as a single logical line (no embedded newlines).
    Owned representation; safe to store in collections and reuse.

    Attributes:
        id: Read identifier (id line content after the '>'; stored without leading '>').
        sequence: Sequence line (normalized to a single line, no '\\n' or '\\r').
    """

    var _id: BString
    var _sequence: BString

    @always_inline
    fn __init__(
        out self,
        id: String,
        sequence: String,
    ) raises:
        """Build from id and sequence strings."""
        self._id = BString(id)
        self._sequence = BString(sequence)

    @always_inline
    fn __init__(
        out self,
        id: Span[Byte, _],
        sequence: Span[Byte, _],
    ) raises:
        self._id = BString(id)
        self._sequence = BString(sequence)

    fn __init__(
        out self,
        var id: BString,
        var sequence: BString,
    ):
        self._id = id^
        self._sequence = sequence^

    @always_inline
    fn sequence(ref [_]self) -> StringSlice[origin = origin_of(self)]:
        """Return the sequence line as a string slice."""
        var span = Span[Byte, origin_of(self)](
            ptr=self._sequence.ptr.unsafe_mut_cast[
                origin_of(self).mut
            ]().unsafe_origin_cast[origin_of(self)](),
            length=len(self._sequence),
        )
        return StringSlice(unsafe_from_utf8=span)

    @always_inline
    fn id(ref [_]self) -> StringSlice[origin = origin_of(self)]:
        """Return the read identifier (id without leading '>') as a string slice.
        """
        var span = Span[Byte, origin_of(self)](
            ptr=self._id.ptr.unsafe_mut_cast[
                origin_of(self).mut
            ]().unsafe_origin_cast[origin_of(self)](),
            length=len(self._id),
        )
        return StringSlice(unsafe_from_utf8=span)

    fn definition(self) -> Definition:
        var id_str = self._id.as_string_slice()
        var parts = id_str.split(" ")
        var id = parts[0].strip()
        var id_ascii = BString(id)
        if len(parts) > 1:
            description = BString()
            for part in parts[1:]:
                description.extend(part.as_bytes())
            description = BString(_strip_spaces(description.as_span()))
            return Definition(Id=id_ascii^, Description=description^)

        return Definition(Id=id_ascii^, Description=None)

    @always_inline
    fn byte_len(self) -> Int:
        """Return total byte length when written (\">\" + id + \"\\n\" + sequence + \"\\n\").
        """
        return 1 + len(self._id) + 1 + len(self._sequence) + 1

    @always_inline
    fn __str__(self) -> String:
        return String.write(self)

    fn write[w: Writer](self, mut writer: w):
        """Write the record in standard FASTA format."""
        writer.write(">")
        writer.write(
            self._id.to_string(),
            "\n",
            self._sequence.to_string(),
            "\n",
        )

    @always_inline
    fn write_to[w: Writer](self, mut writer: w):
        """Required by Writable trait; delegates to write()."""
        self.write(writer)

    @always_inline
    fn __len__(self) -> Int:
        """Return the sequence length (number of bases)."""
        return len(self._sequence)

    @always_inline
    fn __hash__[H: Hasher](self, mut hasher: H):
        hasher.update(self._sequence.as_string_slice())

    @always_inline
    fn __eq__(self, other: Self) -> Bool:
        return self._sequence == other._sequence

    fn __ne__(self, other: Self) -> Bool:
        return not self.__eq__(other)

    fn __repr__(self) -> String:
        return self.__str__()
