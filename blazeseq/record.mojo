from hashlib.hasher import default_hasher, Hasher
from blazeseq.quality_schema import (
    QualitySchema,
    generic_schema,
)
from blazeseq.ascii_string import ASCIIString
from blazeseq.utils import _check_ascii
from blazeseq.errors import ValidationError

comptime read_header = ord("@")
comptime quality_header = ord("+")
comptime new_line = ord("\n")
comptime carriage_return = ord("\r")


# Add minimal internal validation, header start and length of quality and sequence.
struct FastqRecord(
    Copyable,
    Hashable,
    Movable,
    Representable,
    Sized,
    Writable,
):
    """A single FASTQ record (four lines: @id, sequence, +, quality).

    Owned representation; safe to store in collections and reuse. Use `RefRecord`
    for zero-copy parsing when consuming immediately. `quality_offset` is the
    Phred offset (33 or 64) used to decode quality scores.

    Attributes:
        header: Line starting with '@' (read identifier).
        sequence: Sequence line.
        plus_line: Line starting with '+' (optional repeat of id).
        quality: Quality line (same length as sequence).
        phred_offset: Phred offset for `phred_scores()` (e.g. 33 for Sanger).

    Example:
        ```mojo
        from blazeseq import FastqRecord
        from blazeseq.quality_schema import generic_schema
        var rec = FastqRecord("@read1", "ACGT", "+", "IIII", generic_schema)
        print(rec.header_slice())
        var scores = rec.phred_scores()
        ```
    """

    var header: ASCIIString
    var sequence: ASCIIString
    var plus_line: ASCIIString
    var quality: ASCIIString
    var phred_offset: Int8

    @always_inline
    fn __init__(
        out self,
        seq_header: String,
        seq_str: String,
        qu_header: String,
        qu_str: String,
        schema: QualitySchema = generic_schema,
    ) raises:
        """Build from four string lines; phred_offset from schema (default generic_schema)."""
        self.header = ASCIIString(seq_header)
        self.sequence = ASCIIString(seq_str)
        self.plus_line = ASCIIString(qu_header)
        self.quality = ASCIIString(qu_str)
        self.phred_offset = Int8(schema.OFFSET)

    @always_inline
    fn __init__(
        out self,
        header_span: Span[Byte, MutExternalOrigin],
        seq_span: Span[Byte, MutExternalOrigin],
        plus_line_span: Span[Byte, MutExternalOrigin],
        quality_span: Span[Byte, MutExternalOrigin],
        quality_offset: Int8 = 33,
    ) raises:
        self.header = ASCIIString(header_span)
        self.plus_line = ASCIIString(plus_line_span)
        self.sequence = ASCIIString(seq_span)
        self.quality = ASCIIString(quality_span)
        self.phred_offset = quality_offset

    fn __init__(out self, sequence: String) raises:
        """Build from a single string containing four newline-separated lines.
        """
        var seqs = sequence.strip().split("\n")
        if len(seqs) > 4:
            raise Error("Sequence does not seem to be valid")

        self.header = ASCIIString(String(seqs[0].strip()))
        self.sequence = ASCIIString(String(seqs[1].strip()))
        self.plus_line = ASCIIString(String(seqs[2].strip()))
        self.quality = ASCIIString(String(seqs[3].strip()))
        self.phred_offset = 33

    fn __init__(
        out self,
        var seq_header: ASCIIString,
        var seq_str: ASCIIString,
        var qu_header: ASCIIString,
        var qu_str: ASCIIString,
        quality_offset: Int8,
    ):
        self.header = seq_header^
        self.sequence = seq_str^
        self.plus_line = qu_header^
        self.quality = qu_str^
        self.phred_offset = quality_offset

    fn __init__(
        out self,
        var seq_header: ASCIIString,
        var seq_str: ASCIIString,
        var qu_header: ASCIIString,
        var qu_str: ASCIIString,
        schema: QualitySchema = generic_schema,
    ):
        self.header = seq_header^
        self.sequence = seq_str^
        self.plus_line = qu_header^
        self.quality = qu_str^
        self.phred_offset = Int8(schema.OFFSET)

    @always_inline
    fn sequence_slice(self) -> StringSlice[MutExternalOrigin]:
        """Return the sequence line as a string slice."""
        return self.sequence.as_string_slice()

    @always_inline
    fn quality_slice(self) -> StringSlice[MutExternalOrigin]:
        """Return the quality line (raw ASCII bytes) as a string slice."""
        return self.quality.as_string_slice()

    @always_inline
    fn phred_scores(self) -> List[UInt8]:
        """Return Phred quality scores using the record's phred_offset (e.g. 33).
        """
        output = List[UInt8](length=len(self.quality), fill=0)
        for i in range(len(self.quality)):
            output[i] = self.quality[i] - UInt8(self.phred_offset)
        return output^

    @always_inline
    fn phred_scores(self, offset: UInt8) -> List[UInt8]:
        """Return Phred quality scores using the given offset (e.g. 33 or 64).
        """
        output = List[UInt8](length=len(self.quality), fill=0)
        for i in range(len(self.quality)):
            output[i] = self.quality[i] - offset
        return output^

    @always_inline
    fn header_slice(self) -> StringSlice[MutExternalOrigin]:
        """Return the @-line (read identifier) as a string slice."""
        return self.header.as_string_slice()

    @always_inline
    fn byte_len(self) -> Int:
        """Return total byte length of all four lines (headers + sequence + quality).
        """
        return (
            len(self.plus_line)
            + len(self.quality)
            + len(self.header)
            + len(self.sequence)
        )

    @always_inline
    fn __str__(self) -> String:
        return String.write(self)

    fn write[w: Writer](self, mut writer: w):
        """Write the record in standard four-line FASTQ format to writer."""
        writer.write(
            self.header.to_string(),
            "\n",
            self.sequence.to_string(),
            "\n",
            self.plus_line.to_string(),
            "\n",
            self.quality.to_string(),
            "\n",
        )

    @always_inline
    fn write_to[w: Writer](self, mut writer: w):
        """Required by Writable trait; delegates to write()."""
        self.write(writer)

    @always_inline
    fn __len__(self) -> Int:
        """Return the sequence length (number of bases)."""
        return len(self.sequence)

    @always_inline
    fn __hash__[H: Hasher](self, mut hasher: H):
        hasher.update(self.sequence.as_string_slice())

    @always_inline
    fn __eq__(self, other: Self) -> Bool:
        return self.sequence == other.sequence

    fn __ne__(self, other: Self) -> Bool:
        return not self.__eq__(other)

    fn __repr__(self) -> String:
        return self.__str__()


