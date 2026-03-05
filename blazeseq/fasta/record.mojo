from hashlib.hasher import default_hasher, Hasher
from blazeseq.ascii_string import ASCIIString
from collections.string import StringSlice, String
from memory import Span
from blazeseq.io.writers import Writer


@fieldwise_init
struct Definition(Copyable, Movable):
    """Definition of a FASTA/FASTQ record.

    Attributes:
        Id: The identifier of the record.
        Description: The description of the record.
    """

    var Id: ASCIIString
    var Description: Optional[ASCIIString]


struct FastaRecord(
    Copyable,
    Hashable,
    Movable,
    Representable,
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

    var _id: ASCIIString
    var _sequence: ASCIIString

    @always_inline
    fn __init__(
        out self,
        id: String,
        sequence: String,
    ) raises:
        """Build from id and sequence strings."""
        self._id = ASCIIString(id)
        self._sequence = ASCIIString(sequence)

    @always_inline
    fn __init__(
        out self,
        id: Span[Byte, MutExternalOrigin],
        sequence: Span[Byte, MutExternalOrigin],
    ) raises:
        self._id = ASCIIString(id)
        self._sequence = ASCIIString(sequence)

    fn __init__(
        out self,
        var id: ASCIIString,
        var sequence: ASCIIString,
    ):
        self._id = id^
        self._sequence = sequence^

    @always_inline
    fn sequence(ref [_]self) -> Span[Byte, origin_of(self)]:
        """Return the sequence line as a span."""
        return Span[Byte, origin_of(self)](
            ptr=self._sequence.ptr.unsafe_mut_cast[
                origin_of(self).mut
            ]().unsafe_origin_cast[origin_of(self)](),
            length=len(self._sequence),
        )

    @always_inline
    fn id(ref [_]self) -> Span[Byte, origin_of(self)]:
        """Return the read identifier (id without leading '>') as a span."""
        return Span[Byte, origin_of(self)](
            ptr=self._id.ptr.unsafe_mut_cast[
                origin_of(self).mut
            ]().unsafe_origin_cast[origin_of(self)](),
            length=len(self._id),
        )

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
