"""Tests for error handling with context in BlazeSeq."""

from blazeseq.parser import FastqParser, ParserConfig
from blazeseq.io.readers import MemoryReader
from blazeseq.errors import ParseError, ValidationError
from blazeseq.CONSTS import EOF
from testing import assert_equal, assert_raises, assert_true, TestSuite


fn create_invalid_header_fastq() -> List[Byte]:
    """Create FASTQ data with invalid header (doesn't start with @)."""
    var data = List[Byte]()
    # Invalid header - doesn't start with @
    data.append(ord("r"))
    data.append(ord("1"))
    data.append(ord("\n"))
    data.append(ord("A"))
    data.append(ord("T"))
    data.append(ord("C"))
    data.append(ord("G"))
    data.append(ord("\n"))
    data.append(ord("+"))
    data.append(ord("\n"))
    data.append(ord("!"))
    data.append(ord("@"))
    data.append(ord("#"))
    data.append(ord("$"))
    data.append(ord("\n"))
    return data^


fn create_mismatched_length_fastq() -> List[Byte]:
    """Create FASTQ data with mismatched sequence/quality lengths."""
    var data = List[Byte]()
    # Valid header
    data.append(ord("@"))
    data.append(ord("r"))
    data.append(ord("1"))
    data.append(ord("\n"))
    # Sequence
    data.append(ord("A"))
    data.append(ord("T"))
    data.append(ord("C"))
    data.append(ord("G"))
    data.append(ord("\n"))
    # Quality header
    data.append(ord("+"))
    data.append(ord("\n"))
    # Quality string (only 3 chars, but sequence is 4)
    data.append(ord("!"))
    data.append(ord("@"))
    data.append(ord("#"))
    data.append(ord("\n"))
    return data^


fn test_parse_error_with_context() raises:
    """Test that ParseError includes contextual information."""
    var invalid_data = create_invalid_header_fastq()
    var reader = MemoryReader(invalid_data^)
    comptime config = ParserConfig(check_ascii=True, check_quality=True)
    var parser = FastqParser[MemoryReader, config](reader^)
    
    # Using direct method should raise ParseError with context
    with assert_raises(contains="Record number"):
        _ = parser.next_record()


fn test_validation_error_with_context() raises:
    """Test that ValidationError includes contextual information."""
    var invalid_data = create_mismatched_length_fastq()
    var reader = MemoryReader(invalid_data^)
    comptime config = ParserConfig(check_ascii=True, check_quality=True)
    var parser = FastqParser[MemoryReader, config](reader^)
    
    # Using direct method should raise ParseError (which wraps ValidationError)
    with assert_raises(contains="Record number"):
        _ = parser.next_record()


fn test_error_context_in_iterator() raises:
    """Test that errors in iterators are printed with context."""
    var invalid_data = create_invalid_header_fastq()
    var reader = MemoryReader(invalid_data^)
    comptime config = ParserConfig(check_ascii=True, check_quality=True)
    var parser = FastqParser[MemoryReader, config](reader^)
    
    # Using iterator should print error and stop iteration
    var count = 0
    for record in parser.records():
        count += 1
    
    # Should have processed 0 records due to error
    assert_equal(count, 0)


fn test_record_number_tracking() raises:
    """Test that record numbers are tracked correctly."""
    # Create data with multiple records, second one invalid
    var data = List[Byte]()
    # First record (valid)
    data.append(ord("@"))
    data.append(ord("r"))
    data.append(ord("1"))
    data.append(ord("\n"))
    data.append(ord("A"))
    data.append(ord("T"))
    data.append(ord("\n"))
    data.append(ord("+"))
    data.append(ord("\n"))
    data.append(ord("!"))
    data.append(ord("@"))
    data.append(ord("\n"))
    # Second record (invalid header)
    data.append(ord("r"))
    data.append(ord("2"))
    data.append(ord("\n"))
    data.append(ord("G"))
    data.append(ord("C"))
    data.append(ord("\n"))
    data.append(ord("+"))
    data.append(ord("\n"))
    data.append(ord("#"))
    data.append(ord("$"))
    data.append(ord("\n"))
    
    var reader = MemoryReader(data^)
    comptime config = ParserConfig(check_ascii=True, check_quality=True)
    var parser = FastqParser[MemoryReader, config](reader^)
    
    # First record should succeed
    var record1 = parser.next_record()
    assert_equal(len(record1), 2)
    
    # Second record should fail with record_number = 2
    with assert_raises(contains="Record number: 2"):
        _ = parser.next_record()


fn test_line_number_tracking() raises:
    """Test that line numbers are tracked correctly."""
    var invalid_data = create_invalid_header_fastq()
    var reader = MemoryReader(invalid_data^)
    comptime config = ParserConfig(check_ascii=True, check_quality=True)
    var parser = FastqParser[MemoryReader, config](reader^)
    
    # Error should include line number
    with assert_raises(contains="Line number"):
        _ = parser.next_record()


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
