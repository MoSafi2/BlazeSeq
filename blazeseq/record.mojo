from .helpers import slice_tensor, write_to_buff
from math import min
from .CONSTS import *
from .iostream import BufferedLineIterator
from utils.variant import Variant
from tensor import Tensor

alias TI8 = Tensor[I8]
alias schema = Variant[String, QualitySchema]


@value
struct FastqRecord(CollectionElement, Sized, Stringable, KeyElement):
    """Struct that represent a single FastaQ record."""

    var SeqHeader: TI8
    var SeqStr: TI8
    var QuHeader: TI8
    var QuStr: TI8
    var quality_schema: QualitySchema

    fn __init__(
        inout self,
        SH: TI8,
        SS: TI8,
        QH: TI8,
        QS: TI8,
        quality_schema: schema = "generic",
    ) raises:
        self.SeqHeader = SH
        self.QuHeader = QH
        self.SeqStr = SS
        self.QuStr = QS

        if quality_schema.isa[String]():
            self.quality_schema = self._parse_schema(quality_schema.get[String]()[])
        else:
            self.quality_schema = quality_schema.get[QualitySchema]()[]

    @always_inline
    fn get_seq(self) -> String:
        var temp = self.SeqStr
        return String(temp._steal_ptr(), temp.num_elements())

    @always_inline
    fn get_qulity(self) -> String:
        var temp = self.QuStr
        return String(temp._steal_ptr(), temp.num_elements())

    @always_inline
    fn get_qulity_scores(self, quality_format: String) -> Tensor[I8]:
        var schema = self._parse_schema((quality_format))
        return self.QuStr - schema.OFFSET

    @always_inline
    fn get_qulity_scores(self, schema: QualitySchema) -> Tensor[I8]:
        return self.QuStr - schema.OFFSET

    @always_inline
    fn get_qulity_scores(self, offset: Int8) -> Tensor[I8]:
        return self.QuStr - offset

    @always_inline
    fn get_header(self) -> String:
        var temp = self.SeqHeader
        return String(temp._steal_ptr(), temp.num_elements())

    @always_inline
    fn wirte_record(self) -> String:
        var temp = self.__concat_record()
        return String(temp._steal_ptr(), temp.num_elements())

    @always_inline
    fn validate_record(self) raises:
        if self.SeqHeader[0] != read_header:
            raise Error("Sequence Header is corrupt")

        if self.QuHeader[0] != quality_header:
            raise Error("Quality Header is corrupt")

        if self.SeqStr.num_elements() != self.QuStr.num_elements():
            raise Error("Corrput Lengths")

        if self.QuHeader.num_elements() > 1:
            if self.QuHeader.num_elements() != self.SeqHeader.num_elements():
                raise Error("Quality Header is corrupt")

        if self.QuHeader.num_elements() > 1:
            for i in range(1, self.QuHeader.num_elements()):
                if self.QuHeader[i] != self.SeqHeader[i]:
                    raise Error("Non matching headers")

    @always_inline
    fn validate_quality_schema(self) raises:
        for i in range(self.QuStr.num_elements()):
            if (
                self.QuStr[i] > self.quality_schema.UPPER
                or self.QuStr[i] < self.quality_schema.LOWER
            ):
                raise Error("Corrput quality score according to proivded schema")

    @always_inline
    fn total_length(self) -> Int:
        return (
            self.SeqHeader.num_elements()
            + self.SeqStr.num_elements()
            + self.QuHeader.num_elements()
            + self.QuStr.num_elements()
        )

    @always_inline
    fn __concat_record(self) -> Tensor[I8]:
        if self.total_length() == 0:
            return Tensor[I8](0)

        var offset = 0
        var t = Tensor[I8](self.total_length())

        write_to_buff(self.SeqHeader, t, offset)
        offset = offset + self.SeqHeader.num_elements() + 1
        t[offset - 1] = new_line

        write_to_buff(self.SeqStr, t, offset)
        offset = offset + self.SeqStr.num_elements() + 1
        t[offset - 1] = new_line

        write_to_buff(self.QuHeader, t, offset)
        offset = offset + self.QuHeader.num_elements() + 1
        t[offset - 1] = new_line

        write_to_buff(self.QuStr, t, offset)
        offset = offset + self.QuStr.num_elements() + 1
        t[offset - 1] = new_line

        return t

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

    @always_inline
    fn hash(self) -> Int:
        return self.__hash__()

    # BUG: returns Smaller strings that expected.
    @always_inline
    fn __str__(self) -> String:
        if self.total_length() == 0:
            return ""
        var concat = self.__concat_record()
        return String(concat._steal_ptr(), self.total_length())

    @always_inline
    fn __len__(self) -> Int:
        return self.SeqStr.num_elements()

    @always_inline
    fn __hash__(self) -> Int:
        """Hashes the first 31 bp (if possible) into one 64bit"""
        var hash: Int = 0
        for i in range(min(31, self.SeqStr.num_elements())):
            var rem = self.SeqStr[i] & 0x03  # Mask for for first 2 significant bits.
            hash = (hash << 2) + rem.to_int()
        return hash

    @always_inline
    fn __eq__(self, other: Self) -> Bool:
        return self.__hash__() == other.__hash__()

    fn __ne__(self, other: Self) -> Bool:
        return self.__hash__() != other.__hash__()


@value
struct RecordCoord(CollectionElement, Sized, Stringable):
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
    fn validate(self, buf: BufferedLineIterator) raises:
        if self.seq_len() != self.qu_len():
            print(self.seq_len(), self.qu_len())
            raise Error("Corrupt Lengths.")

    @always_inline
    fn seq_len(self) -> Int32:
        return self.SeqStr.end - self.SeqStr.start

    @always_inline
    fn qu_len(self) -> Int32:
        return self.QuStr.end - self.QuStr.start

    @always_inline
    fn qu_header_len(self) -> Int32:
        return self.QuHeader.end - self.QuHeader.start

    fn __len__(self) -> Int:
        return self.seq_len().to_int()

    fn __str__(self) -> String:
        return (
            String("SeqHeader: ")
            + self.SeqHeader.start
            + "..."
            + self.SeqHeader.end
            + "\nSeqStr: "
            + self.SeqStr.start
            + "..."
            + self.SeqStr.end
            + "\nQuHeader: "
            + self.QuHeader.start
            + "..."
            + self.QuHeader.end
            + "\nQuStr: "
            + self.QuStr.start
            + "..."
            + self.QuStr.end
        )


struct RollingHash:
    var start: Int
    var end: Int
    var init_hash: Int
    var hash: Int

    fn __init__(inout self, record: FastqRecord):
        self.start = 0
        self.end = min(len(record), 31)
        self.init_hash = record.hash()
        self.hash = self.init_hash
        var ref = Reference(record)

    fn rolling_hash(inout self, record: FastqRecord, start: Int, end: Int) -> Int:
        var ele = min(end - start, 31)

        for i in range(self.end, end):
            self.hash = self.hash & 0x1FFFFFFFFFFFFFFF
            var rem = record.SeqStr[i] & 0x03  # Mask for the first two bits
            self.hash = (self.hash << 2) + rem.to_int()

        self.start += self.end - end
        self.end = end
        return self.hash
