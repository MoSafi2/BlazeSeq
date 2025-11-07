from hashlib.hasher import default_hasher, Hasher
from blazeseq.quality_schema import (
    QualitySchema,
    sanger_schema,
    illumina_1_3_schema,
    solexa_schema,
    illumina_1_5_schema,
    illumina_1_8_schema,
    generic_schema,
)
from utils.variant import Variant

alias schema = Variant[String, QualitySchema]
alias read_header = ord("@")
alias quality_header = ord("+")
alias new_line = ord("\n")
alias carriage_return = ord("\r")


struct FastqRecord[val: Bool = True](
    Copyable,
    EqualityComparable,
    Hashable,
    Movable,
    Representable,
    Sized,
    Writable,
):
    """Struct that represent a single FastaQ record."""

    var SeqHeader: String
    var SeqStr: String
    var QuHeader: String
    var QuStr: String
    var quality_schema: QualitySchema

    fn __init__(
        out self,
        SeqHeader: String,
        SeqStr: String,
        QuHeader: String,
        QuStr: String,
        quality_schema: schema = "generic",
    ) raises:
        self.SeqHeader = SeqHeader
        self.QuHeader = QuHeader
        self.SeqStr = SeqStr
        self.QuStr = QuStr

        if quality_schema.isa[String]():
            self.quality_schema = _parse_schema(quality_schema[String])
        else:
            self.quality_schema = quality_schema[QualitySchema].copy()

        @parameter
        if val:
            self.validate_record()
            self.validate_quality_schema()

    fn __init__(out self, sequence: String) raises:
        var seqs = sequence.strip().split("\n")
        if len(seqs) > 4:
            raise Error("Sequence does not seem to be valid")

        # Bug when Using
        self.SeqHeader = String(seqs[0].strip())
        self.SeqStr = String(seqs[1].strip())
        self.QuHeader = String(seqs[2].strip())
        self.QuStr = String(seqs[3].strip())
        self.quality_schema = materialize[generic_schema]()

        @parameter
        if val:
            self.validate_record()
            self.validate_quality_schema()

    @always_inline
    fn get_seq(self) -> StringSlice[origin_of(self.SeqStr)]:
        return self.SeqStr.as_string_slice()

    @always_inline
    fn get_quality_string(self) -> StringSlice[origin_of(self.QuStr)]:
        return self.QuStr.as_string_slice()

    @always_inline
    fn get_qulity_scores(self, mut quality_format: schema) -> List[UInt8]:
        var in_schema: QualitySchema

        if quality_format.isa[String]():
            in_schema = _parse_schema(quality_format.take[String]())
        else:
            in_schema = quality_format.take[QualitySchema]()

        output = List[UInt8](capacity=len(self.QuStr))
        bytes = self.QuStr.as_bytes()
        for i in range(len(self.QuStr)):
            output[i] = bytes[i] - in_schema.OFFSET
        return output^

    @always_inline
    fn get_qulity_scores(self, offset: UInt8) -> List[UInt8]:
        output = List[UInt8](capacity=len(self.QuStr))
        bytes = self.QuStr.as_bytes()
        for i in range(len(self.QuStr)):
            output[i] = bytes[i] - offset
        return output^

    @always_inline
    fn get_header_string(self) -> StringSlice[origin_of(self.SeqHeader)]:
        return self.SeqHeader.as_string_slice()

    @always_inline
    fn validate_record(self) raises:
        if self.SeqHeader.as_bytes()[0] != read_header:
            raise Error("Sequence header does not start with '@'")

        if self.QuHeader.as_bytes()[0] != quality_header:
            raise Error("Quality header dies not start with '+'")

        if len(self.SeqStr) != len(self.QuStr):
            raise Error(
                "Quality and Sequencing string does not match in lengths"
            )

        if len(self.QuHeader) > 1:
            if len(self.QuHeader) != len(self.SeqHeader):
                raise Error(
                    "Quality Header is not the same length as the Sequencing"
                    " header"
                )

            if (
                self.QuHeader.as_string_slice()[1:]
                != self.SeqHeader.as_string_slice()[1:]
            ):
                raise Error(
                    "Quality Header is not the same as the Sequecing Header"
                )

    @always_inline
    fn validate_quality_schema(self) raises:
        for i in range(len(self.QuStr)):
            if (
                self.QuStr.as_bytes()[i] > self.quality_schema.UPPER
                or self.QuStr.as_bytes()[i] < self.quality_schema.LOWER
            ):
                raise Error(
                    "Corrput quality score according to proivded schema"
                )

    @always_inline
    fn total_length(self) -> Int:
        return (
            len(self.QuHeader)
            + len(self.QuStr)
            + len(self.SeqHeader)
            + len(self.SeqStr)
        )

    @always_inline
    fn __str__(self) -> String:
        return String.write(self)

    fn write_to[w: Writer](self, mut writer: w):
        writer.write(
            self.SeqHeader,
            "\n",
            self.SeqStr,
            "\n",
            self.QuHeader,
            "\n",
            self.QuStr,
            "\n",
        )

    @always_inline
    fn __len__(self) -> Int:
        return len(self.SeqStr)

    @always_inline
    fn __hash__[H: Hasher](self, mut hasher: H):
        hasher.update(self.SeqStr.as_string_slice())

    @always_inline
    fn __eq__(self, other: Self) -> Bool:
        return self.SeqStr == other.SeqStr

    fn __ne__(self, other: Self) -> Bool:
        return not self.__eq__(other)

    fn __repr__(self) -> String:
        return self.__str__()


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
        schema = illumina_1_8_schema
    elif quality_format == "generic":
        schema = generic_schema
    else:
        print(
            "Uknown quality schema please choose one of 'sanger', 'solexa',"
            " 'illumina_1.3', 'illumina_1.5' 'illumina_1.8', or 'generic'"
        )
        return generic_schema
    return schema



