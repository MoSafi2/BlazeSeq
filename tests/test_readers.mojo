"""Tests for FileReader and MemoryReader from blazeseq.readers module."""

from testing import assert_equal, assert_raises, assert_true, assert_false
from pathlib import Path
from blazeseq.readers import FileReader, MemoryReader
from memory import alloc, Span
from testing import TestSuite


# ============================================================================
# Helper Functions
# ============================================================================


fn create_test_file(path: Path, content: String) raises -> Path:
    """Helper function to create test files."""
    new_path = Path("tests/test_data") / path
    with open(new_path, "w") as f:
        f.write(content)
    return new_path


fn create_memory_reader_from_string(content: String) -> MemoryReader:
    """Helper function to create MemoryReader from string content."""
    var content_bytes = content.as_bytes()
    return MemoryReader(content_bytes)


# ============================================================================
# MemoryReader Initialization Tests
# ============================================================================


fn test_memory_reader_init_from_list() raises:
    """Test MemoryReader initialization from List[Byte]."""
    var data = List[Byte]()
    data.append(72)  # 'H'
    data.append(101)  # 'e'
    data.append(108)  # 'l'
    data.append(108)  # 'l'
    data.append(111)  # 'o'
    
    var reader = MemoryReader(data^)
    assert_equal(reader.position, 0, "Position should start at 0")
    
    # Verify we can read the data
    var buf = alloc[Byte](5)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=5)
    var bytes_read = reader.read_to_buffer(span, 5)
    
    assert_equal(bytes_read, 5, "Should read 5 bytes")
    assert_equal(reader.position, 5, "Position should advance to 5")
    
    buf.free()
    print("✓ test_memory_reader_init_from_list passed")


fn test_memory_reader_init_from_span() raises:
    """Test MemoryReader initialization from Span[Byte]."""
    var data = "Hello World"
    var data_bytes = data.as_bytes()
    # MemoryReader accepts Span[Byte] (any origin), so we can pass it directly
    var reader = MemoryReader(data_bytes)
    assert_equal(reader.position, 0, "Position should start at 0")
    
    # Verify we can read the data
    var buf = alloc[Byte](11)
    var read_span = Span[Byte, MutExternalOrigin](ptr=buf, length=11)
    var bytes_read = reader.read_to_buffer(read_span, 11)
    
    assert_equal(bytes_read, 11, "Should read 11 bytes")
    assert_equal(reader.position, 11, "Position should advance to 11")
    
    buf.free()
    print("✓ test_memory_reader_init_from_span passed")


fn test_memory_reader_init_from_string() raises:
    """Test MemoryReader initialization from string helper."""
    var content = "Test content\n"
    var reader = create_memory_reader_from_string(content)
    
    assert_equal(reader.position, 0, "Position should start at 0")
    
    print("✓ test_memory_reader_init_from_string passed")


fn test_memory_reader_init_empty() raises:
    """Test MemoryReader initialization with empty data."""
    var data = List[Byte]()
    var reader = MemoryReader(data^)
    
    assert_equal(reader.position, 0, "Position should start at 0")
    
    # Reading should return 0 (EOF)
    var buf = alloc[Byte](10)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=10)
    var bytes_read = reader.read_to_buffer(span, 10)
    
    assert_equal(bytes_read, 0, "Should return 0 bytes at EOF")
    
    buf.free()
    print("✓ test_memory_reader_init_empty passed")


# ============================================================================
# MemoryReader read_to_buffer Tests
# ============================================================================


fn test_memory_reader_read_to_buffer_basic() raises:
    """Test basic read_to_buffer functionality."""
    var content = "Hello World"
    var reader = create_memory_reader_from_string(content)
    
    var buf = alloc[Byte](11)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=11)
    var bytes_read = reader.read_to_buffer(span, 11)
    
    assert_equal(bytes_read, 11, "Should read 11 bytes")
    assert_equal(reader.position, 11, "Position should be at end")
    
    # Verify content
    assert_equal(span[0], 72, "First byte should be 'H'")
    assert_equal(span[4], 111, "Fifth byte should be 'o'")
    
    buf.free()
    print("✓ test_memory_reader_read_to_buffer_basic passed")


