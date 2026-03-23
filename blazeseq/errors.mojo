"""Custom error types for BlazeSeq with contextual information.

Public API:
- FastxErrorCode: trivial enum for hot-path returns (no raise)
- ParseError, ValidationError: structs with message and context
- format_parse_error_from_code, format_validation_error_from_code: build error strings from codes
- buffer_capacity_error: build buffer-capacity message for callers that raise Error(...)
"""

# ---------------------------------------------------------------------------
# FastxErrorCode: trivial enum for hot-path error returns (no raise)
# ---------------------------------------------------------------------------


struct FastxErrorCode(Copyable, Equatable, TrivialRegisterPassable):
    """Trivial error code returned by low-level parsing/validation; caller builds and raises.
    """

    var value: Int8

    @always_inline
    def __init__(out self, value: Int8):
        self.value = value

    comptime OK = Self(0)
    # Parse structure (_validate_fastq_structure)
    comptime ID_NO_AT = Self(1)
    comptime SEP_NO_PLUS = Self(2)
    comptime SEQ_QUAL_LEN_MISMATCH = Self(3)
    # Validation
    comptime ASCII_INVALID = Self(4)
    comptime QUALITY_OUT_OF_RANGE = Self(5)
    # Refill / EOF
    comptime EOF = Self(6)
    comptime UNEXPECTED_EOF = Self(7)
    comptime BUFFER_EXCEEDED = Self(8)
    comptime BUFFER_AT_MAX = Self(9)
    comptime OTHER = Self(10)

    @always_inline
    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    @always_inline
    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value


def _message_for_code(code: FastxErrorCode) -> String:
    """Internal: return default message for a FastxErrorCode. Used when building ParseError/ValidationError.
    """
    if code == FastxErrorCode.ID_NO_AT:
        return "Sequence id line does not start with '@'"
    if code == FastxErrorCode.SEP_NO_PLUS:
        return "Separator line does not start with '+'"
    if code == FastxErrorCode.SEQ_QUAL_LEN_MISMATCH:
        return "Quality and sequence line do not match in length"
    if code == FastxErrorCode.ASCII_INVALID:
        return "Non ASCII letters found"
    if code == FastxErrorCode.QUALITY_OUT_OF_RANGE:
        return "Corrupt quality score according to provided schema"
    if code == FastxErrorCode.UNEXPECTED_EOF:
        return "Unexpected end of file in FASTQ record"
    if code == FastxErrorCode.BUFFER_EXCEEDED:
        return "FASTQ record exceeds buffer capacity"
    if code == FastxErrorCode.BUFFER_AT_MAX:
        return "FASTQ record exceeds maximum buffer capacity"
    return "Parse or validation error"


def format_parse_error_from_code(
    code: FastxErrorCode,
    record_number: Int,
    line_number: Int,
    file_position: Int64,
    record_snippet: String = "",
) -> String:
    """Build full ParseError string from error code and context (cold path).

    Returns the full formatted error string, including contextual lines such as
    "Record number", "Line number", "File position", and "Record snippet" when
    that information is available. This is used by callers that raise
    `Error(String)` so that `String(Error)` already contains rich context.
    """
    var parse_err = ParseError(
        _message_for_code(code),
        record_number=record_number,
        line_number=line_number,
        file_position=file_position,
        record_snippet=record_snippet,
    )
    # Use the Writable implementation to build the complete message with
    # contextual fields, instead of returning only the base message.
    return String(parse_err)


def format_validation_error_from_code(
    code: FastxErrorCode,
    record_number: Int,
    field: String = "",
    record_snippet: String = "",
) -> String:
    """Build full ValidationError string from error code and context (cold path).

    Returns the full formatted error string, including contextual lines such as
    "Record number", "Field", and "Record snippet" when that information is
    available.
    """
    var field_name = field
    if len(field_name) == 0 and code == FastxErrorCode.ASCII_INVALID:
        field_name = "ascii"
    elif len(field_name) == 0 and code == FastxErrorCode.QUALITY_OUT_OF_RANGE:
        field_name = "quality"
    var val_err = ValidationError(
        _message_for_code(code),
        record_number=record_number,
        field=field_name,
        record_snippet=record_snippet,
    )
    return String(val_err)


