"""Custom error types for BlazeSeq with contextual information."""

struct ParseError(Writable):
    """Error raised during FASTQ parsing with contextual information."""
    
    var message: String
    var record_number: Int  # 1-indexed record number
    var line_number: Int    # 1-indexed line number in file
    var file_position: Int64 # Byte position in file
    var record_snippet: String  # First 100-200 chars of problematic record
    
    fn __init__(
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
    
    fn __str__(self) -> String:
        """Format error message with context."""
        var msg = self.message
        if self.record_number > 0:
            msg += "\n  Record number: " + String(self.record_number)
        if self.line_number > 0:
            msg += "\n  Line number: " + String(self.line_number)
        if self.file_position > 0:
            msg += "\n  File position: " + String(self.file_position)
        if len(self.record_snippet) > 0:
            msg += "\n  Record snippet: " + self.record_snippet
        return msg
    
    fn write_to[w: Writer](self, mut writer: w):
        """Write error to writer."""
        writer.write(self.__str__())


struct ValidationError(Writable):
    """Error raised during FASTQ record validation."""
    
    var message: String
    var record_number: Int
    var field: String  # "header", "sequence", "quality", etc.
    var record_snippet: String
    
    fn __init__(
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
    
    fn __str__(self) -> String:
        """Format error message with context."""
        var msg = self.message
        if self.record_number > 0:
            msg += "\n  Record number: " + String(self.record_number)
        if len(self.field) > 0:
            msg += "\n  Field: " + self.field
        if len(self.record_snippet) > 0:
            msg += "\n  Record snippet: " + self.record_snippet
        return msg
    
    fn write_to[w: Writer](self, mut writer: w):
        """Write error to writer."""
        writer.write(self.__str__())


# ---------------------------------------------------------------------------
# Shared error message helpers (for consistent Error strings across modules)
# ---------------------------------------------------------------------------

fn buffer_capacity_error(
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
        msg = "Line exceeds max buffer capacity of " + String(max_capacity) + " bytes"
    else:
        msg = "Line exceeds buffer capacity of " + String(capacity) + " bytes"
    if growth_hint:
        msg += ". Enable buffer_growth or use a larger buffer_capacity."
    return msg
