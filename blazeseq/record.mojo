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
from blazeseq.byte_string import ByteString
from utils.variant import Variant

comptime schema = Variant[String, QualitySchema]
comptime read_header = ord("@")
comptime quality_header = ord("+")
comptime new_line = ord("\n")
comptime carriage_return = ord("\r")


struct FastqRecord(
    Copyable,
    Hashable,
    Movable,
    Representable,
    Sized,
    Writable,
):
    """Struct that represent a single FastaQ record."""

    var SeqHeader: ByteString
    var SeqStr: ByteString
    var QuHeader: ByteString
    var QuStr: ByteString
    var quality_schema: QualitySchema


    @always_inline
    fn __init__(out self, seq_header: String, seq_str: String, qu_header: String, qu_str: String, quality_schema: schema = "generic") raises:
        self.SeqHeader = ByteString(seq_header)
        self.SeqStr = ByteString(seq_str)
        self.QuHeader = ByteString(qu_header)
        self.QuStr = ByteString(qu_str)

        if quality_schema.isa[String]():
            self.quality_schema = _parse_schema(quality_schema[String])
        else:
            self.quality_schema = quality_schema[QualitySchema].copy()

    @always_inline
    fn __init__(
        out self,
        SeqHeader: Span[Byte, MutExternalOrigin],
        SeqStr: Span[Byte, MutExternalOrigin],
        QuHeader: Span[Byte, MutExternalOrigin],
        QuStr: Span[Byte, MutExternalOrigin],
        quality_schema: schema = "generic",
    ) raises:
        self.SeqHeader = ByteString(SeqHeader)
        self.QuHeader = ByteString(QuHeader)
        self.SeqStr = ByteString(SeqStr)
        self.QuStr = ByteString(QuStr)

        if quality_schema.isa[String]():
            self.quality_schema = _parse_schema(quality_schema[String])
        else:
            self.quality_schema = quality_schema[QualitySchema].copy()

    fn __init__(out self, sequence: String) raises:
        var seqs = sequence.strip().split("\n")
        if len(seqs) > 4:
            raise Error("Sequence does not seem to be valid")

        # Bug when Using
        self.SeqHeader = ByteString(String(seqs[0].strip()))
        self.SeqStr = ByteString(String(seqs[1].strip()))
        self.QuHeader = ByteString(String(seqs[2].strip()))
        self.QuStr = ByteString(String(seqs[3].strip()))
        self.quality_schema = materialize[generic_schema]()

    @always_inline
    fn get_seq(self) -> StringSlice[MutExternalOrigin]:
        return self.SeqStr.as_string_slice()

    @always_inline
    fn get_quality_string(self) -> StringSlice[MutExternalOrigin]:
        return self.QuStr.as_string_slice()

    @always_inline
    fn get_quality_scores(self, mut quality_format: schema) -> List[UInt8]:
        var in_schema: QualitySchema

        if quality_format.isa[String]():
            in_schema = _parse_schema(quality_format.take[String]())
        else:
            in_schema = quality_format.take[QualitySchema]()

        output = List[UInt8](length=len(self.QuStr), fill=0)
        for i in range(len(self.QuStr)):
            output[i] = self.QuStr[i] - in_schema.OFFSET
        return output^

    @always_inline
    fn get_quality_scores(self, offset: UInt8) -> List[UInt8]:
        output = List[UInt8](length=len(self.QuStr), fill=0)
        for i in range(len(self.QuStr)):
            output[i] = self.QuStr[i] - offset
        return output^

    @always_inline
    fn get_header_string(self) -> StringSlice[MutExternalOrigin]:
        return self.SeqHeader.as_string_slice()

    @always_inline
    fn validate_record(self) raises:
        """Delegate to default Validator for backward compatibility."""
        var v = Validator(check_quality=False, quality_schema=self.quality_schema.copy())
        v.validate_record(self)

    @always_inline
    fn validate_quality_schema(self) raises:
        """Delegate to default Validator for backward compatibility."""
        var v = Validator(check_quality=True, quality_schema=self.quality_schema.copy())
        v.validate_quality_schema(self)

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
            self.SeqHeader.to_string(),
            "\n",
            self.SeqStr.to_string(),
            "\n",
            self.QuHeader.to_string(),
            "\n",
            self.QuStr.to_string(),
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


# ---------------------------------------------------------------------------
# Validator: FASTQ record validation, instantiable from ParserConfig
# ---------------------------------------------------------------------------