struct ParseError(Writable):
    """Error raised during FASTQ parsing with contextual information."""

    var message: String
    var record_number: Int  # 1-indexed record number
    var line_number: Int  # 1-indexed line number in file
    var file_position: Int64  # Byte position in file
    var record_snippet: String  # First 100-200 chars of problematic record

    def __init__(
        out self,
        message: String,
        record_number: Int = 0,
        line_number: Int = 0,
        file_position: Int64 = 0,
        record_snippet: String = "",
    ):
        """Initialize ParseError with message and optional context.

        Args:
            message: The error message.
            record_number: 1-indexed record number where error occurred (0 if unknown).
            line_number: 1-indexed line number in file (0 if unknown).
            file_position: Byte position in file (0 if unknown).
            record_snippet: First 100-200 chars of problematic record (empty if unavailable).
        """
        self.message = message
        self.record_number = record_number
        self.line_number = line_number
        self.file_position = file_position
        self.record_snippet = record_snippet


    def write_to[w: Writer](self, mut writer: w):
        """Write error to writer without building an intermediate String."""
        writer.write(self.message)
        if self.record_number > 0:
            writer.write("\n  Record number: ")
            writer.write(self.record_number)
        if self.line_number > 0:
            writer.write("\n  Line number: ")
            writer.write(self.line_number)
        if self.file_position > 0:
            writer.write("\n  File position: ")
            writer.write(self.file_position)
        if len(self.record_snippet) > 0:
            writer.write("\n  Record snippet: ")
            writer.write(self.record_snippet)


struct ValidationError(Writable):
    """Error raised during FASTQ record validation."""

    var message: String
    var record_number: Int
    var field: String  # "header", "sequence", "quality", etc.
    var record_snippet: String

    def __init__(
        out self,
        message: String,
        record_number: Int = 0,
        field: String = "",
        record_snippet: String = "",
    ):
        """Initialize ValidationError with message and optional context.

        Args:
            message: The error message.
            record_number: 1-indexed record number where error occurred (0 if unknown).
            field: Field name where validation failed (e.g., "header", "sequence", "quality").
            record_snippet: First 100-200 chars of problematic record (empty if unavailable).
        """
        self.message = message
        self.record_number = record_number
        self.field = field
        self.record_snippet = record_snippet

    def write_to[w: Writer](self, mut writer: w):
        """Write error to writer without building an intermediate String."""
        writer.write(self.message)
        if self.record_number > 0:
            writer.write("\n  Record number: ")
            writer.write(self.record_number)
        if len(self.field) > 0:
            writer.write("\n  Field: ")
            writer.write(self.field)
        if len(self.record_snippet) > 0:
            writer.write("\n  Record snippet: ")
            writer.write(self.record_snippet)


# ---------------------------------------------------------------------------
# Shared error message helpers (for consistent Error strings across modules)
# ---------------------------------------------------------------------------


def buffer_capacity_error(
    capacity: Int,
    max_capacity: Int = 0,
    growth_hint: Bool = False,
    at_max: Bool = False,
) -> String:
    """Build a single "line exceeds buffer" message for use by LineIterator and parser/utils.

    Args:
        capacity: Current buffer capacity in bytes.
        max_capacity: Maximum buffer capacity when growth is enabled (0 if N/A).
        growth_hint: If True, append hint to enable buffer_growth or use larger buffer_capacity.
        at_max: If True and max_capacity > 0, message is about exceeding max capacity.

    Returns:
        A string suitable for raise Error(...).
    """
    var msg: String
    if at_max and max_capacity > 0:
        msg = (
            "Line exceeds max buffer capacity of "
            + String(max_capacity)
            + " bytes"
        )
    else:
        msg = "Line exceeds buffer capacity of " + String(capacity) + " bytes"
    if growth_hint:
        msg += ". Enable buffer_growth or use a larger buffer_capacity."
    return msg