@fieldwise_init
struct RecordCoord[
    mut: Bool, //, o: Origin[mut], validate_quality: Bool = False
](Sized, Writable, Movable, Copyable):
    """Struct that represent coordinates of a FastqRecord in a chunk. Provides minimal validation of the record. Mainly used for fast parsing.
    """

    var SeqHeader: Span[Byte, o]
    var SeqStr: Span[Byte, o]
    var QuHeader: Span[Byte, o]
    var QuStr: Span[Byte, o]
    var quality_schema: QualitySchema


    fn __init__(
        out self,
        SeqHeader: Span[Byte, o],
        SeqStr: Span[Byte, o],
        QuHeader: Span[Byte, o],
        QuStr: Span[Byte, o],
        quality_schema: schema = "generic",

    ):
        self.SeqHeader = SeqHeader
        self.SeqStr = SeqStr
        self.QuHeader = QuHeader
        self.QuStr = QuStr

        if quality_schema.isa[String]():
            self.quality_schema = _parse_schema(quality_schema[String])
        else:
            self.quality_schema = quality_schema[QualitySchema]


    @always_inline
    fn get_seq(self) -> StringSlice[origin_of(self)]:
        return StringSlice[origin = origin_of(self)](
            ptr=self.SeqStr.unsafe_ptr(), length=len(self.SeqStr)
        )

    @always_inline
    fn get_quality(self) -> StringSlice[origin_of(self)]:
        return StringSlice[origin = origin_of(self)](
            ptr=self.QuStr.unsafe_ptr(), length=len(self.QuStr)
        )

    @always_inline
    fn get_header(self) -> StringSlice[origin_of(self)]:
        return StringSlice[origin = origin_of(self)](
            ptr=self.SeqHeader.unsafe_ptr(), length=len(self.SeqHeader)
        )

    @always_inline
    fn __len__(self) -> Int:
        return self.len_record()

    @always_inline
    fn len_record(self) -> Int:
        return len(self.SeqStr)

    @always_inline
    fn len_quality(self) -> Int:
        return len(self.QuStr)

    @always_inline
    fn len_qu_header(self) -> Int:
        return len(self.QuHeader)

    @always_inline
    fn len_seq_header(self) -> Int:
        return len(self.SeqHeader)

    @always_inline
    fn total_length(self) -> Int:
        return (
            self.len_seq_header()
            + self.len_record()
            + self.len_qu_header()
            + self.len_quality()
        )

    @always_inline
    fn get_qulity_scores(
        self, quality_format: schema
    ) -> List[Byte]:
        if quality_format.isa[String]():
            schema = _parse_schema((quality_format[String]))
        else:
            schema = quality_format[QualitySchema]

        output = List[Byte](capacity=self.len_quality())
        for i in range(self.len_quality()):
            output[i] = self.QuStr[i] - schema.OFFSET
        return output^

    @always_inline
    fn get_qulity_scores(
        self, offset: UInt8
    ) -> List[Byte]:
        output = List[Byte](capacity=self.len_quality())
        for i in range(self.len_quality()):
            output[i] = self.QuStr[i] - offset
        return output^


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
            if self.QuStr[i] > Int(self.quality_schema.UPPER) or self.QuStr[i]
             < Int(self.quality_schema.LOWER):
                raise Error(
                    "Corrput quality score according to proivded schema"
                )



    @always_inline
    fn seq_len(self) -> Int32:
        return len(self.SeqStr)

    @always_inline
    fn qu_len(self) -> Int32:
        return len(self.QuStr)

    @always_inline
    fn qu_header_len(self) -> Int32:
        return len(self.QuHeader)

    @always_inline
    fn seq_header_len(self) -> Int32:
        return len(self.SeqHeader)


    fn write_to[w: Writer](self, mut writer: w):
        writer.write_bytes(self.SeqHeader)
        writer.write("\n")
        writer.write_bytes(self.SeqStr)
        writer.write("\n")
        writer.write_bytes(self.QuHeader)
        writer.write("\n")
        writer.write_bytes(self.QuStr)

