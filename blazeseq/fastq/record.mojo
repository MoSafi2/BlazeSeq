from hashlib.hasher import default_hasher, Hasher
from blazeseq.fastq.quality_schema import (
    QualitySchema,
    generic_schema,
)
from blazeseq.byte_string import BString
from blazeseq.fasta.definition import Definition
from blazeseq.utils import _check_ascii, _strip_spaces
from blazeseq.errors import (
    ValidationError,
    FastxErrorCode,
    format_validation_error_from_code,
)
from blazeseq.CONSTS import simd_width
from collections.string import StringSlice, String
from memory import Span
from blazeseq.io.writers import Writer


struct Validator(Copyable):
    """
    Validator for optional ASCII and quality checks on FASTQ records.

    Structure (@, +, seq/qual length) is validated in the parser hot loop; this
    validator only runs optional ASCII and quality-range checks when enabled via
    ParserConfig (check_ascii, check_quality). Used by FastqParser when those flags
    are True; can also be used standalone on FastqRecord or RefRecord.

    Attributes:
        check_ascii: If True, validate() requires all record bytes to be ASCII.
        check_quality: If True, validate() checks quality bytes against quality_schema.
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

    fn id_snippet(self, record: FastqRecord) -> String:
        """Extract id snippet from record for error messages."""
        var snippet = String(capacity=100)
        var id_str = record.id()
        if len(id_str) > 0:
            snippet += String(id_str)
            if len(snippet) > 100:
                snippet = snippet[:97] + "..."
        return snippet

    fn id_snippet(self, record: RefRecord) -> String:
        """Extract id snippet from RefRecord for error messages."""
        var snippet = String(capacity=100)
        var id_str = StringSlice(unsafe_from_utf8=record._id)
        if len(id_str) > 0:
            snippet += String(id_str)
            if len(snippet) > 100:
                snippet = snippet[:97] + "..."
        return snippet

    @always_inline
    fn _validate_quality_range(self, record: RefRecord) -> FastxErrorCode:
        """Validate each quality byte is within schema LOWER..UPPER. Returns OK or QUALITY_OUT_OF_RANGE.
        """
        var ptr = record._quality.unsafe_ptr()
        var n = len(record._quality)

        var lower = UInt8(self.quality_schema.LOWER)
        var span = UInt8(self.quality_schema.UPPER - self.quality_schema.LOWER)

        var lower_v = SIMD[DType.uint8, simd_width](lower)
        var span_v = SIMD[DType.uint8, simd_width](span)

        var i = 0
        while i + simd_width <= n:
            var chunk = ptr.load[width=simd_width](i)
            var mask = (chunk - lower_v).ge(
                span_v
            )  # Unsigned unsaturated substraction wraps on underflow.
            if mask.reduce_or():
                return FastxErrorCode.QUALITY_OUT_OF_RANGE
            i += simd_width

        while i < n:
            if (ptr[i] - lower) > span:
                return FastxErrorCode.QUALITY_OUT_OF_RANGE
            i += 1

        return FastxErrorCode.OK

    @always_inline
    fn _validate_ascii(self, record: RefRecord) -> FastxErrorCode:
        """Validate all record lines contain only ASCII bytes. Returns OK or ASCII_INVALID.
        """
        var c = _check_ascii(record._id)
        if c != FastxErrorCode.OK:
            return c
        c = _check_ascii(record._sequence)
        if c != FastxErrorCode.OK:
            return c
        return _check_ascii(record._quality)

    @always_inline
    fn _validate_quality_range(self, record: FastqRecord) -> FastxErrorCode:
        """Validate quality bytes using SIMD vectorization + unsigned range trick.
        """

        var ptr = record._quality.as_span().unsafe_ptr()
        var n = len(record._quality)

        # Precompute once: valid range is [lower, upper], span = upper - lower
        # The unsigned trick: (byte - lower) > span  <==>  byte < lower OR byte > upper
        var lower = UInt8(self.quality_schema.LOWER)
        var span = UInt8(self.quality_schema.UPPER - self.quality_schema.LOWER)

        var lower_v = SIMD[DType.uint8, simd_width](lower)
        var span_v = SIMD[DType.uint8, simd_width](span)

        var i = 0
        while i + simd_width <= n:
            var chunk = ptr.load[width=simd_width](i)
            # unsigned subtraction wraps on underflow — out-of-range bytes produce value > span
            var mask = (chunk - lower_v).ge(span_v)
            if mask.reduce_or():
                return FastxErrorCode.QUALITY_OUT_OF_RANGE
            i += simd_width

        while i < n:
            if (ptr[i] - lower) > span:
                return FastxErrorCode.QUALITY_OUT_OF_RANGE
            i += 1

        return FastxErrorCode.OK

    @always_inline
    fn _validate_ascii(self, record: FastqRecord) -> FastxErrorCode:
        """Validate all record lines contain only ASCII bytes. Returns OK or ASCII_INVALID.
        """
        var c = _check_ascii(record._id.as_span())
        if c != FastxErrorCode.OK:
            return c
        c = _check_ascii(record._sequence.as_span())
        if c != FastxErrorCode.OK:
            return c
        return _check_ascii(record._quality.as_span())

    @always_inline
    fn _validate(self, record: RefRecord) -> FastxErrorCode:
        """Run configured validations; returns error code. Used by parser hot path.
        """
        if self.check_ascii:
            var code = self._validate_ascii(record)
            if code != FastxErrorCode.OK:
                return code
        if self.check_quality:
            return self._validate_quality_range(record)
        return FastxErrorCode.OK

    @always_inline
    fn _validate(self, record: FastqRecord) -> FastxErrorCode:
        """Run configured validations; returns error code. Used by parser hot path.
        """
        if self.check_ascii:
            var code = self._validate_ascii(record)
            if code != FastxErrorCode.OK:
                return code
        if self.check_quality:
            return self._validate_quality_range(record)
        return FastxErrorCode.OK

    fn validate(
        self, record: FastqRecord, record_number: Int = 0, line_number: Int = 0
    ) raises:
        """Run configured validations (ASCII and/or quality) for a parsed FASTQ record.

        Structure is validated in the parser hot loop; here only check_ascii and
        check_quality are applied when enabled.

        Args:
            record: The FastqRecord to validate.
            record_number: Optional 1-indexed record number for error context (0 if unknown).
            line_number: Optional 1-indexed line number for error context (0 if unknown).
        """
        var code = self._validate(record)
        if code != FastxErrorCode.OK:
            raise Error(
                format_validation_error_from_code(
                    code, record_number, "", self.id_snippet(record)
                )
            )

    fn validate(
        self, record: RefRecord, record_number: Int = 0, line_number: Int = 0
    ) raises:
        """Run configured validations (ASCII and/or quality) for a parsed FASTQ record.

        Structure is validated in the parser hot loop; here only check_ascii and
        check_quality are applied when enabled.

        Args:
            record: The RefRecord to validate.
            record_number: Optional 1-indexed record number for error context (0 if unknown).
            line_number: Optional 1-indexed line number for error context (0 if unknown).
        """
        var code = self._validate(record)
        if code != FastxErrorCode.OK:
            raise Error(
                format_validation_error_from_code(
                    code, record_number, "", self.id_snippet(record)
                )
            )


# Add minimal internal validation, id start and length of quality and sequence.
struct FastqRecord(
    Copyable,
    Hashable,
    Movable,
    Sized,
    Writable,
):
    """A single FASTQ record (four lines: @id, sequence, +, quality).

    Owned representation; safe to store in collections and reuse. Use `RefRecord`
    for zero-copy parsing when consuming immediately. The plus line is emitted as "+"
    when writing; only id, sequence, and quality are stored. `phred_offset` is the
    Phred offset (33 or 64) used to decode quality scores.

    Attributes:
        id: Read identifier (id line content after the '@'; stored without leading '@').
        sequence: Sequence line.
        quality: Quality line (same length as sequence).
        phred_offset: Phred offset for `phred_scores()` (e.g. 33 for Sanger).

    Example:
        ```mojo
        from blazeseq import FastqRecord
        from blazeseq.fastq.quality_schema import generic_schema
        var rec = FastqRecord("read1", "ACGT", "IIII", generic_schema)
        print(rec.id())
        var scores = rec.phred_scores()
        ```
    """

    var _id: BString
    var _sequence: BString
    var _quality: BString
    var _phred_offset: Int8

    @always_inline
    fn __init__(
        out self,
        id: String,
        sequence: String,
        quality: String,
        schema: QualitySchema = generic_schema,
    ) raises:
        """Build from id, sequence, and quality strings; phred_offset from schema (default generic_schema).
        """
        self._id = BString(id)
        self._sequence = BString(sequence)
        self._quality = BString(quality)
        self._phred_offset = Int8(schema.OFFSET)

    @always_inline
    fn __init__(
        out self,
        id: Span[Byte, MutExternalOrigin],
        sequence: Span[Byte, MutExternalOrigin],
        quality: Span[Byte, MutExternalOrigin],
        phred_offset: Int8 = 33,
    ) raises:
        self._id = BString(id)
        self._sequence = BString(sequence)
        self._quality = BString(quality)
        self._phred_offset = phred_offset

    fn __init__(out self, fast_str: String) raises:
        """Build from a single string containing four newline-separated lines (line 3, plus line, is discarded).
        """
        var seqs = fast_str.strip().split("\n")
        if len(seqs) > 4:
            raise Error("Sequence does not seem to be valid")

        self._id = BString(String(seqs[0].strip()))
        self._sequence = BString(String(seqs[1].strip()))
        self._quality = BString(String(seqs[3].strip()))
        self._phred_offset = 33

    fn __init__(
        out self,
        var id: BString,
        var sequence: BString,
        var quality: BString,
        phred_offset: Int8,
    ):
        self._id = id^
        self._sequence = sequence^
        self._quality = quality^
        self._phred_offset = phred_offset

    @always_inline
    fn sequence(ref [_]self) -> StringSlice[origin = origin_of(self)]:
        """Return the sequence line as a string slice."""
        var span = Span[Byte, origin_of(self)](
            ptr=self._sequence.ptr.unsafe_mut_cast[
                origin_of(self).mut
            ]().unsafe_origin_cast[origin_of(self)](),
            length=len(self._sequence),
        )
        return StringSlice[origin = origin_of(self)](unsafe_from_utf8=span)

    @always_inline
    fn quality(ref [_]self) -> StringSlice[origin = origin_of(self)]:
        """Return the quality line (raw ASCII bytes) as a string slice."""
        var span = Span[Byte, origin_of(self)](
            ptr=self._quality.ptr.unsafe_mut_cast[
                origin_of(self).mut
            ]().unsafe_origin_cast[origin_of(self)](),
            length=len(self._quality),
        )
        return StringSlice[origin = origin_of(self)](unsafe_from_utf8=span)

    @always_inline
    fn phred_scores(self) -> List[UInt8]:
        """Return Phred quality scores using the record's phred_offset (e.g. 33).
        """
        output = List[UInt8](length=len(self._quality), fill=0)
        for i in range(len(self._quality)):
            output[i] = self._quality[i] - UInt8(self._phred_offset)
        return output^

    @always_inline
    fn phred_scores(self, offset: UInt8) -> List[UInt8]:
        """Return Phred quality scores using the given offset (e.g. 33 or 64).
        """
        output = List[UInt8](length=len(self._quality), fill=0)
        for i in range(len(self._quality)):
            output[i] = self._quality[i] - offset
        return output^

    @always_inline
    fn id(ref [_]self) -> StringSlice[origin = origin_of(self)]:
        """Return the read identifier (id without leading '@') as a string slice.
        """
        var span = Span[Byte, origin_of(self)](
            ptr=self._id.ptr.unsafe_mut_cast[
                origin_of(self).mut
            ]().unsafe_origin_cast[origin_of(self)](),
            length=len(self._id),
        )
        return StringSlice[origin = origin_of(self)](unsafe_from_utf8=span)

    fn definition(ref self) -> Definition:
        """Return Id and optional Description parsed from the id line (first token vs rest)."""
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
        """Return total byte length when written ("@" + id + sequence + quality + "+\n")."""
        return 1 + len(self._id) + len(self._sequence) + len(self._quality) + 5

    @always_inline
    fn __str__(self) -> String:
        return String.write(self)

    fn write[w: Writer](self, mut writer: w):
        """Write the record in standard four-line FASTQ format to writer (emits "@" before id and "+" for the plus line).
        """
        writer.write("@")
        writer.write(
            self._id.to_string(),
            "\n",
            self._sequence.to_string(),
            "\n",
            "+\n",
            self._quality.to_string(),
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


@align(64)
struct RefRecord[mut: Bool, //, origin: Origin[mut=mut]](
    ImplicitlyDestructible, Movable, Sized, Writable, TrivialRegisterPassable
):
    """Zero-copy reference to a FASTQ record inside the parser's buffer.

    Lifetime: Valid only until the next parser read or buffer mutation. Do not
    store in collections (e.g. `List`); consume or copy to `FastqRecord` promptly.
    Not thread-safe. Use for maximum parsing throughput when processing
    immediately; use `FastqRecord` when you need to store or reuse records.

    Attributes:
        id, sequence, quality: Spans into the parser buffer (id is identifier without leading '@').
        phred_offset: Phred offset (33 or 64) for quality decoding.

    Example:
        ```mojo
        from blazeseq import FastqParser, FileReader
        from pathlib import Path
        var parser = FastqParser[FileReader](FileReader(Path("data.fastq")), "generic")
        for record_ref in parser.ref_records():
            _ = record_ref.id()
            _ = record_ref.sequence()
        ```
    """

    var _id: Span[Byte, Self.origin]
    var _sequence: Span[Byte, Self.origin]
    var _quality: Span[Byte, Self.origin]
    var _phred_offset: UInt8

    fn __init__(
        out self,
        id: Span[Byte, Self.origin],
        sequence: Span[Byte, Self.origin],
        quality: Span[Byte, Self.origin],
        phred_offset: UInt8 = 33,
    ):
        self._id = id
        self._sequence = sequence
        self._quality = quality
        self._phred_offset = phred_offset

    @always_inline
    fn sequence(self) -> StringSlice[origin = Self.origin]:
        """Return the sequence line as a string slice (valid only while ref is valid).
        """
        return StringSlice[origin = Self.origin](
            unsafe_from_utf8=self._sequence
        )

    @always_inline
    fn quality(self) -> StringSlice[origin = Self.origin]:
        """Return the quality line as a string slice (valid only while ref is valid).
        """
        return StringSlice[origin = Self.origin](unsafe_from_utf8=self._quality)

    @always_inline
    fn id(self) -> StringSlice[origin = Self.origin]:
        """Return the read identifier (id without leading '@') as a string slice (valid only while ref is valid).
        """
        return StringSlice[origin = Self.origin](unsafe_from_utf8=self._id)

    fn definition(self) -> Definition:
        """Return Id and optional Description parsed from the id line (first token vs rest)."""
        var id_str = StringSlice(unsafe_from_utf8=self._id)
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
    fn __len__(self) -> Int:
        """Return the sequence length (number of bases)."""
        return len(self._sequence)

    @always_inline
    fn byte_len(self) -> Int:
        """Return total byte length when written ("@" + id + sequence + quality + newlines and "+\n"). Used for calculating buffer capacity."""
        return 1 + len(self._id) + len(self._sequence) + len(self._quality) + 5

    @always_inline
    fn phred_scores(self) -> List[Byte]:
        """Return Phred quality scores using the record's phred_offset."""
        output = List[Byte](length=len(self._quality), fill=0)
        for i in range(len(self._quality)):
            output[i] = self._quality[i] - UInt8(self._phred_offset)
        return output^

    @always_inline
    fn phred_scores(self, offset: UInt8) -> List[Byte]:
        """Return Phred quality scores using the given offset (e.g. 33 or 64).
        """
        output = List[Byte](length=len(self._quality), fill=0)
        for i in range(len(self._quality)):
            output[i] = self._quality[i] - offset
        return output^

    fn write[w: Writer](self, mut writer: w):
        """Write the record in standard four-line FASTQ format to writer (emits "@" before id and "+" for the plus line).
        """
        writer.write("@")
        writer.write_string(StringSlice(unsafe_from_utf8=self._id))
        writer.write("\n")
        writer.write_string(StringSlice(unsafe_from_utf8=self._sequence))
        writer.write("\n")
        writer.write("+\n")
        writer.write_string(StringSlice(unsafe_from_utf8=self._quality))
        writer.write("\n")

    @always_inline
    fn write_to[w: Writer](self, mut writer: w):
        """Required by Writable trait; delegates to write()."""
        self.write(writer)
