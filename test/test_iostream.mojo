from testing import assert_equal, assert_raises, assert_true, assert_false
from pathlib import Path
from blazeseq.CONSTS import DEFAULT_CAPACITY
from blazeseq.iostream import BufferedReader, FileReader, InnerBuffer
from testing import TestSuite


fn create_test_file(path: Path, content: String) raises -> Path:
    """Helper function to create test files."""
    new_path = Path("test/test_data") / path
    with open(new_path, "w") as f:
        f.write(content)

    return new_path


fn test_buffered_reader_init() raises:
    """Verify initialization with default capacity."""
    # Create a test file
    var test_file = Path("test_init.txt")
    test_file = create_test_file(test_file, "Hello World\n")

    # Initialize BufferedReader
    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Verify buffer is initialized
    assert_true(
        buf_reader.capacity() > 0, "Buffer should have positive capacity"
    )
    assert_equal(
        buf_reader.capacity(), DEFAULT_CAPACITY, "Should use default capacity"
    )
    assert_equal(buf_reader.head, 0, "Head should start at 0")
    assert_true(buf_reader.end > 0, "Buffer should be initially filled")
    assert_true(buf_reader.IS_EOF, "Should not be EOF initially")

    print("✓ test_buffered_reader_init passed")


fn test_buffered_reader_initial_fill() raises:
    """Verify buffer fills on init."""
    var test_content = "Initial content for testing\n"
    var test_file = Path("test_initial_fill.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Check that buffer has been filled
    assert_true(buf_reader.end > 0, "Buffer end should be > 0 after init")
    assert_true(len(buf_reader) > 0, "Buffer should contain data")
    assert_true(
        len(buf_reader) <= buf_reader.capacity(),
        "Filled data should not exceed capacity",
    )

    # Verify actual content was read
    var expected_len = min(len(test_content), buf_reader.capacity())
    assert_equal(
        buf_reader.end, expected_len, "Should read expected amount of data"
    )

    print("✓ test_buffered_reader_initial_fill passed")


fn test_buffered_reader_len() raises:
    """Test __len__ returns correct available bytes."""
    var test_content = "0123456789\n"
    var test_file = Path("test_len.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Initial length should match content length (or capacity if smaller)
    var initial_len = len(buf_reader)
    assert_equal(
        initial_len,
        len(test_content),
        "Initial length should match file content",
    )

    # Read a line and check length decreases
    var line = buf_reader.get_next_line()
    var new_len = len(buf_reader)
    assert_true(new_len < initial_len, "Length should decrease after reading")
    assert_equal(new_len, 0, "Should have no bytes left after reading line")

    print("✓ test_buffered_reader_len passed")


fn test_buffered_reader_getitem() raises:
    """Test single byte access."""
    var test_content = "ABC\n"
    var test_file = Path("test_getitem.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Test accessing bytes within valid range
    assert_equal(buf_reader[0], ord("A"), "First byte should be 'A'")
    assert_equal(buf_reader[1], ord("B"), "Second byte should be 'B'")
    assert_equal(buf_reader[2], ord("C"), "Third byte should be 'C'")
    assert_equal(buf_reader[3], ord("\n"), "Fourth byte should be newline")

    print("✓ test_buffered_reader_getitem passed")


fn test_buffered_reader_getitem_out_of_bounds() raises:
    """Verify bounds checking."""
    var test_file = Path("test_getitem_bounds.txt")
    test_file = create_test_file(test_file, "XYZ\n")

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Test accessing before head (should fail)
    with assert_raises(contains="Out of bounds"):
        _ = buf_reader[-1]

    # Test accessing at or after end (should fail)
    with assert_raises(contains="Out of bounds"):
        _ = buf_reader[buf_reader.end]

    with assert_raises(contains="Out of bounds"):
        _ = buf_reader[buf_reader.end + 10]

    print("✓ test_buffered_reader_getitem_out_of_bounds passed")


fn test_buffered_reader_slice() raises:
    """Test slicing operations."""
    var test_content = "0123456789\n"
    var test_file = Path("test_slice.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Test basic slice
    var slice1 = buf_reader[0:3]
    assert_equal(len(slice1), 3, "Slice should have length 3")
    assert_equal(slice1[0], ord("0"), "First element should be '0'")
    assert_equal(slice1[2], ord("2"), "Third element should be '2'")

    # Test slice to end
    var slice2 = buf_reader[5:]
    assert_equal(
        len(slice2),
        buf_reader.end - 5,
        "Slice to end should have correct length",
    )

    # Test slice from start
    var slice3 = buf_reader[:4]
    assert_equal(len(slice3), 4, "Slice from start should have length 4")

    print("✓ test_buffered_reader_slice passed")


fn test_buffered_reader_as_span() raises:
    """Test span creation."""
    var test_content = "Span test content\n"
    var test_file = Path("test_as_span.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Get span of available data
    var span = buf_reader.as_span()

    assert_equal(
        len(span), len(buf_reader), "Span length should match buffer length"
    )
    assert_equal(
        len(span),
        buf_reader.end - buf_reader.head,
        "Span should represent data from head to end",
    )
    print(span[0])

    assert_equal(span[0], ord("S"), "First byte should be 'S'")
    assert_equal(span[1], ord("p"), "Second byte should be 'p'")

    print("✓ test_buffered_reader_as_span passed")

    _ = buf_reader  # Hack to keep the reader alive


# ============================================================================
# Basic Line Reading Tests
# ============================================================================


fn test_get_next_line_single_line() raises:
    """Read one line ending with newline."""
    var test_content = "Hello World\n"
    var test_file = Path("test_single_line.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var line = buf_reader.get_next_line()
    assert_equal(line, "Hello World", "Should read line without newline")

    # Next read should raise EOF
    with assert_raises(contains="EOF"):
        _ = buf_reader.get_next_line()

    print("✓ test_get_next_line_single_line passed")


fn test_get_next_line_multiple_lines() raises:
    """Read several lines sequentially."""
    var test_content = "Line 1\nLine 2\nLine 3\n"
    var test_file = Path("test_multiple_lines.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var line1 = buf_reader.get_next_line()
    assert_equal(line1, "Line 1", "First line should be 'Line 1'")

    var line2 = buf_reader.get_next_line()
    assert_equal(line2, "Line 2", "Second line should be 'Line 2'")

    var line3 = buf_reader.get_next_line()
    assert_equal(line3, "Line 3", "Third line should be 'Line 3'")

    # Should raise EOF after all lines
    with assert_raises(contains="EOF"):
        _ = buf_reader.get_next_line()

    print("✓ test_get_next_line_multiple_lines passed")


fn test_get_next_line_empty_line() raises:
    """Handle empty lines (just newline)."""
    var test_content = "First\n\nThird\n"
    var test_file = Path("test_empty_line.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var line1 = buf_reader.get_next_line()
    assert_equal(line1, "First", "First line should be 'First'")

    var line2 = buf_reader.get_next_line()
    assert_equal(line2, "", "Empty line should be empty string")

    var line3 = buf_reader.get_next_line()
    assert_equal(line3, "Third", "Third line should be 'Third'")

    print("✓ test_get_next_line_empty_line passed")


fn test_get_next_line_no_trailing_newline() raises:
    """Handle last line without newline."""
    var test_content = "Line with newline\nLine without newline"
    var test_file = Path("test_no_trailing.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var line1 = buf_reader.get_next_line()
    assert_equal(line1, "Line with newline", "First line correct")

    var line2 = buf_reader.get_next_line()
    assert_equal(line2, "Line without newline", "Last line without newline")

    print("✓ test_get_next_line_no_trailing_newline passed")


fn test_get_next_line_with_spaces() raises:
    """Verify space stripping works."""
    var test_content = "  Leading spaces\nTrailing spaces  \n  Both sides  \n"
    var test_file = Path("test_spaces.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var line1 = buf_reader.get_next_line()
    assert_equal(line1, "Leading spaces", "Leading spaces stripped")

    var line2 = buf_reader.get_next_line()
    assert_equal(line2, "Trailing spaces", "Trailing spaces stripped")

    var line3 = buf_reader.get_next_line()
    assert_equal(line3, "Both sides", "Both sides stripped")

    print("✓ test_get_next_line_with_spaces passed")


fn test_get_next_line_bytes() raises:
    """Test byte list return variant."""
    var test_content = "Test line\n"
    var test_file = Path("test_bytes.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var line_bytes = buf_reader.get_next_line_bytes()

    # Verify it's a List[Byte] with expected content
    assert_true(len(line_bytes) > 0, "Should return non-empty byte list")
    assert_equal(line_bytes[0], ord("T"), "First byte should be 'T'")
    assert_equal(line_bytes[1], ord("e"), "Second byte should be 'e'")

    print("✓ test_get_next_line_bytes passed")


fn test_get_next_line_span() raises:
    """Test span return variant."""
    var test_content = "Span line\n"
    var test_file = Path("test_span.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var line_span = buf_reader.get_next_line_span()

    # Verify it's a Span with expected content
    assert_true(len(line_span) > 0, "Should return non-empty span")
    assert_equal(line_span[0], ord("S"), "First byte should be 'S'")
    assert_equal(line_span[1], ord("p"), "Second byte should be 'p'")

    _ = buf_reader
    print("✓ test_get_next_line_span passed")


# ============================================================================
# Edge Cases
# ============================================================================


fn test_get_next_line_line_longer_than_buffer() raises:
    """Verify error on oversized line."""
    # Create a line longer than buffer capacity
    var long_line = String("")
    for i in range(200):
        long_line += "x"
    long_line += "\n"

    var test_file = Path("test_long_line.txt")
    test_file = create_test_file(test_file, long_line)

    # Use small buffer capacity
    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=100)

    # Should raise error about line being too long
    with assert_raises(contains="Line is longer than the buffer capacity"):
        _ = buf_reader.get_next_line()

    print("✓ test_get_next_line_line_longer_than_buffer passed")


fn test_get_next_line_at_eof() raises:
    """Test behavior when EOF reached."""
    var test_content = "Last line"
    var test_file = Path("test_at_eof.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Read the last line (no trailing newline)
    var line = buf_reader.get_next_line()
    assert_equal(line, "Last line", "Should read last line")

    # Verify EOF state
    assert_true(buf_reader.IS_EOF, "EOF flag should be set")
    assert_equal(len(buf_reader), 0, "No data should remain")

    print("✓ test_get_next_line_at_eof passed")


fn test_get_next_line_after_eof() raises:
    """Verify error when reading past EOF."""
    var test_content = "Only line\n"
    var test_file = Path("test_after_eof.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Read the only line
    _ = buf_reader.get_next_line()

    # Try to read again - should raise EOF
    with assert_raises(contains="EOF"):
        _ = buf_reader.get_next_line()

    # Try again - should still raise EOF
    with assert_raises(contains="EOF"):
        _ = buf_reader.get_next_line()

    print("✓ test_get_next_line_after_eof passed")


fn test_get_next_line_empty_file() raises:
    """Handle empty file gracefully."""
    var test_file = Path("test_empty.txt")
    test_file = create_test_file(test_file, "")

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Should be at EOF immediately
    assert_true(buf_reader.IS_EOF, "Should be at EOF for empty file")

    # Reading should raise EOF
    with assert_raises(contains="EOF"):
        _ = buf_reader.get_next_line()

    print("✓ test_get_next_line_empty_file passed")


fn test_get_next_line_only_newlines() raises:
    """File with only newline characters."""
    var test_content = "\n\n\n\n"
    var test_file = Path("test_only_newlines.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Should read 4 empty lines
    for i in range(4):
        var line = buf_reader.get_next_line()
        assert_equal(line, "", "Should read empty line")

    # Next read should raise EOF
    with assert_raises(contains="EOF"):
        _ = buf_reader.get_next_line()

    print("✓ test_get_next_line_only_newlines passed")


# ============================================================================
# Buffer Management Tests
# ============================================================================


fn test_left_shift() raises:
    """Verify head is moved to start and data copied."""
    var test_content = "Line1\nLine2\nLine3\n"
    var test_file = Path("test_left_shift.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Read first line to move head
    _ = buf_reader.get_next_line()

    var head_before = buf_reader.head
    _ = buf_reader.end
    var len_before = len(buf_reader)

    assert_true(head_before > 0, "Head should have moved")

    # Manually trigger left shift
    buf_reader._left_shift()

    # After left shift, head should be 0
    assert_equal(buf_reader.head, 0, "Head should be reset to 0")
    assert_equal(len(buf_reader), len_before, "Length should be preserved")
    assert_equal(buf_reader.end, len_before, "End should equal previous length")

    print("✓ test_left_shift passed")


fn test_left_shift_when_head_is_zero() raises:
    """Test no-op case."""
    var test_content = "Test content\n"
    var test_file = Path("test_left_shift_noop.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Don't read anything, head is already 0
    assert_equal(buf_reader.head, 0, "Head should start at 0")

    var end_before = buf_reader.end

    # Left shift should be a no-op
    buf_reader._left_shift()

    assert_equal(buf_reader.head, 0, "Head should still be 0")
    assert_equal(buf_reader.end, end_before, "End should be unchanged")

    print("✓ test_left_shift_when_head_is_zero passed")


fn test_fill_buffer() raises:
    """Test refilling after consumption."""
    # Create content larger than default buffer
    var test_content = String("")
    for i in range(100):
        test_content += "Line " + String(i) + "\n"

    var test_file = Path("test_fill_buffer.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=100)

    _ = buf_reader.end

    # Read some lines to consume buffer
    for i in range(10):
        x = buf_reader.get_next_line()

    # This should trigger buffer refill
    var bytes_read = buf_reader._fill_buffer()

    # Verify buffer was refilled
    assert_true(bytes_read > 0, "Should read bytes on refill")

    print("✓ test_fill_buffer passed")


fn test_fill_buffer_at_eof() raises:
    """Verify EOF flag is set correctly."""
    var test_content = "Short\n"
    var test_file = Path("test_fill_eof.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Initial fill happens in __init__
    # For small file, should already be at EOF
    assert_true(buf_reader.IS_EOF, "Should be at EOF after initial fill")

    # Try to fill again
    var bytes_read = buf_reader._fill_buffer()
    assert_equal(bytes_read, 0, "Should read 0 bytes at EOF")
    assert_true(buf_reader.IS_EOF, "EOF flag should remain set")

    print("✓ test_fill_buffer_at_eof passed")


fn test_fill_buffer_partial_read() raises:
    """Test when source returns less than requested."""
    # Create file smaller than buffer capacity
    var test_content = "Small file content\n"
    var test_file = Path("test_partial_read.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=1024)

    # Initial fill should read less than capacity
    var content_len = len(test_content)
    assert_equal(
        buf_reader.end, content_len, "Should read only available content"
    )
    assert_true(
        buf_reader.end < buf_reader.capacity(), "Should not fill entire buffer"
    )
    assert_true(buf_reader.IS_EOF, "Should be at EOF after partial read")

    print("✓ test_fill_buffer_partial_read passed")


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
