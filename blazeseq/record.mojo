from blazeseq.helpers import slice_tensor, write_to_buff
from blazeseq.CONSTS import *
from blazeseq.iostream import BufferedLineIterator
from utils.variant import Variant
from tensor import Tensor
from utils import Span
from math import align_down, remainder
from memory import UnsafePointer
from utils import Writable, StringSlice

alias TU8 = Tensor[U8]
alias schema = Variant[String, QualitySchema]


@value
struct FastqRecord(Sized, Stringable, CollectionElement, KeyElement, Writable):
    """Struct that represent a single FastaQ record."""

    var SeqHeader: TU8
    var SeqStr: TU8
    var QuHeader: TU8
    var QuStr: TU8
    var quality_schema: QualitySchema

    fn __init__(
        inout self,
        SH: TU8,
        SS: TU8,
        QH: TU8,
        QS: TU8,
        quality_schema: schema = "generic",
    ) raises:
        self.SeqHeader = SH
        self.QuHeader = QH
        self.SeqStr = SS
        self.QuStr = QS

        if quality_schema.isa[String]():
            self.quality_schema = self._parse_schema(quality_schema[String])
        else:
            self.quality_schema = quality_schema[QualitySchema]

    fn __init__(
        inout self,
        SH: String,
        SS: String,
        QH: String,
        QS: String,
        quality_schema: schema = "generic",
    ):
        self.SeqHeader = SH._buffer
        self.SeqStr = SS._buffer
        self.QuHeader = QH._buffer
        self.QuStr = QS._buffer
        if quality_schema.isa[String]():
            var q: String = quality_schema[String]
            self.quality_schema = self._parse_schema(q)
        else:
            self.quality_schema = quality_schema[QualitySchema]

    @always_inline
    fn get_seq(self) -> StringSlice[__origin_of(self)]:
        return StringSlice[__origin_of(self)](
            ptr=self.SeqStr._ptr, length=self.SeqStr.num_elements()
        )

    @always_inline
    fn get_qulity(self) -> StringSlice[__origin_of(self)]:
        return StringSlice[__origin_of(self)](
            ptr=self.QuStr._ptr, length=self.QuStr.num_elements()
        )

    @always_inline
    fn get_qulity_scores(self, quality_format: String) -> Tensor[U8]:
        var schema = self._parse_schema((quality_format))
        return self.QuStr - schema.OFFSET

    @always_inline
    fn get_qulity_scores(self, schema: QualitySchema) -> Tensor[U8]:
        return self.QuStr - schema.OFFSET

    @always_inline
    fn get_qulity_scores(self, offset: UInt8) -> Tensor[U8]:
        return self.QuStr - offset

    @always_inline
    fn get_header(self) -> StringSlice[__origin_of(self)]:
        return StringSlice[__origin_of(self)](
            ptr=self.SeqHeader._ptr, length=self.SeqHeader.num_elements()
        )

    @always_inline
    fn validate_record(self) raises:
        if self.SeqHeader[0] != read_header:
            raise Error("Sequence Header is corrupt")

        if self.QuHeader[0] != quality_header:
            raise Error("Quality Header is corrupt")

        if self.len_record() != self.len_quality():
            raise Error("Corrput Lengths")

        if self.len_qu_header() > 1:
            if self.len_qu_header() != self.len_seq_header():
                raise Error("Quality Header is corrupt")

        if self.len_qu_header() > 1:
            for i in range(1, self.len_qu_header()):
                if self.QuHeader[i] != self.SeqHeader[i]:
                    raise Error("Non matching headers")

    @always_inline
    fn validate_quality_schema(self) raises:
        for i in range(self.len_quality()):
            if (
                self.QuStr[i] > self.quality_schema.UPPER
                or self.QuStr[i] < self.quality_schema.LOWER
            ):
                raise Error(
                    "Corrput quality score according to proivded schema"
                )

    @always_inline
    fn total_length(self) -> Int:
        return (
            self.len_seq_header()
            + self.len_record()
            + self.len_qu_header()
            + self.len_quality()
            + 4
        )

    fn write_to[w: Writer](self, inout writer: w):
        var l1 = Span[origin = __origin_of(self.SeqHeader)](
            ptr=self.SeqHeader.unsafe_ptr(),
            length=self.SeqHeader.num_elements(),
        )
        var l2 = Span[origin = __origin_of(self.SeqStr)](
            ptr=self.SeqStr.unsafe_ptr(), length=self.SeqStr.num_elements()
        )
        var l3 = Span[origin = __origin_of(self.QuHeader)](
            ptr=self.QuHeader.unsafe_ptr(), length=self.QuHeader.num_elements()
        )
        var l4 = Span[origin = __origin_of(self.QuStr)](
            ptr=self.QuStr.unsafe_ptr(), length=self.QuStr.num_elements()
        )
        writer.write_bytes(l1)
        writer.write("\n")
        writer.write_bytes(l2)
        writer.write("\n")
        writer.write_bytes(l3)
        writer.write("\n")
        writer.write_bytes(l4)
        writer.write("\n")

    @staticmethod
    @always_inline
    fn _parse_schema(quality_format: String) -> QualitySchema:
        var schema: QualitySchema

        if quality_format == "sanger":
            schema = sanger_schema
        elif quality_format == "solexa":
            schema = solexa_schema
        elif quality_format == "illumina_1.3":
            schema = illumina_1_3_schema
        elif quality_format == "illumina_1.5":
            schema = illumina_1_5_schema
        elif quality_format == "illumina_1.8":
            schema = illumina_1_8
        elif quality_format == "generic":
            schema = generic_schema
        else:
            print(
                "Uknown quality schema please choose one of 'sanger', 'solexa',"
                " 'illumina_1.3', 'illumina_1.5' 'illumina_1.8', or 'generic'"
            )
            return generic_schema
        return schema

    # BUG: returns Smaller strings that expected.
    @always_inline
    fn __str__(self) -> String:
        return String.write(self)

    @always_inline
    fn __len__(self) -> Int:
        return self.SeqStr.num_elements()

    @always_inline
    fn len_record(self) -> Int:
        return self.SeqStr.num_elements()

    @always_inline
    fn len_quality(self) -> Int:
        return self.QuStr.num_elements()

    @always_inline
    fn len_qu_header(self) -> Int:
        return self.QuHeader.num_elements()

    @always_inline
    fn len_seq_header(self) -> Int:
        return self.SeqHeader.num_elements()

    @always_inline
    fn hash[bits: Int = 3, length: Int = 64 // bits](self) -> UInt64:
        """Hashes the first xx bp (if possible) into one 64bit. Max length is 64/nBits per bp.
        """

        @parameter
        if length < 32:
            return self._hash_packed(self.SeqStr.unsafe_ptr(), length)
        return self._hash_additive(self.SeqStr.unsafe_ptr(), length)

    # Can be Vectorized
    @staticmethod
    @always_inline
    fn _hash_packed[
        bits: Int = 3
    ](bytes: UnsafePointer[Byte], length: Int) -> UInt64:
        """
        Hash the DNA strand to into 64bits unsigned number using xbit encoding.
        If the length of the bytes strand is longer than 64//bits bps, the hash is truncated.
        ----

        parameters:
        - bits (Int): the number of least significant bits used to hash a base pair. increased bit width reduces the number of bp that can be hashed.

        args:
        - bytes (UnsafePointer[Byte]): pointer the the basepair buffer.
        - length (Int): the length of the buffer to be hashed.
        """
        alias rnge: Int = 64 // bits
        alias width = simdwidthof[Byte]()
        var hash: UInt64 = 0
        var mask = (0b1 << bits) - 1
        for i in range(0, min(rnge, length), width):
            # Mask for for first <n> significant bits, vectorized operation.
            var base_vals = bytes.load[width=width](i) & mask
            for j in range(len(base_vals)):
                hash = (hash << bits) | int(base_vals[j])
        return hash

    # Can be Vectorized
    @staticmethod
    @always_inline
    fn _hash_additive[
        bits: Int = 3
    ](bytes: UnsafePointer[UInt8], length: Int) -> UInt64:
        """Hashes longer DNA sequences . It hashes 16bps spans of the sequences and using 2 or 3 bit encoding and adds them to the hash.
        """
        constrained[
            bits <= 3, "Additive hashing can only hash up to 3bit resolution"
        ]()
        var full_hash: UInt64 = 0
        var mask = (0b1 << bits) - 1
        var rounds = align_down(length, 16)
        var rem = length % 16

        for round in range(rounds):
            var interim_hash: UInt64 = 0

            @parameter
            for i in range(16):
                var base_val = bytes[i + 16 * round] & mask
                interim_hash = interim_hash << bits | int(base_val)
            full_hash = full_hash + interim_hash

        if rem > 0:
            var interim_hash: UInt64 = 0
            for i in range(rem):
                var base_val = bytes[i + 16 * rounds] & mask
                interim_hash = interim_hash << bits | int(base_val)
            full_hash = full_hash + interim_hash

        return full_hash

    @always_inline
    fn __hash__(self) -> UInt:
        return int(self.hash())

    @always_inline
    fn __eq__(self, other: Self) -> Bool:
        return self.__hash__() == other.__hash__()

    fn __ne__(self, other: Self) -> Bool:
        return self.__hash__() != other.__hash__()


@value
struct RecordCoord(Sized, Stringable, CollectionElement):
    """Struct that represent coordinates of a FastqRecord in a chunk. Provides minimal validation of the record. Mainly used for fast parsing.
    """

    var SeqHeader: Slice
    var SeqStr: Slice
    var QuHeader: Slice
    var QuStr: Slice

    fn __init__(
        inout self,
        SH: Slice,
        SS: Slice,
        QH: Slice,
        QS: Slice,
    ):
        self.SeqHeader = SH
        self.SeqStr = SS
        self.QuHeader = QH
        self.QuStr = QS

    @always_inline
    fn validate(self) raises:
        if self.seq_len() != self.qu_len():
            raise Error("Corrput Lengths")
        if (
            self.qu_header_len() > 1
            and self.qu_header_len() != self.seq_header_len()
        ):
            raise Error("Corrput Lengths")

    @always_inline
    fn seq_len(self) -> Int32:
        return self.SeqStr.end.or_else(0) - self.SeqStr.start.or_else(0)

    @always_inline
    fn qu_len(self) -> Int32:
        return self.QuStr.end.or_else(0) - self.QuStr.start.or_else(0)

    @always_inline
    fn qu_header_len(self) -> Int32:
        return self.QuHeader.end.or_else(0) - self.QuHeader.start.or_else(0)

    @always_inline
    fn seq_header_len(self) -> Int32:
        return self.SeqHeader.end.or_else(0) - self.SeqHeader.start.or_else(0)

    fn __len__(self) -> Int:
        return int(self.seq_len())

    fn __str__(self) -> String:
        return (
            String("SeqHeader: ")
            + str(self.SeqHeader.start.or_else(0))
            + "..."
            + str(self.SeqHeader.end.or_else(0))
            + "\nSeqStr: "
            + str(self.SeqStr.start.or_else(0))
            + "..."
            + str(self.SeqStr.end.or_else(0))
            + "\nQuHeader: "
            + str(self.QuHeader.start.or_else(0))
            + "..."
            + str(self.QuHeader.end.or_else(0))
            + "\nQuStr: "
            + str(self.QuStr.start.or_else(0))
            + "..."
            + str(self.QuStr.end.or_else(0))
        )