fn test_memory_reader_read_to_buffer_partial() raises:
    """Test reading partial data."""
    var content = "Hello World"
    var reader = create_memory_reader_from_string(content)
    
    var buf = alloc[Byte](5)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=5)
    var bytes_read = reader.read_to_buffer(span, 5)
    
    assert_equal(bytes_read, 5, "Should read 5 bytes")
    assert_equal(reader.position, 5, "Position should be at 5")
    
    # Verify content
    assert_equal(span[0], 72, "First byte should be 'H'")
    assert_equal(span[4], 111, "Fifth byte should be 'o'")
    
    buf.free()
    print("✓ test_memory_reader_read_to_buffer_partial passed")


fn test_memory_reader_read_to_buffer_with_pos() raises:
    """Test read_to_buffer with position offset."""
    var content = "Hello World"
    var reader = create_memory_reader_from_string(content)
    
    var buf = alloc[Byte](11)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=11)
    
    # Read with position offset
    var bytes_read = reader.read_to_buffer(span, 5, pos=3)
    
    assert_equal(bytes_read, 5, "Should read 5 bytes")
    assert_equal(reader.position, 5, "Position should advance")
    
    # Verify content was written at offset position
    assert_equal(span[3], 72, "Byte at position 3 should be 'H'")
    assert_equal(span[4], 101, "Byte at position 4 should be 'e'")
    
    buf.free()
    print("✓ test_memory_reader_read_to_buffer_with_pos passed")


fn test_memory_reader_read_to_buffer_multiple_reads() raises:
    """Test multiple sequential reads."""
    var content = "Hello World"
    var reader = create_memory_reader_from_string(content)
    
    var buf = alloc[Byte](11)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=11)
    
    # First read
    var bytes_read1 = reader.read_to_buffer(span, 5)
    assert_equal(bytes_read1, 5, "First read should return 5 bytes")
    assert_equal(reader.position, 5, "Position should be at 5")
    
    # Second read
    var bytes_read2 = reader.read_to_buffer(span, 6)
    assert_equal(bytes_read2, 6, "Second read should return 6 bytes")
    assert_equal(reader.position, 11, "Position should be at 11")
    
    buf.free()
    print("✓ test_memory_reader_read_to_buffer_multiple_reads passed")


fn test_memory_reader_read_to_buffer_eof() raises:
    """Test reading past EOF."""
    var content = "Hello"
    var reader = create_memory_reader_from_string(content)
    
    var buf = alloc[Byte](10)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=10)
    
    # Read more than available
    var bytes_read = reader.read_to_buffer(span, 10)
    
    assert_equal(bytes_read, 5, "Should only read 5 bytes (available)")
    assert_equal(reader.position, 5, "Position should be at end")
    
    # Next read should return 0 (EOF)
    var bytes_read2 = reader.read_to_buffer(span, 10)
    assert_equal(bytes_read2, 0, "Should return 0 at EOF")
    
    buf.free()
    print("✓ test_memory_reader_read_to_buffer_eof passed")


fn test_memory_reader_read_to_buffer_large_content() raises:
    """Test reading large content."""
    var content = String("")
    for i in range(1000):
        content += "A"
    
    var reader = create_memory_reader_from_string(content)
    
    var buf = alloc[Byte](500)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=500)
    
    var bytes_read = reader.read_to_buffer(span, 500)
    assert_equal(bytes_read, 500, "Should read 500 bytes")
    assert_equal(reader.position, 500, "Position should be at 500")
    
    # Read remaining
    var bytes_read2 = reader.read_to_buffer(span, 500)
    assert_equal(bytes_read2, 500, "Should read remaining 500 bytes")
    assert_equal(reader.position, 1000, "Position should be at 1000")
    
    buf.free()
    print("✓ test_memory_reader_read_to_buffer_large_content passed")


# ============================================================================
# MemoryReader Error Handling Tests
# ============================================================================


