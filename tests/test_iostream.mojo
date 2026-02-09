from testing import assert_equal, assert_raises, assert_true, assert_false
from pathlib import Path
from blazeseq.CONSTS import DEFAULT_CAPACITY
from blazeseq.iostream import BufferedReader
from blazeseq.readers import FileReader
from memory import alloc, Span
from testing import TestSuite


fn create_test_file(path: Path, content: String) raises -> Path:
    """Helper function to create test files."""
    new_path = Path("tests/test_data") / path
    with open(new_path, "w") as f:
        f.write(content)

    return new_path


# ============================================================================
# Initialization Tests
# ============================================================================


fn test_buffered_reader_init() raises:
    """Verify initialization with default capacity."""
    var test_file = Path("test_init.txt")
    test_file = create_test_file(test_file, "Hello World\n")

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

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


fn test_buffered_reader_init_custom_capacity() raises:
    """Verify initialization with custom capacity."""
    var test_content = "Test content\n"
    var test_file = Path("test_init_custom.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=200)

    assert_equal(buf_reader.capacity(), 200, "Should use custom capacity")
    assert_true(buf_reader.available() > 0, "Buffer should be filled")

    print("✓ test_buffered_reader_init_custom_capacity passed")


fn test_buffered_reader_init_empty_file() raises:
    """Handle empty file initialization."""
    var test_file = Path("test_init_empty.txt")
    test_file = create_test_file(test_file, "")

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    assert_true(buf_reader.is_eof(), "Should be at EOF for empty file")
    assert_equal(buf_reader.available(), 0, "Should have no available bytes")

    print("✓ test_buffered_reader_init_empty_file passed")


# ============================================================================
# Basic Property Tests
# ============================================================================


fn test_buffered_reader_capacity() raises:
    """Test capacity() method."""
    var test_content = "Test content\n"
    var test_file = Path("test_capacity.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=150)

    assert_equal(buf_reader.capacity(), 150, "Should return correct capacity")

    print("✓ test_buffered_reader_capacity passed")


fn test_buffered_reader_available() raises:
    """Test available() method."""
    var test_content = "0123456789\n"
    var test_file = Path("test_available.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var initial_available = buf_reader.available()
    assert_true(initial_available > 0, "Should have available bytes initially")
    assert_equal(initial_available, len(test_content), "Should match content length")

    # Consume some bytes
    buf_reader.consume(5)
    assert_equal(
        buf_reader.available(),
        initial_available - 5,
        "Available should decrease after consume",
    )

    print("✓ test_buffered_reader_available passed")


fn test_buffered_reader_len() raises:
    """Test __len__ returns correct available bytes."""
    var test_content = "0123456789\n"
    var test_file = Path("test_len.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    assert_equal(len(buf_reader), len(test_content), "Length should match content")
    assert_equal(len(buf_reader), buf_reader.available(), "__len__ should equal available()")

    buf_reader.consume(3)
    assert_equal(len(buf_reader), len(test_content) - 3, "Length should decrease after consume")

    print("✓ test_buffered_reader_len passed")


fn test_buffered_reader_buffer_position() raises:
    """Test buffer_position() method."""
    var test_content = "Test content\n"
    var test_file = Path("test_buffer_position.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    assert_equal(
        buf_reader.buffer_position(), 0, "Read position should start at 0"
    )

    buf_reader.consume(5)
    assert_equal(
        buf_reader.buffer_position(), 5, "Read position should advance after consume"
    )

    print("✓ test_buffered_reader_buffer_position passed")


fn test_buffered_reader_stream_position() raises:
    """Test stream_position() method."""
    var test_content = "Test content\n"
    var test_file = Path("test_stream_position.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var initial_pos = buf_reader.stream_position()
    assert_equal(initial_pos, 0, "Stream position should start at 0")

    buf_reader.consume(5)
    assert_equal(
        buf_reader.stream_position(), 5, "Stream position should advance after consume"
    )

    print("✓ test_buffered_reader_stream_position passed")


fn test_buffered_reader_is_eof() raises:
    """Test is_eof() method."""
    var test_content = "Short\n"
    var test_file = Path("test_is_eof.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Small file should be at EOF after initial fill
    assert_true(buf_reader.is_eof(), "Should be at EOF for small file")

    # Large file should not be at EOF initially
    var large_content = String("")
    for i in range(200):
        large_content += "Line " + String(i) + "\n"

    var test_file2 = Path("test_is_eof_large.txt")
    test_file2 = create_test_file(test_file2, large_content)

    var reader2 = FileReader(test_file2)
    var buf_reader2 = BufferedReader(reader2^, capacity=100)

    assert_false(buf_reader2.is_eof(), "Should not be at EOF for large file initially")

    print("✓ test_buffered_reader_is_eof passed")


# ============================================================================
# Consume Tests
# ============================================================================


fn test_buffered_reader_consume() raises:
    """Test consume() method."""
    var test_content = "0123456789\n"
    var test_file = Path("test_consume.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var initial_available = buf_reader.available()
    buf_reader.consume(3)

    assert_equal(
        buf_reader.available(),
        initial_available - 3,
        "Available should decrease after consume",
    )
    assert_equal(buf_reader.buffer_position(), 3, "Buffer position should advance")

    print("✓ test_buffered_reader_consume passed")


fn test_buffered_reader_consume_zero() raises:
    """Test consume(0) is valid."""
    var test_content = "Test\n"
    var test_file = Path("test_consume_zero.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var initial_available = buf_reader.available()
    buf_reader.consume(0)

    assert_equal(
        buf_reader.available(), initial_available, "Available should not change"
    )

    print("✓ test_buffered_reader_consume_zero passed")


fn test_buffered_reader_consume_negative() raises:
    """Test consume() with negative size raises error."""
    var test_content = "Test\n"
    var test_file = Path("test_consume_negative.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    with assert_raises(contains="consume size must be non-negative"):
        buf_reader.consume(-1)

    print("✓ test_buffered_reader_consume_negative passed")


fn test_buffered_reader_consume_too_much() raises:
    """Test consume() exceeding available raises error."""
    var test_content = "Test\n"
    var test_file = Path("test_consume_too_much.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var available = buf_reader.available()
    with assert_raises(contains="Cannot consume"):
        buf_reader.consume(available + 1)

    print("✓ test_buffered_reader_consume_too_much passed")


# ============================================================================
# Ensure Available Tests
# ============================================================================


fn test_buffered_reader_ensure_available() raises:
    """Test ensure_available() method."""
    var test_content = "0123456789\n"
    var test_file = Path("test_ensure_available.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Should succeed when enough bytes available
    var result = buf_reader.ensure_available(5)
    assert_true(result, "Should return True when enough bytes available")
    assert_true(buf_reader.available() >= 5, "Should have at least 5 bytes available")

    print("✓ test_buffered_reader_ensure_available passed")


fn test_buffered_reader_ensure_available_large_file() raises:
    """Test ensure_available() with large file requiring refill."""
    var test_content = String("")
    for i in range(200):
        test_content += "Line " + String(i) + "\n"

    var test_file = Path("test_ensure_available_large.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=100)

    # Consume most of buffer
    buf_reader.consume(90)

    # Request more than available - should trigger refill
    var result = buf_reader.ensure_available(50)
    assert_true(result, "Should return True after refill")
    assert_true(buf_reader.available() >= 50, "Should have at least 50 bytes available")

    print("✓ test_buffered_reader_ensure_available_large_file passed")


fn test_buffered_reader_ensure_available_eof() raises:
    """Test ensure_available() returns False at EOF."""
    var test_content = "Short\n"
    var test_file = Path("test_ensure_available_eof.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Consume all available
    buf_reader.consume(buf_reader.available())

    # Try to ensure more - should return False at EOF
    var result = buf_reader.ensure_available(100)
    assert_false(result, "Should return False when at EOF")

    print("✓ test_buffered_reader_ensure_available_eof passed")


# ============================================================================
# Read Exact Tests
# ============================================================================


fn test_buffered_reader_read_exact() raises:
    """Test read_exact() method."""
    var test_content = "0123456789\n"
    var test_file = Path("test_read_exact.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var bytes = buf_reader.read_exact(5)
    assert_equal(len(bytes), 5, "Should read exactly 5 bytes")
    assert_equal(bytes[0], ord("0"), "First byte should be '0'")
    assert_equal(bytes[4], ord("4"), "Fifth byte should be '4'")

    # Buffer position should have advanced
    assert_equal(buf_reader.buffer_position(), 5, "Buffer position should advance")

    print("✓ test_buffered_reader_read_exact passed")


fn test_buffered_reader_read_exact_zero() raises:
    """Test read_exact(0) returns empty list."""
    var test_content = "Test\n"
    var test_file = Path("test_read_exact_zero.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var bytes = buf_reader.read_exact(0)
    assert_equal(len(bytes), 0, "Should return empty list for size 0")

    print("✓ test_buffered_reader_read_exact_zero passed")


fn test_buffered_reader_read_exact_negative() raises:
    """Test read_exact() with negative size raises error."""
    var test_content = "Test\n"
    var test_file = Path("test_read_exact_negative.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    with assert_raises(contains="read_exact size must be non-negative"):
        _ = buf_reader.read_exact(-1)

    print("✓ test_buffered_reader_read_exact_negative passed")


fn test_buffered_reader_read_exact_eof() raises:
    """Test read_exact() raises error when EOF reached."""
    var test_content = "Short\n"
    var test_file = Path("test_read_exact_eof.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Consume all available
    buf_reader.consume(buf_reader.available())

    # Try to read more - should raise error
    with assert_raises(contains="Unexpected EOF"):
        _ = buf_reader.read_exact(100)

    print("✓ test_buffered_reader_read_exact_eof passed")


fn test_buffered_reader_read_exact_large_file() raises:
    """Test read_exact() with large file requiring refill."""
    var test_content = String("")
    for i in range(200):
        test_content += "Line " + String(i) + "\n"

    var test_file = Path("test_read_exact_large.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=100)

    # Consume most of buffer
    buf_reader.consume(90)

    # Read exact amount that requires refill
    var bytes = buf_reader.read_exact(50)
    assert_equal(len(bytes), 50, "Should read exactly 50 bytes")

    print("✓ test_buffered_reader_read_exact_large_file passed")


# ============================================================================
# View Tests
# ============================================================================


fn test_buffered_reader_view() raises:
    """Test view() returns span of unconsumed bytes."""
    var test_content = "Span test content\n"
    var test_file = Path("test_view.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    var span = buf_reader.view()
    assert_equal(len(span), len(buf_reader), "Span length should match buffer length")
    assert_equal(len(span), buf_reader.available(), "Span should represent available data")
    assert_equal(span[0], ord("S"), "First byte should be 'S'")
    assert_equal(span[1], ord("p"), "Second byte should be 'p'")

    # Consume some bytes
    buf_reader.consume(5)
    var span2 = buf_reader.view()
    assert_equal(len(span2), buf_reader.available(), "Span should reflect consumed bytes")

    print("✓ test_buffered_reader_view passed")


# ============================================================================
# Indexing Tests
# ============================================================================


fn test_buffered_reader_getitem() raises:
    """Test single byte access via __getitem__."""
    var test_content = "ABC\n"
    var test_file = Path("test_getitem.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    assert_equal(buf_reader[0], ord("A"), "First byte should be 'A'")
    assert_equal(buf_reader[1], ord("B"), "Second byte should be 'B'")
    assert_equal(buf_reader[2], ord("C"), "Third byte should be 'C'")
    assert_equal(buf_reader[3], ord("\n"), "Fourth byte should be newline")

    print("✓ test_buffered_reader_getitem passed")


fn test_buffered_reader_getitem_out_of_bounds() raises:
    """Verify bounds checking for __getitem__."""
    var test_file = Path("test_getitem_bounds.txt")
    test_file = create_test_file(test_file, "XYZ\n")

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    with assert_raises(contains="Out of bounds"):
        _ = buf_reader[-1]

    var available = buf_reader.available()
    with assert_raises(contains="Out of bounds"):
        _ = buf_reader[available]

    with assert_raises(contains="Out of bounds"):
        _ = buf_reader[available + 10]

    print("✓ test_buffered_reader_getitem_out_of_bounds passed")


fn test_buffered_reader_getitem_after_consume() raises:
    """Test indexing after consuming bytes."""
    var test_content = "0123456789\n"
    var test_file = Path("test_getitem_after_consume.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    buf_reader.consume(3)
    # After consuming 3 bytes, index 0 should point to what was originally at index 3
    assert_equal(buf_reader[0], ord("3"), "Index 0 should point to consumed position")

    print("✓ test_buffered_reader_getitem_after_consume passed")


# ============================================================================
# Slice Tests
# ============================================================================


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
        buf_reader.available() - 5,
        "Slice to end should have correct length",
    )

    # Test slice from start
    var slice3 = buf_reader[:4]
    assert_equal(len(slice3), 4, "Slice from start should have length 4")

    print("✓ test_buffered_reader_slice passed")


fn test_buffered_reader_slice_edge_cases() raises:
    """Test slice operations with various edge cases."""
    var test_content = "0123456789ABCDEF\n"
    var test_file = Path("test_slice_edge_cases.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Test slice with step (should raise error)
    with assert_raises(contains="Step loading is not supported"):
        _ = buf_reader[0:10:2]

    # Test slice beyond buffer end
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


fn test_buffered_reader_slice_after_consume() raises:
    """Test slicing after consuming bytes."""
    var test_content = "0123456789\n"
    var test_file = Path("test_slice_after_consume.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    buf_reader.consume(3)
    # After consuming 3, slice [0:3] should get bytes 3-5
    var slice = buf_reader[0:3]
    assert_equal(len(slice), 3, "Slice should have correct length")
    assert_equal(slice[0], ord("3"), "First byte should be '3'")

    print("✓ test_buffered_reader_slice_after_consume passed")


# ============================================================================
# Grow Buffer Tests
# ============================================================================


fn test_buffered_reader_grow_buffer() raises:
    """Test grow_buffer() method."""
    var test_content = "Test content for resize\n"
    var test_file = Path("test_grow_buffer.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=100)

    var original_capacity = buf_reader.capacity()
    var original_available = buf_reader.available()

    # Grow buffer
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

    # Available data should be preserved
    assert_equal(
        buf_reader.available(),
        original_available,
        "Available data should be preserved",
    )

    print("✓ test_buffered_reader_grow_buffer passed")


fn test_buffered_reader_grow_buffer_max_capacity() raises:
    """Test grow_buffer() error at max capacity."""
    var test_content = "Test content\n"
    var test_file = Path("test_grow_buffer_max_capacity.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=100)

    # Try to grow when already at max capacity
    with assert_raises(contains="Buffer already at max capacity"):
        buf_reader.grow_buffer(50, 100)

    print("✓ test_buffered_reader_grow_buffer_max_capacity passed")


fn test_buffered_reader_grow_buffer_respects_max() raises:
    """Test grow_buffer() respects max_capacity limit."""
    var test_content = "Test content\n"
    var test_file = Path("test_grow_buffer_respects_max.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=100)

    # Try to grow beyond max - should cap at max
    buf_reader.grow_buffer(1000, 150)
    assert_equal(
        buf_reader.capacity(), 150, "Capacity should be capped at max_capacity"
    )

    print("✓ test_buffered_reader_grow_buffer_respects_max passed")


# ============================================================================
# Writer Interface Tests
# ============================================================================


fn test_buffered_reader_write_to() raises:
    """Test write_to() method."""
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
    """Test __str__() method."""
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


fn test_buffered_reader_write_to_after_consume() raises:
    """Test write_to() after consuming bytes."""
    var test_content = "0123456789\n"
    var test_file = Path("test_write_to_after_consume.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    buf_reader.consume(5)
    var output = String()
    buf_reader.write_to(output)

    # Should only write unconsumed bytes
    assert_equal(String(output), "56789\n", "Should write only unconsumed bytes")

    print("✓ test_buffered_reader_write_to_after_consume passed")


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

    # Should initialize without errors
    assert_true(buf_reader.available() > 0, "Should have available bytes")

    print("✓ test_buffered_reader_ascii_validation passed")


fn test_buffered_reader_ascii_validation_invalid() raises:
    """Test ASCII validation raises error on non-ASCII bytes."""
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
        _ = buf_reader

    # Should work fine when check_ascii=False
    var reader2 = FileReader(new_path)
    var buf_reader2 = BufferedReader[check_ascii=False](reader2^)
    assert_true(buf_reader2.available() > 0, "Should work without ASCII check")

    print("✓ test_buffered_reader_ascii_validation_invalid passed")


# ============================================================================
# Large File Tests
# ============================================================================


fn test_buffered_reader_large_file() raises:
    """Test with large file requiring multiple buffer fills."""
    var test_content = String("")
    for i in range(200):
        test_content += "Line " + String(i) + "\n"

    var test_file = Path("test_large_file.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=100)

    # Initially should not be at EOF
    assert_false(buf_reader.is_eof(), "Should not be at EOF initially")

    # Read all content using read_exact
    var total_read = 0
    while not buf_reader.is_eof() or buf_reader.available() > 0:
        if buf_reader.available() > 0:
            var bytes = buf_reader.read_exact(min(50, buf_reader.available()))
            total_read += len(bytes)
        else:
            if not buf_reader.ensure_available(1):
                break

    assert_true(total_read > 0, "Should read content from large file")

    print("✓ test_buffered_reader_large_file passed")


fn test_buffered_reader_sequential_reading() raises:
    """Test sequential reading across buffer boundaries."""
    var test_content = String("")
    for i in range(150):
        test_content += "Line " + String(i) + " with some content\n"

    var test_file = Path("test_sequential_reading.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^, capacity=200)

    # Read bytes sequentially
    var bytes_read = 0
    while buf_reader.available() > 0 or not buf_reader.is_eof():
        if buf_reader.available() > 0:
            var chunk = buf_reader.read_exact(min(30, buf_reader.available()))
            bytes_read += len(chunk)
        else:
            if not buf_reader.ensure_available(1):
                break

    assert_true(bytes_read > 0, "Should read content sequentially")

    print("✓ test_buffered_reader_sequential_reading passed")


# ============================================================================
# Edge Cases
# ============================================================================


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


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
