"""Tests for error handling with context in BlazeSeq."""

from blazeseq.fastq.parser import FastqParser, ParserConfig
from blazeseq.io.readers import MemoryReader
from blazeseq.errors import ParseError, ValidationError
from blazeseq.CONSTS import EOF
from std.testing import assert_equal, assert_raises, assert_true, TestSuite


def create_invalid_id_fastq() -> List[Byte]:
    """Create FASTQ data with invalid header (doesn't start with @)."""
    var data = List[Byte]()
    # Invalid header - doesn't start with @
    data.append(Byte(ord("r")))
    data.append(Byte(ord("1")))
    data.append(Byte(ord("\n")))
    data.append(Byte(ord("A")))
    data.append(Byte(ord("T")))
    data.append(Byte(ord("C")))
    data.append(Byte(ord("G")))
    data.append(Byte(ord("\n")))
    data.append(Byte(ord("+")))
    data.append(Byte(ord("\n")))
    data.append(Byte(ord("!")))
    data.append(Byte(ord("@")))
    data.append(Byte(ord("#")))
    data.append(Byte(ord("$")))
    data.append(Byte(ord("\n")))
    return data^


def create_mismatched_length_fastq() -> List[Byte]:
    """Create FASTQ data with mismatched sequence/quality lengths."""
    var data = List[Byte]()
    # Valid header
    data.append(Byte(ord("@")))
    data.append(Byte(ord("r")))
    data.append(Byte(ord("1")))
    data.append(Byte(ord("\n")))
    # Sequence
    data.append(Byte(ord("A")))
    data.append(Byte(ord("T")))
    data.append(Byte(ord("C")))
    data.append(Byte(ord("G")))
    data.append(Byte(ord("\n")))
    # Quality header
    data.append(Byte(ord("+")))
    data.append(Byte(ord("\n")))
    # Quality string (only 3 chars, but sequence is 4)
    data.append(Byte(ord("!")))
    data.append(Byte(ord("@")))
    data.append(Byte(ord("#")))
    data.append(Byte(ord("\n")))
    return data^


def test_parse_error_with_context() raises:
    """Test that ParseError includes contextual information."""
    var invalid_data = create_invalid_id_fastq()
    var reader = MemoryReader(invalid_data^)
    comptime config = ParserConfig(check_ascii=True, check_quality=True)
    var parser = FastqParser[MemoryReader, config](reader^)
    
    # Using direct method should raise ParseError with context
    with assert_raises(contains="Record number"):
        _ = parser.next_record()


def test_validation_error_with_context() raises:
    """Test that ValidationError includes contextual information."""
    var invalid_data = create_mismatched_length_fastq()
    var reader = MemoryReader(invalid_data^)
    comptime config = ParserConfig(check_ascii=True, check_quality=True)
    var parser = FastqParser[MemoryReader, config](reader^)
    
    # Using direct method should raise ParseError (which wraps ValidationError)
    with assert_raises(contains="Record number"):
        _ = parser.next_record()


def test_error_context_in_iterator() raises:
    """Test that errors in iterators are printed with context."""
    var invalid_data = create_invalid_id_fastq()
    var reader = MemoryReader(invalid_data^)
    comptime config = ParserConfig(check_ascii=True, check_quality=True)
    var parser = FastqParser[MemoryReader, config](reader^)
    
    # Using iterator should print error and stop iteration
    var count = 0
    for _ in parser.records():
        count += 1
    
    # Should have processed 0 records due to error
    assert_equal(count, 0)


def test_record_number_tracking() raises:
    """Test that record numbers are tracked correctly."""
    # Create data with multiple records, second one invalid
    var data = List[Byte]()
    # First record (valid)
    data.append(Byte(ord("@")))
    data.append(Byte(ord("r")))
    data.append(Byte(ord("1")))
    data.append(Byte(ord("\n")))
    data.append(Byte(ord("A")))
    data.append(Byte(ord("T")))
    data.append(Byte(ord("\n")))
    data.append(Byte(ord("+")))
    data.append(Byte(ord("\n")))
    data.append(Byte(ord("!")))
    data.append(Byte(ord("@")))
    data.append(Byte(ord("\n")))
    # Second record (invalid header)
    data.append(Byte(ord("r")))
    data.append(Byte(ord("2")))
    data.append(Byte(ord("\n")))
    data.append(Byte(ord("G")))
    data.append(Byte(ord("C")))
    data.append(Byte(ord("\n")))
    data.append(Byte(ord("+")))
    data.append(Byte(ord("\n")))
    data.append(Byte(ord("#")))
    data.append(Byte(ord("$")))
    data.append(Byte(ord("\n")))
    
    var reader = MemoryReader(data^)
    comptime config = ParserConfig(check_ascii=True, check_quality=True)
    var parser = FastqParser[MemoryReader, config](reader^)
    
    # First record should succeed
    var record1 = parser.next_record()
    assert_equal(len(record1), 2)
    
    # Second record should fail with record_number = 2
    with assert_raises(contains="Record number: 2"):
        _ = parser.next_record()


def test_line_number_tracking() raises:
    """Test that line numbers are tracked correctly."""
    var invalid_data = create_invalid_id_fastq()
    var reader = MemoryReader(invalid_data^)
    comptime config = ParserConfig(check_ascii=True, check_quality=True)
    var parser = FastqParser[MemoryReader, config](reader^)
    
    # Error should include line number
    with assert_raises(contains="Line number"):
        _ = parser.next_record()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