fn test_memory_reader_read_to_buffer_invalid_pos() raises:
    """Test read_to_buffer with invalid position."""
    var content = "Hello"
    var reader = create_memory_reader_from_string(content)
    
    var buf = alloc[Byte](5)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=5)
    
    with assert_raises(contains="Position is outside the buffer"):
        reader.read_to_buffer(span, 3, pos=10)
    
    buf.free()
    print("✓ test_memory_reader_read_to_buffer_invalid_pos passed")


fn test_memory_reader_read_to_buffer_negative_amt() raises:
    """Test read_to_buffer with negative amount."""
    var content = "Hello"
    var reader = create_memory_reader_from_string(content)
    
    var buf = alloc[Byte](5)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=5)
    
    with assert_raises(contains="The amount to be read should be positive"):
        reader.read_to_buffer(span, -1)
    
    buf.free()
    print("✓ test_memory_reader_read_to_buffer_negative_amt passed")


fn test_memory_reader_read_to_buffer_amt_too_large() raises:
    """Test read_to_buffer with amount larger than buffer space."""
    var content = "Hello"
    var reader = create_memory_reader_from_string(content)
    
    var buf = alloc[Byte](5)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=5)
    
    with assert_raises(contains="Number of elements to read is bigger than the available space"):
        reader.read_to_buffer(span, 10, pos=0)
    
    buf.free()
    print("✓ test_memory_reader_read_to_buffer_amt_too_large passed")


fn test_memory_reader_read_to_buffer_amt_too_large_with_pos() raises:
    """Test read_to_buffer with amount larger than remaining buffer space."""
    var content = "Hello"
    var reader = create_memory_reader_from_string(content)
    
    var buf = alloc[Byte](10)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=10)
    
    with assert_raises(contains="Number of elements to read is bigger than the available space"):
        reader.read_to_buffer(span, 8, pos=5)
    
    buf.free()
    print("✓ test_memory_reader_read_to_buffer_amt_too_large_with_pos passed")


# ============================================================================
# FileReader Initialization Tests
# ============================================================================


fn test_file_reader_init() raises:
    """Test FileReader initialization."""
    var test_path = create_test_file(Path("test_file_reader_init.txt"), "Hello World\n")
    
    var reader = FileReader(test_path)
    
    # Verify file was opened successfully by reading from it
    var buf = alloc[Byte](12)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=12)
    var bytes_read = reader.read_to_buffer(span, 12)
    
    assert_equal(bytes_read, 12, "Should read 12 bytes")
    
    buf.free()
    print("✓ test_file_reader_init passed")


fn test_file_reader_init_nonexistent_file() raises:
    """Test FileReader initialization with nonexistent file."""
    var nonexistent_path = Path("tests/test_data/nonexistent_file.txt")
    
    with assert_raises():
        var reader = FileReader(nonexistent_path)
        _ = reader
    
    print("✓ test_file_reader_init_nonexistent_file passed")


# ============================================================================
# FileReader read_bytes Tests
# ============================================================================


fn test_file_reader_read_bytes() raises:
    """Test FileReader read_bytes method."""
    var content = "Hello World\n"
    var test_path = create_test_file(Path("test_file_reader_read_bytes.txt"), content)
    
    var reader = FileReader(test_path)
    var bytes = reader.read_bytes()
    
    assert_equal(len(bytes), 12, "Should read 12 bytes")
    assert_equal(bytes[0], 72, "First byte should be 'H'")
    assert_equal(bytes[4], 111, "Fifth byte should be 'o'")
    
    print("✓ test_file_reader_read_bytes passed")


fn test_file_reader_read_bytes_partial() raises:
    """Test FileReader read_bytes with specific amount."""
    var content = "Hello World\n"
    var test_path = create_test_file(Path("test_file_reader_read_bytes_partial.txt"), content)
    
    var reader = FileReader(test_path)
    var bytes = reader.read_bytes(5)
    
    assert_equal(len(bytes), 5, "Should read 5 bytes")
    assert_equal(bytes[0], 72, "First byte should be 'H'")
    assert_equal(bytes[4], 111, "Fifth byte should be 'o'")
    
    print("✓ test_file_reader_read_bytes_partial passed")


