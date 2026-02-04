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


# ============================================================================
# ASCII Validation Tests
# ============================================================================


fn test_buffered_reader_ascii_validation() raises:
    """Test ASCII validation with valid ASCII content."""
    var test_content = "Valid ASCII content\nLine 2\nLine 3\n"
    var test_file = Path("test_ascii_valid.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader[check_ascii=True](reader^)

    # Should read without errors
    var line1 = buf_reader.get_next_line()
    assert_equal(line1, "Valid ASCII content", "Should read valid ASCII")

    var line2 = buf_reader.get_next_line()
    assert_equal(line2, "Line 2", "Should read second line")

    print("✓ test_buffered_reader_ascii_validation passed")


fn test_buffered_reader_ascii_validation_invalid() raises:
    """Test ASCII validation raises error on non-ASCII bytes."""
    # Create file with non-ASCII bytes (byte > 127)
    # We'll write bytes directly to create non-ASCII content
    var test_file = Path("test_ascii_invalid.txt")
    new_path = Path("test/test_data") / test_file
    
    # Write non-ASCII bytes directly
    var non_ascii_bytes = List[Byte]()
    non_ascii_bytes.append(ord("A"))
    non_ascii_bytes.append(ord("B"))
    non_ascii_bytes.append(Byte(200))  # Non-ASCII byte
    non_ascii_bytes.append(ord("\n"))
    
    with open(new_path, "w") as f:
        f.write_bytes(non_ascii_bytes)

    var reader = FileReader(new_path)
    
    # Should raise error when check_ascii=True
    with assert_raises(contains="Non ASCII letters found"):
        var buf_reader = BufferedReader[check_ascii=True](reader^)
        _ = buf_reader.get_next_line()

    # Should work fine when check_ascii=False
    var reader2 = FileReader(new_path)
    var buf_reader2 = BufferedReader[check_ascii=False](reader2^)
    _ = buf_reader2.get_next_line()

    print("✓ test_buffered_reader_ascii_validation_invalid passed")


# ============================================================================
# Utility Method Tests
# ============================================================================


fn test_buffered_reader_usable_space() raises:
    """Test usable space calculation."""
    var test_content = "Test content for usable space\n"
    var test_file = Path("test_usable_space.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=100)

    # Initially, usable space should be capacity (head=0, end < capacity)
    var initial_usable = buf_reader.usable_space()
    assert_true(initial_usable >= buf_reader.capacity() - buf_reader.head, "Usable space should be >= capacity initially")

    # Read a line to move head
    _ = buf_reader.get_next_line()

    # After reading, usable space should be uninatialized_space + head
    var expected_usable = buf_reader.uninatialized_space() + buf_reader.head
    assert_equal(buf_reader.usable_space(), expected_usable, "Usable space should match calculation")

    print("✓ test_buffered_reader_usable_space passed")


fn test_buffered_reader_uninitialized_space() raises:
    """Test uninitialized space calculation."""
    var test_content = "Short\n"
    var test_file = Path("test_uninitialized_space.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=100)

    # Uninitialized space should be capacity - end
    var expected = buf_reader.capacity() - buf_reader.end
    assert_equal(buf_reader.uninatialized_space(), expected, "Uninitialized space should be capacity - end")

    # After reading, end changes but calculation should still hold
    _ = buf_reader.get_next_line()
    var expected_after = buf_reader.capacity() - buf_reader.end
    assert_equal(buf_reader.uninatialized_space(), expected_after, "Uninitialized space should update correctly")

    print("✓ test_buffered_reader_uninitialized_space passed")


fn test_buffered_reader_has_more_lines() raises:
    """Test line availability detection."""
    var test_content = "Line 1\nLine 2\nLine 3\n"
    var test_file = Path("test_has_more_lines.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Should have more lines initially
    assert_true(buf_reader.has_more_lines(), "Should have more lines initially")

    # Read first line
    _ = buf_reader.get_next_line()
    assert_true(buf_reader.has_more_lines(), "Should still have more lines")

    # Read second line
    _ = buf_reader.get_next_line()
    assert_true(buf_reader.has_more_lines(), "Should still have more lines")

    # Read third line
    _ = buf_reader.get_next_line()
    assert_false(buf_reader.has_more_lines(), "Should not have more lines after reading all")

    print("✓ test_buffered_reader_has_more_lines passed")


# ============================================================================
# Buffer Resize Tests
# ============================================================================


fn test_buffered_reader_resize_buf() raises:
    """Test buffer resizing functionality."""
    var test_content = "Test content for resize\n"
    var test_file = Path("test_resize_buf.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=100)

    var original_capacity = buf_reader.capacity()
    var original_end = buf_reader.end

    # Resize buffer
    buf_reader._resize_buf(50, 1000)

    # Capacity should increase
    assert_true(buf_reader.capacity() > original_capacity, "Capacity should increase")
    assert_equal(buf_reader.capacity(), original_capacity + 50, "Capacity should increase by specified amount")

    # End should remain the same (data preserved)
    assert_equal(buf_reader.end, original_end, "End should remain unchanged")

    print("✓ test_buffered_reader_resize_buf passed")


fn test_buffered_reader_resize_buf_max_capacity() raises:
    """Test buffer resize error at max capacity."""
    var test_content = "Test content\n"
    var test_file = Path("test_resize_max_capacity.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=100)

    # Try to resize when already at max capacity
    with assert_raises(contains="Buffer is at max capacity"):
        buf_reader._resize_buf(50, 100)

    print("✓ test_buffered_reader_resize_buf_max_capacity passed")


# ============================================================================
# Writer Interface Tests
# ============================================================================


fn test_buffered_reader_write_to() raises:
    """Test writing buffer content to Writer."""
    var test_content = "Content to write\n"
    var test_file = Path("test_write_to.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Write buffer content to String
    var output = String()
    buf_reader.write_to(output)

    # Verify content was written
    assert_true(len(output) > 0, "Output should contain data")
    assert_equal(String(output), test_content, "Written content should match original")

    print("✓ test_buffered_reader_write_to passed")


fn test_buffered_reader_str() raises:
    """Test string representation of buffer."""
    var test_content = "String representation test\n"
    var test_file = Path("test_str.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Get string representation
    var str_repr = buf_reader.__str__()

    # Verify it matches buffer content
    assert_equal(str_repr, test_content, "String representation should match buffer content")

    print("✓ test_buffered_reader_str passed")


# ============================================================================
# Large File Tests
# ============================================================================


fn test_buffered_reader_large_file_multiple_fills() raises:
    """Test multiple buffer fills with large file."""
    # Create content larger than buffer capacity
    var test_content = String("")
    for i in range(200):
        test_content += "Line " + String(i) + "\n"

    var test_file = Path("test_large_file_multiple_fills.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=100)

    # Read lines, which should trigger multiple buffer fills
    var line_count = 0
    while buf_reader.has_more_lines():
        try:
            _ = buf_reader.get_next_line()
            line_count += 1
        except:
            break

    # Should have read all lines
    assert_equal(line_count, 200, "Should read all 200 lines")

    print("✓ test_buffered_reader_large_file_multiple_fills passed")


fn test_buffered_reader_sequential_reading_large_file() raises:
    """Test sequential reading across buffer boundaries."""
    # Create content that spans multiple buffer fills
    var test_content = String("")
    for i in range(150):
        test_content += "Line " + String(i) + " with some content\n"

    var test_file = Path("test_sequential_reading_large.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=200)

    # Read lines sequentially
    var lines = List[String]()
    while buf_reader.has_more_lines():
        try:
            var line = buf_reader.get_next_line()
            lines.append(line)
        except:
            break

    # Verify we read all lines correctly
    assert_equal(len(lines), 150, "Should read all 150 lines")
    assert_equal(lines[0], "Line 0 with some content", "First line should be correct")
    assert_equal(lines[149], "Line 149 with some content", "Last line should be correct")

    print("✓ test_buffered_reader_sequential_reading_large_file passed")


# ============================================================================
# FileReader Direct Tests
# ============================================================================


fn test_file_reader_read_bytes() raises:
    """Test FileReader read_bytes method."""
    var test_content = "Test content for read_bytes\n"
    var test_file = Path("test_read_bytes.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)

    # Read all bytes
    var bytes = reader.read_bytes()
    assert_equal(len(bytes), len(test_content), "Should read all bytes")

    # Read specific amount
    var reader2 = FileReader(test_file)
    var bytes2 = reader2.read_bytes(10)
    assert_equal(len(bytes2), 10, "Should read specified amount")

    print("✓ test_file_reader_read_bytes passed")


fn test_file_reader_read_to_buffer() raises:
    """Test FileReader read_to_buffer method."""
    var test_content = "Test content for read_to_buffer\n"
    var test_file = Path("test_read_to_buffer.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buffer = InnerBuffer(100)

    # Read to buffer
    var bytes_read = reader.read_to_buffer(buffer, len(test_content), 0)
    assert_equal(Int(bytes_read), len(test_content), "Should read correct amount")

    # Verify content was read
    assert_equal(buffer[0], ord("T"), "First byte should be 'T'")
    assert_equal(buffer[1], ord("e"), "Second byte should be 'e'")

    print("✓ test_file_reader_read_to_buffer passed")


fn test_file_reader_read_to_buffer_errors() raises:
    """Test FileReader read_to_buffer error cases."""
    var test_content = "Test content\n"
    var test_file = Path("test_read_to_buffer_errors.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buffer = InnerBuffer(10)

    # Test negative amount
    with assert_raises(contains="should be positive"):
        _ = reader.read_to_buffer(buffer, -1, 0)

    # Test amount larger than available space
    with assert_raises(contains="bigger than the available space"):
        _ = reader.read_to_buffer(buffer, 100, 0)

    print("✓ test_file_reader_read_to_buffer_errors passed")


# ============================================================================
# InnerBuffer Tests
# ============================================================================


fn test_inner_buffer_resize() raises:
    """Test InnerBuffer resizing."""
    var buffer = InnerBuffer(10)

    # Set some initial values
    buffer[0] = ord("A")
    buffer[1] = ord("B")

    var original_len = len(buffer)

    # Resize buffer
    _ = buffer.resize(20)

    # Length should increase
    assert_equal(len(buffer), 20, "Length should increase")

    # Original data should be preserved
    assert_equal(buffer[0], ord("A"), "Original data should be preserved")
    assert_equal(buffer[1], ord("B"), "Original data should be preserved")

    # Test resize error with smaller size
    with assert_raises(contains="must be greater than current length"):
        _ = buffer.resize(10)

    print("✓ test_inner_buffer_resize passed")


fn test_inner_buffer_as_span_with_pos() raises:
    """Test InnerBuffer as_span with position parameter."""
    var buffer = InnerBuffer(10)

    # Set some values
    for i in range(10):
        buffer[i] = Byte(ord("A") + i)

    # Get span from position 0
    var span1 = buffer.as_span(0)
    assert_equal(len(span1), 10, "Span from 0 should have full length")

    # Get span from position 5
    var span2 = buffer.as_span(5)
    assert_equal(len(span2), 5, "Span from 5 should have remaining length")
    assert_equal(span2[0], ord("F"), "First element should be 'F'")

    # Test error with invalid position
    with assert_raises(contains="outside the buffer"):
        _ = buffer.as_span(20)

    print("✓ test_inner_buffer_as_span_with_pos passed")


fn test_inner_buffer_setitem() raises:
    """Test InnerBuffer byte assignment."""
    var buffer = InnerBuffer(10)

    # Set values
    buffer[0] = ord("X")
    buffer[5] = ord("Y")
    buffer[9] = ord("Z")

    # Verify values were set
    assert_equal(buffer[0], ord("X"), "First byte should be 'X'")
    assert_equal(buffer[5], ord("Y"), "Middle byte should be 'Y'")
    assert_equal(buffer[9], ord("Z"), "Last byte should be 'Z'")

    # Test bounds checking
    with assert_raises(contains="Out of bounds"):
        buffer[10] = ord("A")

    print("✓ test_inner_buffer_setitem passed")


fn test_inner_buffer_bounds() raises:
    """Test InnerBuffer bounds checking."""
    var buffer = InnerBuffer(10)

    # Valid access
    _ = buffer[0]
    _ = buffer[9]

    # Invalid access - negative index
    with assert_raises(contains="Out of bounds"):
        _ = buffer[-1]

    # Invalid access - beyond length
    with assert_raises(contains="Out of bounds"):
        _ = buffer[10]

    # Invalid access - way beyond length
    with assert_raises(contains="Out of bounds"):
        _ = buffer[100]

    print("✓ test_inner_buffer_bounds passed")


# ============================================================================
# Advanced Edge Cases
# ============================================================================


fn test_buffered_reader_slice_edge_cases() raises:
    """Test slice operations with various edge cases."""
    var test_content = "0123456789ABCDEF\n"
    var test_file = Path("test_slice_edge_cases.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Test slice with step (should fail)
    with assert_raises(contains="Step loading is not supported"):
        _ = buf_reader[0:10:2]

    # Test slice beyond end
    with assert_raises(contains="Out of bounds"):
        _ = buf_reader[0:1000]

    # Test empty slice
    var empty_slice = buf_reader[5:5]
    assert_equal(len(empty_slice), 0, "Empty slice should have length 0")

    # Test single element slice
    var single_slice = buf_reader[0:1]
    assert_equal(len(single_slice), 1, "Single element slice should have length 1")
    assert_equal(single_slice[0], ord("0"), "Should contain correct byte")

    print("✓ test_buffered_reader_slice_edge_cases passed")


fn test_buffered_reader_custom_capacity_edge_cases() raises:
    """Test various custom capacity scenarios."""
    var test_content = "Test content\n"
    
    # Test very small capacity
    var test_file1 = Path("test_custom_capacity_small.txt")
    test_file1 = create_test_file(test_file1, test_content)
    var reader1 = FileReader(test_file1)
    var buf_reader1 = BufferedReader(reader1^, capacity=10)
    assert_equal(buf_reader1.capacity(), 10, "Should use custom small capacity")

    # Test larger capacity
    var test_file2 = Path("test_custom_capacity_large.txt")
    test_file2 = create_test_file(test_file2, test_content)
    var reader2 = FileReader(test_file2)
    var buf_reader2 = BufferedReader(reader2^, capacity=1000)
    assert_equal(buf_reader2.capacity(), 1000, "Should use custom large capacity")

    # Test capacity equal to content length
    var test_file3 = Path("test_custom_capacity_exact.txt")
    test_file3 = create_test_file(test_file3, test_content)
    var reader3 = FileReader(test_file3)
    var buf_reader3 = BufferedReader(reader3^, capacity=len(test_content))
    assert_equal(buf_reader3.capacity(), len(test_content), "Should use exact capacity")

    print("✓ test_buffered_reader_custom_capacity_edge_cases passed")


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