# ---------------------------------------------------------------------------
# Validator: FASTQ record validation, instantiable from ParserConfig
# ---------------------------------------------------------------------------


struct Validator(Copyable):
    """
    Validator for FASTQ record structure and optional ASCII/quality checks.

    Used by FastqParser when check_ascii/check_quality are True. Can also be
    used standalone to validate FastqRecord or RefRecord. validate() runs
    structure checks plus optional ASCII and quality-range checks.

    Attributes:
        check_ascii: If True, validate_structure and validate() also require ASCII bytes.
        check_quality: If True, validate() also checks quality bytes against quality_schema.
        quality_schema: Bounds (LOWER, UPPER) and OFFSET for quality validation.
    """

    var check_ascii: Bool
    var check_quality: Bool
    var quality_schema: QualitySchema

    fn __init__(
        out self,
        check_ascii: Bool,
        check_quality: Bool,
        quality_schema: QualitySchema,
    ):
        """Initialize Validator with ASCII/quality flags and quality schema.

        Args:
            check_ascii: If True, validate() will reject non-ASCII bytes in records.
            check_quality: If True, validate() will check quality bytes against schema.
            quality_schema: Schema used for quality validation (e.g. from `_parse_schema`).
        """
        self.check_ascii = check_ascii
        self.check_quality = check_quality
        self.quality_schema = quality_schema.copy()

    @always_inline
    fn validate_structure(
        self, record: FastqRecord, record_number: Int = 0, line_number: Int = 0
    ) raises:
        """Validate record structure: @ header, + header, seq/qual length, optional header match.

        Args:
            record: The `FastqRecord` to validate.
            record_number: Optional 1-indexed record number for error context (0 if unknown).
            line_number: Optional 1-indexed line number for error context (0 if unknown).
        """
        if len(record.header) == 0 or record.header[0] != UInt8(read_header):
            raise Error("Sequence header does not start with '@'")

        if len(record.plus_line) == 0 or record.plus_line[0] != UInt8(quality_header):
            raise Error("Plus line does not start with '+'")

        if len(record.sequence) != len(record.quality):
            raise Error(
                "Quality and sequence string do not match in length"
            )

        if len(record.plus_line) > 1:
            if len(record.plus_line) != len(record.header):
                raise Error(
                    "Plus line is not the same length as the header"
                )

            var plus_slice = record.plus_line.as_string_slice()[1:]
            var header_slice = record.header.as_string_slice()[1:]
            if plus_slice != header_slice:
                raise Error(
                    "Plus line is not the same as the header"
                )

    @always_inline
    fn validate_structure(
        self, record: RefRecord, record_number: Int = 0, line_number: Int = 0
    ) raises:
        """Validate record structure: @ header, + header, seq/qual length, optional header match.

        Args:
            record: The `RefRecord` to validate.
            record_number: Optional 1-indexed record number for error context (0 if unknown).
            line_number: Optional 1-indexed line number for error context (0 if unknown).
        """
        if len(record.header) == 0 or record.header[0] != UInt8(read_header):
            raise Error("Sequence header does not start with '@'")

        if len(record.plus_line) == 0 or record.plus_line[0] != UInt8(quality_header):
            raise Error("Plus line does not start with '+'")

        if len(record.sequence) != len(record.quality):
            raise Error(
                "Quality and sequence string do not match in length"
            )

        if len(record.plus_line) > 1:
            if len(record.plus_line) != len(record.header):
                raise Error(
                    "Plus line is not the same length as the header"
                )

            var plus_slice = StringSlice(unsafe_from_utf8=record.plus_line)[
                1:
            ]
            var header_slice = StringSlice(
                unsafe_from_utf8=record.header
            )[1:]
            if plus_slice != header_slice:
                raise Error(
                    "Plus line is not the same as the header"
                )

    fn header_snippet(self, record: FastqRecord) -> String:
        """Extract header snippet from record for error messages."""
        var snippet = String(capacity=100)
        var header_str = record.header_slice()
        if len(header_str) > 0:
            snippet += String(header_str)
            if len(snippet) > 100:
                snippet = snippet[:97] + "..."
        return snippet

    fn header_snippet(self, record: RefRecord) -> String:
        """Extract header snippet from RefRecord for error messages."""
        var snippet = String(capacity=100)
        var header_str = StringSlice(unsafe_from_utf8=record.header)
        if len(header_str) > 0:
            snippet += String(header_str)
            if len(snippet) > 100:
                snippet = snippet[:97] + "..."
        return snippet

    @always_inline
    fn validate_quality_range(self, record: RefRecord) raises:
        """Validate each quality byte is within schema LOWER..UPPER.

        Raises:
            Error: If any quality byte is outside the schema range.
        """
        for i in range(len(record.quality)):
            if (
                record.quality[i] > self.quality_schema.UPPER
                or record.quality[i] < self.quality_schema.LOWER
            ):
                raise Error(
                    "Corrupt quality score according to provided schema"
                )

    @always_inline
    fn validate_ascii(self, record: RefRecord) raises:
        """Validate all record lines contain only ASCII bytes (0x20-0x7E).

        Raises:
            Error: If any non-ASCII byte is found.
        """
        _check_ascii(record.header)
        _check_ascii(record.sequence)
        _check_ascii(record.plus_line)
        _check_ascii(record.quality)

    # TODO: Convert to SIMD accelerated version
    @always_inline
    fn validate_quality_range(self, record: FastqRecord) raises:
        """Validate each quality byte is within schema LOWER..UPPER.

        Raises:
            Error: If any quality byte is outside the schema range.
        """
        for i in range(len(record.quality)):
            if (
                record.quality[i] > self.quality_schema.UPPER
                or record.quality[i] < self.quality_schema.LOWER
            ):
                raise Error(
                    "Corrupt quality score according to provided schema"
                )

    @always_inline
    fn validate_ascii(self, record: FastqRecord) raises:
        """Validate all record lines contain only ASCII bytes (0x20-0x7E).

        Raises:
            Error: If any non-ASCII byte is found.
        """
        _check_ascii(record.header.as_span())
        _check_ascii(record.sequence.as_span())
        _check_ascii(record.plus_line.as_span())
        _check_ascii(record.quality.as_span())

    @always_inline
    fn validate(
        self, record: FastqRecord, record_number: Int = 0, line_number: Int = 0
    ) raises:
        """Run configured validations for a parsed FASTQ record.

        Args:
            record: The FastqRecord to validate.
            record_number: Optional 1-indexed record number for error context (0 if unknown).
            line_number: Optional 1-indexed line number for error context (0 if unknown).
        """
        try:
            self.validate_structure(record, record_number, line_number)
        except e:
            if record_number > 0:
                var val_err = ValidationError(
                    String(e),
                    record_number=record_number,
                    field="record",
                    record_snippet=self.header_snippet(record),
                )
                raise Error(val_err.__str__())
            raise
        if self.check_ascii:
            try:
                self.validate_ascii(record)
            except e:
                if record_number > 0:
                    var val_err = ValidationError(
                        String(e),
                        record_number=record_number,
                        field="ascii",
                        record_snippet=self.header_snippet(record),
                    )
                    raise Error(val_err.__str__())
                raise
        if self.check_quality:
            try:
                self.validate_quality_range(record)
            except e:
                if record_number > 0:
                    var val_err = ValidationError(
                        String(e),
                        record_number=record_number,
                        field="quality",
                        record_snippet=self.header_snippet(record),
                    )
                    raise Error(val_err.__str__())
                raise

    @always_inline
    fn validate(
        self, record: RefRecord, record_number: Int = 0, line_number: Int = 0
    ) raises:
        """Run configured validations for a parsed FASTQ record.

        Args:
            record: The RefRecord to validate.
            record_number: Optional 1-indexed record number for error context (0 if unknown).
            line_number: Optional 1-indexed line number for error context (0 if unknown).
        """
        try:
            self.validate_structure(record, record_number, line_number)
        except e:
            if record_number > 0:
                var val_err = ValidationError(
                    String(e),
                    record_number=record_number,
                    field="record",
                    record_snippet=self.header_snippet(record),
                )
                raise Error(val_err.__str__())
            raise
        if self.check_ascii:
            try:
                self.validate_ascii(record)
            except e:
                if record_number > 0:
                    var val_err = ValidationError(
                        String(e),
                        record_number=record_number,
                        field="ascii",
                        record_snippet=self.header_snippet(record),
                    )
                    raise Error(val_err.__str__())
                raise
        if self.check_quality:
            try:
                self.validate_quality_range(record)
            except e:
                if record_number > 0:
                    var val_err = ValidationError(
                        String(e),
                        record_number=record_number,
                        field="quality",
                        record_snippet=self.header_snippet(record),
                    )
                    raise Error(val_err.__str__())
                raise