fn test_file_reader_read_bytes_empty_file() raises:
    """Test FileReader read_bytes on empty file."""
    var test_path = create_test_file(Path("test_file_reader_read_bytes_empty.txt"), "")
    
    var reader = FileReader(test_path)
    var bytes = reader.read_bytes()
    
    assert_equal(len(bytes), 0, "Should read 0 bytes from empty file")
    
    print("✓ test_file_reader_read_bytes_empty_file passed")


fn test_file_reader_read_bytes_large_file() raises:
    """Test FileReader read_bytes on large file."""
    var content = String("")
    for i in range(1000):
        content += "A"
    
    var test_path = create_test_file(Path("test_file_reader_read_bytes_large.txt"), content)
    
    var reader = FileReader(test_path)
    var bytes = reader.read_bytes()
    
    assert_equal(len(bytes), 1000, "Should read 1000 bytes")
    assert_equal(bytes[0], 65, "First byte should be 'A'")
    assert_equal(bytes[999], 65, "Last byte should be 'A'")
    
    print("✓ test_file_reader_read_bytes_large_file passed")


# ============================================================================
# FileReader read_to_buffer Tests
# ============================================================================


fn test_file_reader_read_to_buffer_basic() raises:
    """Test FileReader read_to_buffer basic functionality."""
    var content = "Hello World\n"
    var test_path = create_test_file(Path("test_file_reader_read_to_buffer_basic.txt"), content)
    
    var reader = FileReader(test_path)
    
    var buf = alloc[Byte](12)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=12)
    var bytes_read = reader.read_to_buffer(span, 12)
    
    assert_equal(bytes_read, 12, "Should read 12 bytes")
    
    # Verify content
    assert_equal(span[0], 72, "First byte should be 'H'")
    assert_equal(span[4], 111, "Fifth byte should be 'o'")
    
    buf.free()
    print("✓ test_file_reader_read_to_buffer_basic passed")


fn test_file_reader_read_to_buffer_partial() raises:
    """Test FileReader read_to_buffer with partial read."""
    var content = "Hello World\n"
    var test_path = create_test_file(Path("test_file_reader_read_to_buffer_partial.txt"), content)
    
    var reader = FileReader(test_path)
    
    var buf = alloc[Byte](5)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=5)
    var bytes_read = reader.read_to_buffer(span, 5)
    
    assert_equal(bytes_read, 5, "Should read 5 bytes")
    
    # Verify content
    assert_equal(span[0], 72, "First byte should be 'H'")
    assert_equal(span[4], 111, "Fifth byte should be 'o'")
    
    buf.free()
    print("✓ test_file_reader_read_to_buffer_partial passed")


fn test_file_reader_read_to_buffer_with_pos() raises:
    """Test FileReader read_to_buffer with position offset."""
    var content = "Hello World\n"
    var test_path = create_test_file(Path("test_file_reader_read_to_buffer_with_pos.txt"), content)
    
    var reader = FileReader(test_path)
    
    var buf = alloc[Byte](12)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=12)
    
    # Read with position offset - FileReader reads into the entire available buffer space
    # starting at pos, not limited by amt parameter
    var bytes_read = reader.read_to_buffer(span, 5, pos=3)
    
    # FileReader reads as much as fits in the buffer (12 - 3 = 9 bytes available)
    assert_true(bytes_read >= 5, "Should read at least 5 bytes")
    assert_equal(bytes_read, 9, "Should read 9 bytes (remaining buffer space)")
    
    # Verify content was written at offset position
    assert_equal(span[3], 72, "Byte at position 3 should be 'H'")
    assert_equal(span[4], 101, "Byte at position 4 should be 'e'")
    
    buf.free()
    print("✓ test_file_reader_read_to_buffer_with_pos passed")