struct Validator(Copyable):
    """
    Validator for FASTQ record structure and optional quality-schema checks.
    Instantiate with check_quality and quality_schema (e.g. from ParserConfig)
    and attach to a parser, or use for one-off validation of FastqRecords.
    """

    var check_quality: Bool
    var quality_schema: QualitySchema

    fn __init__(out self, check_quality: Bool, quality_schema: QualitySchema):
        """Initialize Validator with quality-check flag and schema for bounds."""
        self.check_quality = check_quality
        self.quality_schema = quality_schema.copy()

    @always_inline
    fn validate_record(self, record: FastqRecord) raises:
        """Validate record structure: @ header, + header, seq/qual length, optional header match."""
        if record.SeqHeader[0] != read_header:
            raise Error("Sequence header does not start with '@'")

        if record.QuHeader[0] != quality_header:
            raise Error("Quality header does not start with '+'")

        if len(record.SeqStr) != len(record.QuStr):
            raise Error(
                "Quality and Sequencing string does not match in lengths"
            )

        if len(record.QuHeader) > 1:
            if len(record.QuHeader) != len(record.SeqHeader):
                raise Error(
                    "Quality Header is not the same length as the Sequencing"
                    " header"
                )

            var qu_header_slice = record.QuHeader.as_string_slice()[1:]
            var seq_header_slice = record.SeqHeader.as_string_slice()[1:]
            if qu_header_slice != seq_header_slice:
                raise Error(
                    "Quality Header is not the same as the Sequencing Header"
                )

    @always_inline
    fn validate_quality_schema(self, record: FastqRecord) raises:
        """Validate each quality byte is within schema LOWER..UPPER."""
        for i in range(len(record.QuStr)):
            if (
                record.QuStr[i] > self.quality_schema.UPPER
                or record.QuStr[i] < self.quality_schema.LOWER
            ):
                raise Error(
                    "Corrupt quality score according to provided schema"
                )

    @always_inline
    fn validate(self, record: FastqRecord) raises:
        """Run structure validation and, if check_quality, quality-schema validation."""
        self.validate_record(record)
        if self.check_quality:
            self.validate_quality_schema(record)


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
    validate_quality: Bool = False,
    origin: Origin[mut=True] = MutExternalOrigin
](Sized, Writable, Movable, Copyable):
    """Struct that represent coordinates of a FastqRecord in a chunk. Provides minimal validation of the record. Mainly used for fast parsing.
    """

    var SeqHeader: Span[Byte, Self.origin]
    var SeqStr: Span[Byte, Self.origin]
    var QuHeader: Span[Byte, Self.origin]
    var QuStr: Span[Byte, Self.origin]
    var quality_schema: QualitySchema


    fn __init__(
        out self,
        SeqHeader: Span[Byte, Self.origin],
        SeqStr: Span[Byte, Self.origin],
        QuHeader: Span[Byte, Self.origin],
        QuStr: Span[Byte, Self.origin],
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
    fn get_seq(self) -> StringSlice[origin = Self.origin]:
        return StringSlice[origin = Self.origin](unsafe_from_utf8=self.SeqStr)

    @always_inline
    fn get_quality(self) -> StringSlice[origin = Self.origin]:
        return StringSlice[origin = Self.origin](unsafe_from_utf8=self.QuStr)

    @always_inline
    fn get_header(self) -> StringSlice[origin = Self.origin]:
        return StringSlice[origin = Self.origin](unsafe_from_utf8=self.SeqHeader)

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
    fn get_quality_scores(
        self, quality_format: schema
    ) -> List[Byte]:
        if quality_format.isa[String]():
            schema = _parse_schema((quality_format[String]))
        else:
            schema = quality_format[QualitySchema]

        output = List[Byte](length=self.len_quality(), fill=0)
        for i in range(self.len_quality()):
            output[i] = self.QuStr[i] - schema.OFFSET
        return output^

    @always_inline
    fn get_quality_scores(
        self, offset: UInt8
    ) -> List[Byte]:
        output = List[Byte](length=self.len_quality(), fill=0)
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
        writer.write_string(StringSlice(unsafe_from_utf8=self.SeqHeader))
        writer.write("\n")
        writer.write_string(StringSlice(unsafe_from_utf8=self.SeqStr))
        writer.write("\n")
        writer.write_string(StringSlice(unsafe_from_utf8=self.QuHeader))
        writer.write("\n")
        writer.write_string(StringSlice(unsafe_from_utf8=self.QuStr))

