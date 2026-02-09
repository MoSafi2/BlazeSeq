from testing import assert_equal, assert_raises, assert_true, assert_false
from pathlib import Path
from blazeseq.CONSTS import DEFAULT_CAPACITY
from blazeseq.iostream import BufferedReader, FileReader
from blazeseq.parser import _has_more_lines, _get_n_lines, LineIterator
from blazeseq.utils import _strip_spaces
from memory import alloc, Span
from testing import TestSuite


fn create_test_file(path: Path, content: String) raises -> Path:
    """Helper function to create test files."""
    new_path = Path("tests/test_data") / path
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
    assert_equal(
        buf_reader.buffer_position(), 0, "Read position should start at 0"
    )
    assert_true(buf_reader.available() > 0, "Buffer should be initially filled")
    assert_true(
        buf_reader.is_eof(),
        "Should be EOF after initial fill when file fits in buffer",
    )

    print("✓ test_buffered_reader_init passed")


fn test_buffered_reader_initial_fill() raises:
    """Verify buffer fills on init."""
    var test_content = "Initial content for testing\n"
    var test_file = Path("test_initial_fill.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Check that buffer has been filled
    assert_true(
        buf_reader.available() > 0, "Buffer should have data after init"
    )
    assert_true(len(buf_reader) > 0, "Buffer should contain data")
    assert_true(
        len(buf_reader) <= buf_reader.capacity(),
        "Filled data should not exceed capacity",
    )

    # Verify actual content was read
    var expected_len = min(len(test_content), buf_reader.capacity())
    assert_equal(
        buf_reader.available(),
        expected_len,
        "Should read expected amount of data",
    )

    print("✓ test_buffered_reader_initial_fill passed")


fn test_buffered_reader_len() raises:
    """Test __len__ returns correct available bytes."""
    var test_content = "0123456789\n"
    var test_file = Path("test_len.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader[check_ascii=True](reader^)

    # Initial length should match content length (or capacity if smaller)
    var initial_len = len(buf_reader)
    assert_equal(
        initial_len,
        len(test_content),
        "Initial length should match file content",
    )

    # Read a line (via parser helper) and check length decreases
    var lines_one = _get_n_lines[FileReader, 1, True](buf_reader)
    var line = String(unsafe_from_utf8=lines_one[0])
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

    # Test accessing before read position (should fail)
    with assert_raises(contains="Out of bounds"):
        _ = buf_reader[-1]

    # Test accessing at or after end (should fail)
    var end_idx = buf_reader.buffer_position() + buf_reader.available()
    with assert_raises(contains="Out of bounds"):
        _ = buf_reader[end_idx]

    with assert_raises(contains="Out of bounds"):
        _ = buf_reader[end_idx + 10]

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

    # Test slice to end (relative: from offset 5 to end of unconsumed)
    var slice2 = buf_reader[5:]
    assert_equal(
        len(slice2),
        buf_reader.available() - 5,
        "Slice to end should have correct length",
    )

    # Test slice from start
    var slice3 = buf_reader[:4]
    assert_equal(len(slice3), 4, "Slice from start should have length 4")

    print("✓ test_buffered_reader_slice passed")


fn test_buffered_reader_view() raises:
    """Test view() returns span of unconsumed bytes."""
    var test_content = "Span test content\n"
    var test_file = Path("test_as_span.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Get span of available data
    var span = buf_reader.view()

    assert_equal(
        len(span), len(buf_reader), "Span length should match buffer length"
    )
    assert_equal(
        len(span),
        buf_reader.available(),
        "Span should represent available data",
    )
    print(span[0])

    assert_equal(span[0], ord("S"), "First byte should be 'S'")
    assert_equal(span[1], ord("p"), "Second byte should be 'p'")

    print("✓ test_buffered_reader_view passed")

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

    var lines = _get_n_lines[FileReader, 1, False](buf_reader)
    var line = String(unsafe_from_utf8=lines[0])
    assert_equal(line, "Hello World", "Should read line without newline")

    # Next read should raise EOF
    with assert_raises(contains="EOF"):
        var lines = _get_n_lines[FileReader, 1, False](buf_reader)
        _ = lines

    print("✓ test_get_next_line_single_line passed")


fn test_get_next_line_multiple_lines() raises:
    """Read several lines sequentially."""
    var test_content = "Line 1\nLine 2\nLine 3\n"
    var test_file = Path("test_multiple_lines.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var lines1 = _get_n_lines[FileReader, 1, False](buf_reader)
    var line1 = String(unsafe_from_utf8=lines1[0])
    assert_equal(line1, "Line 1", "First line should be 'Line 1'")

    var lines2 = _get_n_lines[FileReader, 1, False](buf_reader)
    var line2 = String(unsafe_from_utf8=lines2[0])
    assert_equal(line2, "Line 2", "Second line should be 'Line 2'")

    var lines3 = _get_n_lines[FileReader, 1, False](buf_reader)
    var line3 = String(unsafe_from_utf8=lines3[0])
    assert_equal(line3, "Line 3", "Third line should be 'Line 3'")

    # Should raise EOF after all lines
    with assert_raises(contains="EOF"):
        var lines = _get_n_lines[FileReader, 1, False](buf_reader)
        _ = lines

    print("✓ test_get_next_line_multiple_lines passed")


fn test_get_next_line_empty_line() raises:
    """Handle empty lines (just newline)."""
    var test_content = "First\n\nThird\n"
    var test_file = Path("test_empty_line.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var lines1 = _get_n_lines[FileReader, 1, False](buf_reader)
    var line1 = String(unsafe_from_utf8=lines1[0])
    assert_equal(line1, "First", "First line should be 'First'")

    var lines2 = _get_n_lines[FileReader, 1, False](buf_reader)
    var line2 = String(unsafe_from_utf8=lines2[0])
    assert_equal(line2, "", "Empty line should be empty string")

    var lines3 = _get_n_lines[FileReader, 1, False](buf_reader)
    var line3 = String(unsafe_from_utf8=lines3[0])
    assert_equal(line3, "Third", "Third line should be 'Third'")

    print("✓ test_get_next_line_empty_line passed")


fn test_get_next_line_no_trailing_newline() raises:
    """Handle last line without newline."""
    var test_content = "Line with newline\nLine without newline"
    var test_file = Path("test_no_trailing.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var lines1 = _get_n_lines[FileReader, 1, False](buf_reader)
    var line1 = String(unsafe_from_utf8=lines1[0])
    assert_equal(line1, "Line with newline", "First line correct")

    var lines2 = _get_n_lines[FileReader, 1, False](buf_reader)
    var line2 = String(unsafe_from_utf8=lines2[0])
    assert_equal(line2, "Line without newline", "Last line without newline")

    print("✓ test_get_next_line_no_trailing_newline passed")


fn test_get_next_line_with_spaces() raises:
    """Verify space stripping works."""
    var test_content = "  Leading spaces\nTrailing spaces  \n  Both sides  \n"
    var test_file = Path("test_spaces.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var lines1 = _get_n_lines[FileReader, 1, False](buf_reader)
    var line1 = String(unsafe_from_utf8=_strip_spaces(lines1[0]))
    assert_equal(line1, "Leading spaces", "Leading spaces stripped")

    var lines2 = _get_n_lines[FileReader, 1, False](buf_reader)
    var line2 = String(unsafe_from_utf8=_strip_spaces(lines2[0]))
    assert_equal(line2, "Trailing spaces", "Trailing spaces stripped")

    var lines3 = _get_n_lines[FileReader, 1, False](buf_reader)
    var line3 = String(unsafe_from_utf8=_strip_spaces(lines3[0]))
    assert_equal(line3, "Both sides", "Both sides stripped")

    print("✓ test_get_next_line_with_spaces passed")


fn test_get_next_line_bytes() raises:
    """Test byte list return variant."""
    var test_content = "Test line\n"
    var test_file = Path("test_bytes.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var lines = _get_n_lines[FileReader, 1, False](buf_reader)
    var line_bytes = List[Byte](lines[0])

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

    var lines = _get_n_lines[FileReader, 1, False](buf_reader)
    var line_span = lines[0]

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
        var lines = _get_n_lines[FileReader, 1, False](buf_reader)
        _ = lines

    print("✓ test_get_next_line_line_longer_than_buffer passed")


fn test_get_next_line_at_eof() raises:
    """Test behavior when EOF reached."""
    var test_content = "Last line"
    var test_file = Path("test_at_eof.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Read the last line (no trailing newline)
    var lines = _get_n_lines[FileReader, 1, False](buf_reader)
    var line = String(unsafe_from_utf8=lines[0])
    assert_equal(line, "Last line", "Should read last line")

    # Verify EOF state
    assert_true(buf_reader.is_eof(), "EOF flag should be set")
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
    _ = _get_n_lines[FileReader, 1, False](buf_reader)

    # Try to read again - should raise EOF
    with assert_raises(contains="EOF"):
        var lines = _get_n_lines[FileReader, 1, False](buf_reader)
        _ = lines

    # Try again - should still raise EOF
    with assert_raises(contains="EOF"):
        var lines = _get_n_lines[FileReader, 1, False](buf_reader)
        _ = lines

    print("✓ test_get_next_line_after_eof passed")


fn test_get_next_line_empty_file() raises:
    """Handle empty file gracefully."""
    var test_file = Path("test_empty.txt")
    test_file = create_test_file(test_file, "")

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Should be at EOF immediately
    assert_true(buf_reader.is_eof(), "Should be at EOF for empty file")

    # Reading should raise EOF
    with assert_raises(contains="EOF"):
        var lines = _get_n_lines[FileReader, 1, False](buf_reader)
        _ = lines

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
        var lines = _get_n_lines[FileReader, 1, False](buf_reader)
        var line = String(unsafe_from_utf8=lines[0])
        assert_equal(line, "", "Should read empty line")

    # Next read should raise EOF
    with assert_raises(contains="EOF"):
        var lines = _get_n_lines[FileReader, 1, False](buf_reader)
        _ = lines

    print("✓ test_get_next_line_only_newlines passed")


fn test_line_iterator_for_loop() raises:
    """LineIterator implements Iterator protocol: for line in line_iter works.
    """
    var test_content = "a\nb\nc\n"
    var test_file = Path("test_line_iter_for.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var line_iter = LineIterator[FileReader, False](reader^)

    var lines = List[String]()
    for line in line_iter:
        lines.append(String(unsafe_from_utf8=line))

    assert_equal(len(lines), 3, "Should yield 3 lines")
    assert_equal(lines[0], "a", "First line")
    assert_equal(lines[1], "b", "Second line")
    assert_equal(lines[2], "c", "Third line")

    print("✓ test_line_iterator_for_loop passed")


# ============================================================================
# Buffer Management Tests
# ============================================================================


fn test_left_shift() raises:
    """Verify read position advances after consuming a line; buffer state is consistent.
    """
    var test_content = "Line1\nLine2\nLine3\n"
    var test_file = Path("test_left_shift.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Read first line (consumes from buffer)
    _ = _get_n_lines[FileReader, 1, False](buf_reader)

    # Read position should have advanced; we can still read next line
    var lines2 = _get_n_lines[FileReader, 1, False](buf_reader)
    var line2 = String(unsafe_from_utf8=lines2[0])
    assert_equal(line2, "Line2", "Should read second line after first")

    print("✓ test_left_shift passed")


fn test_left_shift_when_head_is_zero() raises:
    """Test buffer state when no bytes consumed yet."""
    var test_content = "Test content\n"
    var test_file = Path("test_left_shift_noop.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    assert_equal(
        buf_reader.buffer_position(), 0, "Read position should start at 0"
    )
    assert_true(buf_reader.available() > 0, "Should have data available")

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

    _ = buf_reader.buffer_position() + buf_reader.available()

    # Read some lines to consume buffer (no auto-compact; head advances)
    for i in range(10):
        x = _get_n_lines[FileReader, 1, False](buf_reader)

    # Caller must compact to make room before refill
    buf_reader._compact_from(buf_reader.buffer_position())
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
    assert_true(buf_reader.is_eof(), "Should be at EOF after initial fill")

    assert_true(buf_reader.is_eof(), "EOF flag should remain set")

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
        buf_reader.buffer_position() + buf_reader.available(),
        content_len,
        "Should read only available content",
    )
    assert_true(
        buf_reader.buffer_position() + buf_reader.available()
        < buf_reader.capacity(),
        "Should not fill entire buffer",
    )
    assert_true(buf_reader.is_eof(), "Should be at EOF after partial read")

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
    var lines1 = _get_n_lines[FileReader, 1, True](buf_reader)
    var line1 = String(unsafe_from_utf8=lines1[0])
    assert_equal(line1, "Valid ASCII content", "Should read valid ASCII")

    var lines2 = _get_n_lines[FileReader, 1, True](buf_reader)
    var line2 = String(unsafe_from_utf8=lines2[0])
    assert_equal(line2, "Line 2", "Should read second line")

    print("✓ test_buffered_reader_ascii_validation passed")


fn test_buffered_reader_ascii_validation_invalid() raises:
    """Test ASCII validation raises error on non-ASCII bytes."""
    # Create file with non-ASCII bytes (byte > 127)
    # We'll write bytes directly to create non-ASCII content
    var test_file = Path("test_ascii_invalid.txt")
    new_path = Path("tests/test_data") / test_file

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
        var lines = _get_n_lines[FileReader, 1, True](buf_reader)
        _ = lines

    # Should work fine when check_ascii=False
    var reader2 = FileReader(new_path)
    var buf_reader2 = BufferedReader[check_ascii=False](reader2^)
    _ = _get_n_lines[FileReader, 1, False](buf_reader2)

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

    # Read a line to move head
    _ = _get_n_lines[FileReader, 1, False](buf_reader)

    print("✓ test_buffered_reader_usable_space passed")


fn test_buffered_reader_uninitialized_space() raises:
    """Test uninitialized space calculation."""
    var test_content = "Short\n"
    var test_file = Path("test_uninitialized_space.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=100)

    # Uninitialized space should be capacity - end
    var expected = (
        buf_reader.capacity()
        - buf_reader.buffer_position()
        + buf_reader.available()
    )

    # After reading, end changes but calculation should still hold
    _ = _get_n_lines[FileReader, 1, False](buf_reader)
    var expected_after = (
        buf_reader.capacity()
        - buf_reader.buffer_position()
        + buf_reader.available()
    )
    print("✓ test_buffered_reader_uninitialized_space passed")


fn test_buffered_reader_has_more_lines() raises:
    """Test line availability detection."""
    var test_content = "Line 1\nLine 2\nLine 3\n"
    var test_file = Path("test_has_more_lines.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Should have more lines initially
    assert_true(_has_more_lines(buf_reader), "Should have more lines initially")

    # Read first line
    _ = _get_n_lines[FileReader, 1, False](buf_reader)
    assert_true(_has_more_lines(buf_reader), "Should still have more lines")

    # Read second line
    _ = _get_n_lines[FileReader, 1, False](buf_reader)
    assert_true(_has_more_lines(buf_reader), "Should still have more lines")

    # Read third line
    _ = _get_n_lines[FileReader, 1, False](buf_reader)
    assert_false(
        _has_more_lines(buf_reader),
        "Should not have more lines after reading all",
    )

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
    var original_end = buf_reader.buffer_position() + buf_reader.available()

    # Resize buffer
    buf_reader.grow_buffer(50, 1000)

    # Capacity should increase
    assert_true(
        buf_reader.capacity() > original_capacity, "Capacity should increase"
    )
    assert_equal(
        buf_reader.capacity(),
        original_capacity + 50,
        "Capacity should increase by specified amount",
    )

    # End should remain the same (data preserved)
    assert_equal(
        buf_reader.buffer_position() + buf_reader.available(),
        original_end,
        "End should remain unchanged",
    )

    print("✓ test_buffered_reader_resize_buf passed")


fn test_buffered_reader_resize_buf_max_capacity() raises:
    """Test buffer resize error at max capacity."""
    var test_content = "Test content\n"
    var test_file = Path("test_resize_max_capacity.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=100)

    # Try to resize when already at max capacity
    with assert_raises(contains="Buffer already at max capacity"):
        buf_reader.grow_buffer(50, 100)

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
    assert_equal(
        String(output), test_content, "Written content should match original"
    )

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
    assert_equal(
        str_repr,
        test_content,
        "String representation should match buffer content",
    )

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
    while _has_more_lines(buf_reader):
        try:
            var line_lines = _get_n_lines[FileReader, 1, False](buf_reader)
            _ = line_lines
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
    while _has_more_lines(buf_reader):
        try:
            var line_arr = _get_n_lines[FileReader, 1, False](buf_reader)
            var line = String(unsafe_from_utf8=line_arr[0])
            lines.append(line)
        except:
            break

    # Verify we read all lines correctly
    assert_equal(len(lines), 150, "Should read all 150 lines")
    assert_equal(
        lines[0], "Line 0 with some content", "First line should be correct"
    )
    assert_equal(
        lines[149], "Line 149 with some content", "Last line should be correct"
    )

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
    # Create a buffer using Span
    var ptr = alloc[Byte](100)
    var buffer = Span[Byte, MutExternalOrigin](ptr=ptr, length=100)

    # Read to buffer
    var bytes_read = reader.read_to_buffer(buffer, len(test_content), 0)
    assert_equal(
        Int(bytes_read), len(test_content), "Should read correct amount"
    )

    # Verify content was read
    assert_equal(ptr[0], ord("T"), "First byte should be 'T'")
    assert_equal(ptr[1], ord("e"), "Second byte should be 'e'")

    ptr.free()

    print("✓ test_file_reader_read_to_buffer passed")


fn test_file_reader_read_to_buffer_errors() raises:
    """Test FileReader read_to_buffer error cases."""
    var test_content = "Test content\n"
    var test_file = Path("test_read_to_buffer_errors.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    # Create a buffer using Span
    var ptr = alloc[Byte](10)
    var buffer = Span[Byte, MutExternalOrigin](ptr=ptr, length=10)

    # Test negative amount
    with assert_raises(contains="should be positive"):
        _ = reader.read_to_buffer(buffer, -1, 0)

    # Test amount larger than available space
    with assert_raises(contains="bigger than the available space"):
        _ = reader.read_to_buffer(buffer, 100, 0)

    ptr.free()

    print("✓ test_file_reader_read_to_buffer_errors passed")


# ============================================================================
# InnerBuffer Tests - REMOVED
# InnerBuffer has been merged into BufferedReader.
# Buffer functionality is now tested through BufferedReader tests.
# ============================================================================


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

    # Test slice with step (BufferedReader raises; step > 1 not supported)
    with assert_raises(contains="Step loading is not supported"):
        _ = buf_reader[0:10:2]

    # Test slice beyond buffer end (BufferedReader raises Out of bounds)
    with assert_raises(contains="Out of bounds"):
        _ = buf_reader[0:1000]  # end beyond available()

    # Test empty slice
    var empty_slice = buf_reader[5:5]
    assert_equal(len(empty_slice), 0, "Empty slice should have length 0")

    # Test single element slice
    var single_slice = buf_reader[0:1]
    assert_equal(
        len(single_slice), 1, "Single element slice should have length 1"
    )
    assert_equal(single_slice[0], ord("0"), "Should contain correct byte")

    _ = single_slice
    _ = buf_reader
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
    assert_equal(
        buf_reader2.capacity(), 1000, "Should use custom large capacity"
    )

    # Test capacity equal to content length
    var test_file3 = Path("test_custom_capacity_exact.txt")
    test_file3 = create_test_file(test_file3, test_content)
    var reader3 = FileReader(test_file3)
    var buf_reader3 = BufferedReader(reader3^, capacity=len(test_content))
    assert_equal(
        buf_reader3.capacity(), len(test_content), "Should use exact capacity"
    )

    print("✓ test_buffered_reader_custom_capacity_edge_cases passed")


# ============================================================================
# get_n_lines Tests
# ============================================================================


fn test_get_n_lines_basic() raises:
    """Read N lines when all fit in buffer."""
    var test_content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n"
    var test_file = Path("test_get_n_lines_basic.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Read 3 lines
    var lines = _get_n_lines[FileReader, 3, False](buf_reader)
    assert_equal(len(lines), 3, "Should return 3 lines")
    assert_equal(
        String(unsafe_from_utf8=lines[0]), "Line 1", "First line correct"
    )
    assert_equal(
        String(unsafe_from_utf8=lines[1]), "Line 2", "Second line correct"
    )
    assert_equal(
        String(unsafe_from_utf8=lines[2]), "Line 3", "Third line correct"
    )

    # Verify head is positioned correctly
    var next_lines = _get_n_lines[FileReader, 1, False](buf_reader)
    var next_line = String(unsafe_from_utf8=next_lines[0])
    assert_equal(next_line, "Line 4", "Next line should be Line 4")

    print("✓ test_get_n_lines_basic passed")


fn test_get_n_lines_exact_buffer() raises:
    """Read exactly N lines that fit perfectly in buffer."""
    var test_content = "A\nB\nC\n"
    var test_file = Path("test_get_n_lines_exact_buffer.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Read all 3 lines
    var lines = _get_n_lines[FileReader, 3, False](buf_reader)
    assert_equal(len(lines), 3, "Should return 3 lines")
    assert_equal(String(unsafe_from_utf8=lines[0]), "A", "First line correct")
    assert_equal(String(unsafe_from_utf8=lines[1]), "B", "Second line correct")
    assert_equal(String(unsafe_from_utf8=lines[2]), "C", "Third line correct")
    _ = buf_reader
    print("✓ test_get_n_lines_exact_buffer passed")


fn test_get_n_lines_empty_lines() raises:
    """Handle empty lines correctly."""
    var test_content = "Line 1\n\nLine 3\n\n"
    var test_file = Path("test_get_n_lines_empty_lines.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Read 4 lines including empty ones
    var lines = _get_n_lines[FileReader, 4, False](buf_reader)
    assert_equal(len(lines), 4, "Should return 4 lines")
    assert_equal(
        String(unsafe_from_utf8=lines[0]), "Line 1", "First line correct"
    )
    assert_equal(
        String(unsafe_from_utf8=lines[1]), "", "Second line should be empty"
    )
    assert_equal(
        String(unsafe_from_utf8=lines[2]), "Line 3", "Third line correct"
    )
    assert_equal(
        String(unsafe_from_utf8=lines[3]), "", "Fourth line should be empty"
    )

    _ = buf_reader
    print("✓ test_get_n_lines_empty_lines passed")


fn test_get_n_lines_spans_buffer_boundary() raises:
    """Read N lines that require buffer shift."""
    # Create content that will require buffer shift
    var test_content = String("")
    for i in range(20):
        test_content += "Line " + String(i) + "\n"

    var test_file = Path("test_get_n_lines_spans_buffer_boundary.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    # Use small buffer to force boundary crossing
    var buf_reader = BufferedReader(reader^, capacity=50)

    # Read 5 lines that will span buffer boundary
    var lines = _get_n_lines[FileReader, 5, False](buf_reader)
    assert_equal(len(lines), 5, "Should return 5 lines")
    assert_equal(
        String(unsafe_from_utf8=lines[0]), "Line 0", "First line correct"
    )
    assert_equal(
        String(unsafe_from_utf8=lines[4]), "Line 4", "Last line correct"
    )

    # Verify we can continue reading
    var next_lines = _get_n_lines[FileReader, 1, False](buf_reader)
    var next_line = String(unsafe_from_utf8=next_lines[0])
    assert_equal(next_line, "Line 5", "Next line should be Line 5")

    _ = buf_reader
    print("✓ test_get_n_lines_spans_buffer_boundary passed")


fn test_get_n_lines_multiple_shifts() raises:
    """Read N lines requiring multiple buffer fills."""
    var test_content = String("")
    for i in range(30):
        test_content += "Line " + String(i) + " with some content\n"

    var test_file = Path("test_get_n_lines_multiple_shifts.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    # Use buffer that can hold ~3-4 lines to force multiple shifts
    # Each line is ~30 bytes, so 10 lines need ~300 bytes
    # Buffer of 150 bytes can hold ~5 lines, requiring multiple refills for 10 lines
    # But must be large enough to hold all 10 lines after shifting (need at least 300 bytes)
    # Actually, the buffer needs to be able to hold all lines being read, so use 350 bytes
    var buf_reader = BufferedReader(reader^, capacity=350)

    # Read 10 lines that will require multiple shifts
    var lines = _get_n_lines[FileReader, 10, False](buf_reader)
    assert_equal(len(lines), 10, "Should return 10 lines")
    assert_equal(
        String(unsafe_from_utf8=lines[0]),
        "Line 0 with some content",
        "First line correct",
    )
    assert_equal(
        String(unsafe_from_utf8=lines[9]),
        "Line 9 with some content",
        "Last line correct",
    )

    _ = buf_reader
    print("✓ test_get_n_lines_multiple_shifts passed")


fn test_get_n_lines_large_n() raises:
    """Read many lines."""
    var test_content = String("")
    for i in range(50):
        test_content += "Line " + String(i) + "\n"

    var test_file = Path("test_get_n_lines_large_n.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Read 20 lines
    var lines = _get_n_lines[FileReader, 20, False](buf_reader)
    assert_equal(len(lines), 20, "Should return 20 lines")
    assert_equal(
        String(unsafe_from_utf8=lines[0]), "Line 0", "First line correct"
    )
    assert_equal(
        String(unsafe_from_utf8=lines[19]), "Line 19", "Last line correct"
    )

    _ = buf_reader
    print("✓ test_get_n_lines_large_n passed")


fn test_get_n_lines_eof_before_n() raises:
    """EOF reached before getting N lines (should raise error)."""
    var test_content = "Line 1\nLine 2\n"
    var test_file = Path("test_get_n_lines_eof_before_n.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Try to read 5 lines when only 2 exist
    with assert_raises(
        contains="EOF reached before getting all requested lines"
    ):
        _ = _get_n_lines[FileReader, 5, False](buf_reader)

    _ = buf_reader
    print("✓ test_get_n_lines_eof_before_n passed")


fn test_get_n_lines_no_trailing_newline() raises:
    """Last line without newline."""
    var test_content = "Line 1\nLine 2\nLine 3"
    var test_file = Path("test_get_n_lines_no_trailing_newline.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Read all 3 lines
    var lines = _get_n_lines[FileReader, 3, False](buf_reader)
    assert_equal(len(lines), 3, "Should return 3 lines")
    assert_equal(
        String(unsafe_from_utf8=lines[0]), "Line 1", "First line correct"
    )
    assert_equal(
        String(unsafe_from_utf8=lines[1]), "Line 2", "Second line correct"
    )
    assert_equal(
        String(unsafe_from_utf8=lines[2]),
        "Line 3",
        "Last line without newline correct",
    )

    _ = buf_reader
    print("✓ test_get_n_lines_no_trailing_newline passed")


fn test_get_n_lines_single_line() raises:
    """Test reading a single line (n=1 case)."""
    var test_content = "Single line\n"
    var test_file = Path("test_get_n_lines_single_line.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Read 1 line
    var lines = _get_n_lines[FileReader, 1, False](buf_reader)
    assert_equal(len(lines), 1, "Should return 1 line")
    assert_equal(
        String(unsafe_from_utf8=lines[0]), "Single line", "Line correct"
    )

    _ = buf_reader
    print("✓ test_get_n_lines_single_line passed")


fn test_get_n_lines_all_remaining() raises:
    """Read all remaining lines in file."""
    var test_content = "Line 1\nLine 2\nLine 3\nLine 4\n"
    var test_file = Path("test_get_n_lines_all_remaining.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Read first line
    _ = _get_n_lines[FileReader, 1, False](buf_reader)

    # Read all remaining 3 lines
    var lines = _get_n_lines[FileReader, 3, False](buf_reader)
    assert_equal(len(lines), 3, "Should return 3 lines")
    assert_equal(
        String(unsafe_from_utf8=lines[0]), "Line 2", "First line correct"
    )
    assert_equal(
        String(unsafe_from_utf8=lines[2]), "Line 4", "Last line correct"
    )

    _ = buf_reader
    print("✓ test_get_n_lines_all_remaining passed")


fn test_get_n_lines_preserves_buffer() raises:
    """Verify earlier lines remain in buffer."""
    var test_content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n"
    var test_file = Path("test_get_n_lines_preserves_buffer.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Read 3 lines
    var lines = _get_n_lines[FileReader, 3, False](buf_reader)
    assert_equal(len(lines), 3, "Should return 3 lines")

    # Verify the spans still reference valid buffer positions
    # by checking their content
    assert_equal(
        String(unsafe_from_utf8=lines[0]), "Line 1", "First span valid"
    )
    assert_equal(
        String(unsafe_from_utf8=lines[1]), "Line 2", "Second span valid"
    )
    assert_equal(
        String(unsafe_from_utf8=lines[2]), "Line 3", "Third span valid"
    )

    # Verify we can continue reading
    var next_lines = _get_n_lines[FileReader, 1, False](buf_reader)
    var next_line = String(unsafe_from_utf8=next_lines[0])
    assert_equal(next_line, "Line 4", "Can continue reading after get_n_lines")

    _ = buf_reader
    print("✓ test_get_n_lines_preserves_buffer passed")


fn test_get_n_lines_head_position() raises:
    """Verify head is correctly positioned after reading."""
    var test_content = "Line 1\nLine 2\nLine 3\nLine 4\n"
    var test_file = Path("test_get_n_lines_head_position.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var head_before = buf_reader.buffer_position()

    # Read 2 lines
    var lines = _get_n_lines[FileReader, 2, False](buf_reader)
    assert_equal(len(lines), 2, "Should return 2 lines")

    # Head should have advanced
    assert_true(
        buf_reader.buffer_position() > head_before, "Head should have advanced"
    )

    # Next read should continue from correct position
    var next_lines = _get_n_lines[FileReader, 1, False](buf_reader)
    var next_line = String(unsafe_from_utf8=next_lines[0])
    assert_equal(next_line, "Line 3", "Next line should be Line 3")

    _ = buf_reader
    print("✓ test_get_n_lines_head_position passed")


fn test_get_n_lines_span_references() raises:
    """Verify returned spans reference correct buffer positions."""
    var test_content = "Line 1\nLine 2\nLine 3\n"
    var test_file = Path("test_get_n_lines_span_references.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Read 2 lines
    var lines = _get_n_lines[FileReader, 2, False](buf_reader)
    assert_equal(len(lines), 2, "Should return 2 lines")

    # Verify spans have correct content
    var line1_str = String(unsafe_from_utf8=lines[0])
    var line2_str = String(unsafe_from_utf8=lines[1])
    assert_equal(line1_str, "Line 1", "First span content correct")
    assert_equal(line2_str, "Line 2", "Second span content correct")

    # Verify spans are non-empty
    assert_true(len(lines[0]) > 0, "First span should not be empty")
    assert_true(len(lines[1]) > 0, "Second span should not be empty")

    _ = buf_reader
    print("✓ test_get_n_lines_span_references passed")


fn test_get_n_lines_zero() raises:
    """Test n=0 case (should return empty list)."""
    var test_content = "Line 1\nLine 2\n"
    var test_file = Path("test_get_n_lines_zero.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Read 0 lines
    var lines = _get_n_lines[FileReader, 0, False](buf_reader)
    assert_equal(len(lines), 0, "Should return empty list")

    # Should still be able to read normally
    var next_lines = _get_n_lines[FileReader, 1, False](buf_reader)
    var next_line = String(unsafe_from_utf8=next_lines[0])
    assert_equal(next_line, "Line 1", "Should still be able to read after n=0")

    _ = buf_reader
    print("✓ test_get_n_lines_zero passed")


fn test_get_n_lines_spans_valid_after_refill() raises:
    """Verify spans remain valid after buffer shift and refill."""
    # Create content that will require buffer shift
    var test_content = String("")
    for i in range(15):
        test_content += "Line " + String(i) + " with content\n"

    var test_file = Path("test_get_n_lines_spans_valid_after_refill.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    # Use buffer that can hold ~2-3 lines to force refill during reading
    # Each line is ~25 bytes, so 5 lines need ~125 bytes
    # Buffer must be large enough to hold all 5 lines after shifting
    # Use 150 bytes to ensure we can fit all 5 lines
    var buf_reader = BufferedReader(reader^, capacity=150)

    # Read 5 lines that will require buffer shift and refill
    var lines = _get_n_lines[FileReader, 5, False](buf_reader)
    assert_equal(len(lines), 5, "Should return 5 lines")

    # Verify all spans are valid and contain correct content
    # This is critical - spans should remain valid even after buffer shift
    assert_equal(
        String(unsafe_from_utf8=lines[0]),
        "Line 0 with content",
        "First span valid after refill",
    )
    assert_equal(
        String(unsafe_from_utf8=lines[1]),
        "Line 1 with content",
        "Second span valid after refill",
    )
    assert_equal(
        String(unsafe_from_utf8=lines[2]),
        "Line 2 with content",
        "Third span valid after refill",
    )
    assert_equal(
        String(unsafe_from_utf8=lines[3]),
        "Line 3 with content",
        "Fourth span valid after refill",
    )
    assert_equal(
        String(unsafe_from_utf8=lines[4]),
        "Line 4 with content",
        "Fifth span valid after refill",
    )

    # Verify we can continue reading correctly
    var next_lines = _get_n_lines[FileReader, 1, False](buf_reader)
    var next_line = String(unsafe_from_utf8=next_lines[0])
    assert_equal(
        next_line, "Line 5 with content", "Can continue reading after refill"
    )

    _ = buf_reader
    print("✓ test_get_n_lines_spans_valid_after_refill passed")


fn test_get_n_lines_restarts_after_refill() raises:
    """Verify that reading restarts from beginning after refill."""
    # Create content where first few lines fit, but later lines need refill
    var test_content = String("")
    for i in range(20):
        test_content += "Line " + String(i) + "\n"

    var test_file = Path("test_get_n_lines_restarts_after_refill.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    # Use buffer that can hold ~3 lines, so reading 5 lines will need refill
    var buf_reader = BufferedReader(reader^, capacity=40)

    # Read 5 lines - this will trigger refill and restart
    var lines = _get_n_lines[FileReader, 5, False](buf_reader)
    assert_equal(len(lines), 5, "Should return 5 lines")

    # All lines should be correct, even though refill happened
    for i in range(5):
        var expected = "Line " + String(i)
        assert_equal(
            String(unsafe_from_utf8=lines[i]),
            expected,
            "Line " + String(i) + " should be correct after restart",
        )

    # Verify spans are all valid and in order
    assert_equal(
        String(unsafe_from_utf8=lines[0]), "Line 0", "First line correct"
    )
    assert_equal(
        String(unsafe_from_utf8=lines[4]), "Line 4", "Last line correct"
    )

    _ = buf_reader
    print("✓ test_get_n_lines_restarts_after_refill passed")


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