fn test_file_reader_read_to_buffer_multiple_reads() raises:
    """Test FileReader multiple sequential reads."""
    var content = "Hello World\n"
    var test_path = create_test_file(Path("test_file_reader_read_to_buffer_multiple.txt"), content)
    
    var reader = FileReader(test_path)
    
    var buf = alloc[Byte](12)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=12)
    
    # First read - FileReader reads into entire buffer (12 bytes)
    var bytes_read1 = reader.read_to_buffer(span, 5)
    assert_equal(bytes_read1, 12, "First read should return 12 bytes (entire file)")
    
    # Second read - should return 0 (EOF)
    var bytes_read2 = reader.read_to_buffer(span, 7)
    assert_equal(bytes_read2, 0, "Second read should return 0 bytes (EOF)")
    
    buf.free()
    print("✓ test_file_reader_read_to_buffer_multiple_reads passed")


fn test_file_reader_read_to_buffer_large_file() raises:
    """Test FileReader read_to_buffer on large file."""
    var content = String("")
    for i in range(2000):
        content += "A"
    
    var test_path = create_test_file(Path("test_file_reader_read_to_buffer_large.txt"), content)
    
    var reader = FileReader(test_path)
    
    var buf = alloc[Byte](1000)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=1000)
    
    var bytes_read = reader.read_to_buffer(span, 1000)
    assert_equal(bytes_read, 1000, "Should read 1000 bytes")
    
    # Read remaining
    var bytes_read2 = reader.read_to_buffer(span, 1000)
    assert_equal(bytes_read2, 1000, "Should read remaining 1000 bytes")
    
    buf.free()
    print("✓ test_file_reader_read_to_buffer_large_file passed")


# ============================================================================
# FileReader Error Handling Tests
# ============================================================================


fn test_file_reader_read_to_buffer_invalid_pos() raises:
    """Test FileReader read_to_buffer with invalid position."""
    var content = "Hello"
    var test_path = create_test_file(Path("test_file_reader_read_to_buffer_invalid_pos.txt"), content)
    
    var reader = FileReader(test_path)
    
    var buf = alloc[Byte](5)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=5)
    
    with assert_raises(contains="Position is outside the buffer"):
        reader.read_to_buffer(span, 3, pos=10)
    
    buf.free()
    print("✓ test_file_reader_read_to_buffer_invalid_pos passed")


fn test_file_reader_read_to_buffer_negative_amt() raises:
    """Test FileReader read_to_buffer with negative amount."""
    var content = "Hello"
    var test_path = create_test_file(Path("test_file_reader_read_to_buffer_negative_amt.txt"), content)
    
    var reader = FileReader(test_path)
    
    var buf = alloc[Byte](5)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=5)
    
    with assert_raises(contains="The amount to be read should be positive"):
        reader.read_to_buffer(span, -1)
    
    buf.free()
    print("✓ test_file_reader_read_to_buffer_negative_amt passed")


fn test_file_reader_read_to_buffer_amt_too_large() raises:
    """Test FileReader read_to_buffer with amount larger than buffer space."""
    var content = "Hello"
    var test_path = create_test_file(Path("test_file_reader_read_to_buffer_amt_too_large.txt"), content)
    
    var reader = FileReader(test_path)
    
    var buf = alloc[Byte](5)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=5)
    
    with assert_raises(contains="Number of elements to read is bigger than the available space"):
        reader.read_to_buffer(span, 10, pos=0)
    
    buf.free()
    print("✓ test_file_reader_read_to_buffer_amt_too_large passed")


fn test_file_reader_read_to_buffer_amt_too_large_with_pos() raises:
    """Test FileReader read_to_buffer with amount larger than remaining buffer space."""
    var content = "Hello"
    var test_path = create_test_file(Path("test_file_reader_read_to_buffer_amt_too_large_with_pos.txt"), content)
    
    var reader = FileReader(test_path)
    
    var buf = alloc[Byte](10)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=10)
    
    with assert_raises(contains="Number of elements to read is bigger than the available space"):
        reader.read_to_buffer(span, 8, pos=5)
    
    buf.free()
    print("✓ test_file_reader_read_to_buffer_amt_too_large_with_pos passed")


# ============================================================================
# Test Suite
# ============================================================================


fn main() raises:
    """Run all tests."""
    print("Running FileReader and MemoryReader tests...\n")
    TestSuite.discover_tests[__functions_in_module()]().run()
    print("\n✓ All tests passed!")