struct RefRecord[mut: Bool, //, origin: Origin[mut=mut]](
    ImplicitlyDestructible, Movable, Sized, Writable
):
    """Zero-copy reference to a FASTQ record inside the parser's buffer.

    Lifetime: Valid only until the next parser read or buffer mutation. Do not
    store in collections (e.g. `List`); consume or copy to `FastqRecord` promptly.
    Not thread-safe. Use for maximum parsing throughput when processing
    immediately; use `FastqRecord` when you need to store or reuse records.

    Attributes:
        header, sequence, plus_line, quality: Spans into the parser buffer.
        phred_offset: Phred offset (33 or 64) for quality decoding.

    Example:
        ```mojo
        from blazeseq import FastqParser, FileReader
        from pathlib import Path
        var parser = FastqParser[FileReader](FileReader(Path("data.fastq")), "generic")
        for record_ref in parser.ref_records():
            _ = record_ref.header_slice()
            _ = record_ref.sequence_slice()
        ```
    """

    var header: Span[Byte, Self.origin]
    var sequence: Span[Byte, Self.origin]
    var plus_line: Span[Byte, Self.origin]
    var quality: Span[Byte, Self.origin]
    var phred_offset: Int8

    fn __init__(
        out self,
        header_span: Span[Byte, Self.origin],
        seq_span: Span[Byte, Self.origin],
        plus_line_span: Span[Byte, Self.origin],
        quality_span: Span[Byte, Self.origin],
        quality_offset: Int8 = 33,
    ):
        self.header = header_span
        self.sequence = seq_span
        self.plus_line = plus_line_span
        self.quality = quality_span
        self.phred_offset = quality_offset

    @always_inline
    fn sequence_slice(self) -> StringSlice[origin = Self.origin]:
        """Return the sequence line as a string slice (valid only while ref is valid).
        """
        return StringSlice[origin = Self.origin](unsafe_from_utf8=self.sequence)

    @always_inline
    fn quality_slice(self) -> StringSlice[origin = Self.origin]:
        """Return the quality line as a string slice (valid only while ref is valid).
        """
        return StringSlice[origin = Self.origin](unsafe_from_utf8=self.quality)

    @always_inline
    fn header_slice(self) -> StringSlice[origin = Self.origin]:
        """Return the @-line (read id) as a string slice (valid only while ref is valid).
        """
        return StringSlice[origin = Self.origin](
            unsafe_from_utf8=self.header
        )

    @always_inline
    fn __len__(self) -> Int:
        """Return the sequence length (number of bases)."""
        return len(self.sequence)

    @always_inline
    fn byte_len(self) -> Int:
        """Return total byte length of all four lines."""
        return (
            len(self.header)
            + len(self.sequence)
            + len(self.plus_line)
            + len(self.quality)
        )

    @always_inline
    fn phred_scores(self) -> List[Byte]:
        """Return Phred quality scores using the record's phred_offset."""
        output = List[Byte](length=len(self.quality), fill=0)
        for i in range(len(self.quality)):
            output[i] = self.quality[i] - UInt8(self.phred_offset)
        return output^

    @always_inline
    fn phred_scores(self, offset: UInt8) -> List[Byte]:
        """Return Phred quality scores using the given offset (e.g. 33 or 64).
        """
        output = List[Byte](length=len(self.quality), fill=0)
        for i in range(len(self.quality)):
            output[i] = self.quality[i] - offset
        return output^

    fn write[w: Writer](self, mut writer: w):
        """Write the record in standard four-line FASTQ format to writer."""
        writer.write_string(StringSlice(unsafe_from_utf8=self.header))
        writer.write("\n")
        writer.write_string(StringSlice(unsafe_from_utf8=self.sequence))
        writer.write("\n")
        writer.write_string(StringSlice(unsafe_from_utf8=self.plus_line))
        writer.write("\n")
        writer.write_string(StringSlice(unsafe_from_utf8=self.quality))
        writer.write("\n")

    @always_inline
    fn write_to[w: Writer](self, mut writer: w):
        """Required by Writable trait; delegates to write()."""
        self.write(writer)
