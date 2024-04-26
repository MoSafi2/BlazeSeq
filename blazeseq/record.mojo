from blazeseq.helpers import slice_tensor, write_to_buff
from math import min
from blazeseq.CONSTS import *
from blazeseq.iostream import BufferedLineIterator
from utils.variant import Variant
from tensor import Tensor

alias TI8 = Tensor[I8]
alias schema = Variant[String, QualitySchema]


@value
struct FastqRecord(Sized, Stringable, CollectionElement):
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

    fn __init__(
        inout self,
        SH: String,
        SS: String,
        QH: String,
        QS: String,
        quality_schema: schema = "generic",
    ):
        self.SeqHeader = Tensor[I8](SH.as_bytes())
        self.SeqStr = Tensor[I8](SS.as_bytes())
        self.QuHeader = Tensor[I8](QH.as_bytes())
        self.QuStr = Tensor[I8](QS.as_bytes())
        if quality_schema.isa[String]():
            var q: String  = quality_schema.get[String]()[]
            self.quality_schema = self._parse_schema(q)
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
    fn wirte_record(self) -> Tensor[I8]:
        return self.__concat_record_tensor()

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
            + 4
        )

    @always_inline
    fn __concat_record_tensor(self) -> Tensor[I8]:
        var final_list = List[Int8](capacity=self.total_length())

        for i in range(self.SeqHeader.num_elements()):
            final_list.append(self.SeqHeader[i])
        final_list.append(10)

        for i in range(self.SeqStr.num_elements()):
            final_list.append(self.SeqStr[i])
        final_list.append(10)

        for i in range(self.QuHeader.num_elements()):
            final_list.append(self.QuHeader[i])
        final_list.append(10)

        for i in range(self.QuStr.num_elements()):
            final_list.append(self.QuStr[i])
        final_list.append(10)

        return Tensor[I8](final_list)

    @always_inline
    fn __concat_record_str(self) -> String:
        if self.total_length() == 0:
            return ""

        var line1 = self.SeqHeader
        var line1_str = String(line1._steal_ptr(), self.SeqHeader.num_elements() + 1)

        var line2 = self.SeqStr
        var line2_str = String(line2._steal_ptr(), self.SeqStr.num_elements() + 1)

        var line3 = self.QuHeader
        var line3_str = String(line3._steal_ptr(), self.QuHeader.num_elements() + 1)

        var line4 = self.QuStr
        var line4_str = String(line4._steal_ptr(), self.QuStr.num_elements() + 1)

        return line1_str + "\n" + line2_str + "\n" + line3_str + "\n" + line4_str + "\n"

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
        return self.__concat_record_str()

    @always_inline
    fn __len__(self) -> Int:
        return self.SeqStr.num_elements()

    @always_inline
    fn hash[bits: Int = 2](self) -> UInt64:
        """Hashes the first 31 bp (if possible) into one 64bit."""
        var hash: UInt64 = 0
        var rnge: Int = 64 // bits
        var mask = (0b1 << bits)  - 1
        for i in range(min(rnge, self.SeqStr.num_elements())):
            # Mask for for first 3 significant bits.
            var base_val = self.SeqStr[i] & mask  
            hash = (hash << bits) + int(base_val)
        return hash

    @always_inline
    fn __hash__(self) -> Int:
        return int(self.hash())

    @always_inline
    fn __eq__(self, other: Self) -> Bool:
        return self.__hash__() == other.__hash__()

    fn __ne__(self, other: Self) -> Bool:
        return self.__hash__() != other.__hash__()

from math import min
from memory.memory import memset_zero


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
        if self.qu_header_len() > 1 and self.qu_header_len() != self.seq_header_len():
            raise Error("Corrput Lengths")

    @always_inline
    fn seq_len(self) -> Int32:
        return self.SeqStr.end - self.SeqStr.start

    @always_inline
    fn qu_len(self) -> Int32:
        return self.QuStr.end - self.QuStr.start

    @always_inline
    fn qu_header_len(self) -> Int32:
        return self.QuHeader.end - self.QuHeader.start

    @always_inline
    fn seq_header_len(self) -> Int32:
        return self.SeqHeader.end - self.SeqHeader.start

    fn __len__(self) -> Int:
        return int(self.seq_len())

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

