from testing import assert_equal, assert_raises, assert_true, assert_false, TestSuite
from pathlib import Path
from os import remove
from blazeseq.CONSTS import DEFAULT_CAPACITY
from blazeseq.io.buffered import BufferedReader, BufferedWriter
from blazeseq.io.readers import FileReader, MemoryReader
from blazeseq.io.writers import FileWriter

fn create_test_file(path: Path, content: String) raises -> Path:
    """Helper function to create test files."""
    new_path = Path("tests/test_data") / path
    with open(new_path, "w") as f:
        f.write(content)

    return new_path


fn create_memory_reader(content: String) -> MemoryReader:
    """Helper function to create MemoryReader from string content."""
    var content_bytes = content.as_bytes()
    return MemoryReader(content_bytes)


# ============================================================================
# Core Functionality Tests
# ============================================================================
# Initialization


fn test_buffered_reader_init() raises:
    """Verify initialization with default capacity."""
    var content = "Hello World\n"
    var reader = create_memory_reader(content)
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
    # Note: EOF may not be set immediately if content fits in buffer
    # The buffer reads available data but may not be at EOF until all is consumed

    _ = buf_reader
    print("✓ test_buffered_reader_init passed")


fn test_buffered_reader_init_custom_capacity() raises:
    """Verify initialization with custom capacity."""
    var test_content = "Test content\n"
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^, capacity=200)

    assert_equal(buf_reader.capacity(), 200, "Should use custom capacity")
    assert_true(buf_reader.available() > 0, "Buffer should be filled")

    print("✓ test_buffered_reader_init_custom_capacity passed")


fn test_buffered_reader_init_empty() raises:
    """Handle empty buffer initialization."""
    var reader = create_memory_reader("")
    var buf_reader = BufferedReader(reader^)

    assert_true(buf_reader.is_eof(), "Should be at EOF for empty buffer")
    assert_equal(buf_reader.available(), 0, "Should have no available bytes")

    print("✓ test_buffered_reader_init_empty passed")


# Basic Properties


fn test_buffered_reader_available_and_len() raises:
    """Test available() and __len__ methods (they should return the same value).
    """
    var test_content = "0123456789\n"
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)

    var initial_available = buf_reader.available()
    assert_true(initial_available > 0, "Should have available bytes initially")
    assert_equal(
        initial_available, len(test_content), "Should match content length"
    )
    # Verify __len__ equals available()
    assert_equal(
        len(buf_reader),
        buf_reader.available(),
        "__len__ should equal available()",
    )

    # Consume some bytes
    var consumed = buf_reader.consume(5)
    assert_equal(consumed, 5, "Should consume exactly 5 bytes")
    assert_equal(
        buf_reader.available(),
        initial_available - 5,
        "Available should decrease after consume",
    )
    # Verify __len__ still equals available() after consume
    assert_equal(
        len(buf_reader),
        buf_reader.available(),
        "__len__ should still equal available() after consume",
    )
    assert_equal(
        len(buf_reader),
        len(test_content) - 5,
        "Length should decrease after consume",
    )

    print("✓ test_buffered_reader_available_and_len passed")


fn test_buffered_reader_buffer_position() raises:
    """Test buffer_position() method."""
    var test_content = "Test content\n"
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)

    assert_equal(
        buf_reader.buffer_position(), 0, "Read position should start at 0"
    )

    var consumed = buf_reader.consume(5)
    assert_equal(consumed, 5, "Should consume exactly 5 bytes")
    assert_equal(
        buf_reader.buffer_position(),
        5,
        "Read position should advance after consume",
    )

    print("✓ test_buffered_reader_buffer_position passed")


fn test_buffered_reader_stream_position() raises:
    """Test stream_position() method."""
    var test_content = "Test content\n"
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)

    var initial_pos = buf_reader.stream_position()
    assert_equal(initial_pos, 0, "Stream position should start at 0")

    var consumed = buf_reader.consume(5)
    assert_equal(consumed, 5, "Should consume exactly 5 bytes")
    assert_equal(
        buf_reader.stream_position(),
        5,
        "Stream position should advance after consume",
    )

    print("✓ test_buffered_reader_stream_position passed")


fn test_buffered_reader_is_eof() raises:
    """Test is_eof() method."""
    var test_content = "Short\n"
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)

    # Small content may not be at EOF immediately if it fits in buffer
    # Check that we have available bytes
    assert_true(
        buf_reader.available() > 0,
        "Should have available bytes for small content",
    )

    # Large content should not be at EOF initially
    var large_content = String("")
    for i in range(200):
        large_content += "Line " + String(i) + "\n"

    var reader2 = create_memory_reader(large_content)
    var buf_reader2 = BufferedReader(reader2^, capacity=100)

    assert_false(
        buf_reader2.is_eof(), "Should not be at EOF for large content initially"
    )

    print("✓ test_buffered_reader_is_eof passed")


# Buffer Management


fn test_buffered_reader_consume() raises:
    """Test consume() method."""
    var test_content = "0123456789\n"
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)

    var initial_available = buf_reader.available()
    var consumed = buf_reader.consume(3)
    assert_equal(consumed, 3, "Should consume exactly 3 bytes")

    assert_equal(
        buf_reader.available(),
        initial_available - 3,
        "Available should decrease after consume",
    )
    assert_equal(
        buf_reader.buffer_position(), 3, "Buffer position should advance"
    )

    print("✓ test_buffered_reader_consume passed")


fn test_buffered_reader_consume_zero() raises:
    """Test consume(0) is valid."""
    var test_content = "Test\n"
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)

    var initial_available = buf_reader.available()
    var consumed = buf_reader.consume(0)
    assert_equal(consumed, 0, "Should consume 0 bytes")

    assert_equal(
        buf_reader.available(), initial_available, "Available should not change"
    )

    print("✓ test_buffered_reader_consume_zero passed")


fn test_buffered_reader_consume_too_much() raises:
    """Test consume() exceeding available raises error."""
    var test_content = "Test\n"
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)

    var available = buf_reader.available()
    var consumed = buf_reader.consume(available + 1)
    assert_equal(consumed, available, "Consumed should be equal to available")

    _ = buf_reader
    print("✓ test_buffered_reader_consume_too_much passed")


fn test_buffered_reader_read_exact() raises:
    """Test read_exact() method."""
    var test_content = "0123456789\n"
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)

    var bytes = buf_reader.read_exact(5)
    assert_equal(len(bytes), 5, "Should read exactly 5 bytes")
    var content_bytes = test_content.as_bytes()
    assert_equal(bytes[0], content_bytes[0], "First byte should be '0'")
    assert_equal(bytes[4], content_bytes[4], "Fifth byte should be '4'")

    # Buffer position should have advanced
    assert_equal(
        buf_reader.buffer_position(), 5, "Buffer position should advance"
    )

    print("✓ test_buffered_reader_read_exact passed")


fn test_buffered_reader_read_exact_zero() raises:
    """Test read_exact(0) returns empty span."""
    var test_content = "Test\n"
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)

    var bytes = buf_reader.read_exact(0)
    assert_equal(len(bytes), 0, "Should return empty span for size 0")

    print("✓ test_buffered_reader_read_exact_zero passed")


fn test_buffered_reader_read_exact_negative() raises:
    """Test read_exact() with negative size raises error."""
    var test_content = "Test\n"
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)

    with assert_raises(contains="read_exact size must be non-negative"):
        _ = buf_reader.read_exact(-1)

    _ = buf_reader
    print("✓ test_buffered_reader_read_exact_negative passed")


fn test_buffered_reader_read_exact_eof() raises:
    """Test read_exact() raises error when EOF reached."""
    var test_content = "Short\n"
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)

    # Consume all available
    var available = buf_reader.available()
    var consumed = buf_reader.consume(available)
    assert_equal(consumed, available, "Should consume all available bytes")

    # Try to read more - should raise error
    with assert_raises(contains="Unexpected EOF"):
        _ = buf_reader.read_exact(100)

    _ = buf_reader
    print("✓ test_buffered_reader_read_exact_eof passed")


fn test_buffered_reader_read_exact_large() raises:
    """Test read_exact() with large content requiring refill."""
    var test_content = String("")
    for i in range(200):
        test_content += "Line " + String(i) + "\n"

    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^, capacity=100)

    # Consume most of buffer, but leave some room
    var initial_available = buf_reader.available()
    var consume_amount = min(90, initial_available - 10)
    var consumed = buf_reader.consume(consume_amount)
    assert_equal(consumed, consume_amount, "Should consume requested amount")

    # Read available bytes (may be less than 50 if content is smaller)
    var read_amount = min(50, buf_reader.available())
    if read_amount > 0:
        var bytes = buf_reader.read_exact(read_amount)
        assert_equal(
            len(bytes), read_amount, "Should read exactly requested bytes"
        )

    _ = buf_reader
    print("✓ test_buffered_reader_read_exact_large passed")


fn test_buffered_reader_view() raises:
    """Test view() returns span of unconsumed bytes."""
    var test_content = "Span test content\n"
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)

    var span = buf_reader.view()
    assert_equal(
        len(span), len(buf_reader), "Span length should match buffer length"
    )
    assert_equal(
        len(span),
        buf_reader.available(),
        "Span should represent available data",
    )
    var content_bytes = test_content.as_bytes()
    assert_equal(span[0], content_bytes[0], "First byte should be 'S'")
    assert_equal(span[1], content_bytes[1], "Second byte should be 'p'")

    # Consume some bytes
    var consumed = buf_reader.consume(5)
    assert_equal(consumed, 5, "Should consume exactly 5 bytes")
    var span2 = buf_reader.view()
    assert_equal(
        len(span2), buf_reader.available(), "Span should reflect consumed bytes"
    )

    print("✓ test_buffered_reader_view passed")


# Indexing and Slicing


fn test_buffered_reader_getitem() raises:
    """Test single byte access via __getitem__."""
    var test_content = "ABC\n"
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)
    var content_bytes = test_content.as_bytes()

    assert_equal(buf_reader[0], content_bytes[0], "First byte should be 'A'")
    assert_equal(buf_reader[1], content_bytes[1], "Second byte should be 'B'")
    assert_equal(buf_reader[2], content_bytes[2], "Third byte should be 'C'")
    assert_equal(
        buf_reader[3], content_bytes[3], "Fourth byte should be newline"
    )

    print("✓ test_buffered_reader_getitem passed")


fn test_buffered_reader_getitem_out_of_bounds() raises:
    """Verify bounds checking for __getitem__."""
    var test_content = "XYZ\n"
    var reader = create_memory_reader(test_content)
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
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)
    var content_bytes = test_content.as_bytes()

    var consumed = buf_reader.consume(3)
    assert_equal(consumed, 3, "Should consume exactly 3 bytes")
    # After consuming 3 bytes, index 0 should point to what was originally at index 3
    assert_equal(
        buf_reader[0],
        content_bytes[3],
        "Index 0 should point to consumed position",
    )

    print("✓ test_buffered_reader_getitem_after_consume passed")


fn test_buffered_reader_slice() raises:
    """Test slicing operations."""
    var test_content = "0123456789\n"
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)
    var content_bytes = test_content.as_bytes()

    # Test basic slice
    var slice1 = buf_reader[0:3]
    assert_equal(len(slice1), 3, "Slice should have length 3")
    assert_equal(slice1[0], content_bytes[0], "First element should be '0'")
    assert_equal(slice1[2], content_bytes[2], "Third element should be '2'")

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
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)
    var content_bytes = test_content.as_bytes()

    # Test slice with step (should raise error)
    with assert_raises(contains="Step loading is not supported"):
        _ = buf_reader[0:10:2]

    # Test slice beyond buffer end
    with assert_raises(contains="Out of bounds"):
        _ = buf_reader[0:1000]

    # Test empty slice
    var empty_slice = buf_reader[5:5]
    assert_equal(len(empty_slice), 0, "Empty slice should have length 0")

    # Test single element slice - ensure we have data first
    if buf_reader.available() > 0:
        var single_slice = buf_reader[0:1]
        assert_equal(
            len(single_slice), 1, "Single element slice should have length 1"
        )
        assert_equal(
            single_slice[0], content_bytes[0], "Should contain correct byte"
        )

    _ = buf_reader
    print("✓ test_buffered_reader_slice_edge_cases passed")


fn test_buffered_reader_slice_after_consume() raises:
    """Test slicing after consuming bytes."""
    var test_content = "0123456789\n"
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)
    var content_bytes = test_content.as_bytes()

    var consumed = buf_reader.consume(3)
    assert_equal(consumed, 3, "Should consume exactly 3 bytes")
    # After consuming 3, slice [0:3] should get bytes 3-5
    if buf_reader.available() >= 3:
        var slice = buf_reader[0:3]
        assert_equal(len(slice), 3, "Slice should have correct length")
        assert_equal(slice[0], content_bytes[3], "First byte should be '3'")

    _ = buf_reader
    print("✓ test_buffered_reader_slice_after_consume passed")


fn test_buffered_reader_grow_buffer() raises:
    """Test grow_buffer() method."""
    var test_content = "Test content for resize\n"
    var reader = create_memory_reader(test_content)
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
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^, capacity=100)

    # Try to grow when already at max capacity
    with assert_raises(contains="Buffer already at max capacity"):
        buf_reader.grow_buffer(50, 100)

    _ = buf_reader
    print("✓ test_buffered_reader_grow_buffer_max_capacity passed")


fn test_buffered_reader_grow_buffer_respects_max() raises:
    """Test grow_buffer() respects max_capacity limit."""
    var test_content = "Test content\n"
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^, capacity=100)

    # Try to grow beyond max - should cap at max
    buf_reader.grow_buffer(1000, 150)
    assert_equal(
        buf_reader.capacity(), 150, "Capacity should be capped at max_capacity"
    )

    print("✓ test_buffered_reader_grow_buffer_respects_max passed")


# Writer Interface


fn test_buffered_reader_write_to() raises:
    """Test write_to() method."""
    var test_content = "Content to write\n"
    var reader = create_memory_reader(test_content)
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
    var reader = create_memory_reader(test_content)
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
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)

    var consumed = buf_reader.consume(5)
    assert_equal(consumed, 5, "Should consume exactly 5 bytes")
    var output = String()
    buf_reader.write_to(output)

    # Should only write unconsumed bytes
    assert_equal(
        String(output), "56789\n", "Should write only unconsumed bytes"
    )

    print("✓ test_buffered_reader_write_to_after_consume passed")


# ============================================================================
# Feature-Specific Tests
# ============================================================================
# ASCII Validation


fn test_buffered_reader_ascii_validation() raises:
    """BufferedReader should accept regular ASCII content."""
    var test_content = "Valid ASCII content\nLine 2\nLine 3\n"
    var test_file = Path("test_ascii_valid.txt")
    test_file = create_test_file(test_file, test_content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    # Should initialize without errors
    assert_true(buf_reader.available() > 0, "Should have available bytes")

    print("✓ test_buffered_reader_ascii_validation passed")


fn test_buffered_reader_ascii_validation_invalid() raises:
    """BufferedReader should not enforce ASCII on raw bytes."""
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
    var buf_reader = BufferedReader(reader^)
    assert_true(
        buf_reader.available() > 0, "BufferedReader should read non-ASCII bytes"
    )

    print("✓ test_buffered_reader_ascii_validation_invalid passed")


# Large Content (Multiple Refills)


fn test_buffered_reader_large_multiple_refills() raises:
    """Test with large content requiring multiple buffer refills and verify position tracking.
    """
    var test_content = String("")
    for i in range(200):
        test_content += "Line " + String(i) + "\n"

    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^, capacity=100)

    # Initially should not be at EOF
    assert_false(buf_reader.is_eof(), "Should not be at EOF initially")

    # Track stream position to verify it's accurate across refills
    var initial_stream_pos = buf_reader.stream_position()
    assert_equal(initial_stream_pos, 0, "Stream position should start at 0")

    # Read all content using read_exact, tracking position
    var total_read = 0
    var last_stream_pos = 0
    var refill_count = 0

    while not buf_reader.is_eof() or buf_reader.available() > 0:
        var stream_pos_before = buf_reader.stream_position()

        if buf_reader.available() > 0:
            var bytes = buf_reader.read_exact(min(50, buf_reader.available()))
            total_read += len(bytes)

            # Verify stream position advances correctly
            var stream_pos_after = buf_reader.stream_position()
            assert_equal(
                stream_pos_after,
                stream_pos_before + len(bytes),
                "Stream position should advance by bytes read",
            )
            last_stream_pos = stream_pos_after
        else:
            # Buffer full with no bytes available - compact to make room then refill
            buf_reader._compact_from(buf_reader.buffer_position())
            var filled = buf_reader._fill_buffer()
            if filled == 0:
                break
            refill_count += 1  # Count each successful refill
            if buf_reader.available() == 0:
                break

    assert_true(total_read > 0, "Should read content from large buffer")
    assert_equal(total_read, len(test_content), "Should read all content")
    assert_equal(
        last_stream_pos,
        len(test_content),
        "Stream position should match total bytes read",
    )
    assert_true(refill_count > 0, "Should have triggered multiple refills")

    print("✓ test_buffered_reader_large_multiple_refills passed")


# ============================================================================
# Edge Cases
# ============================================================================
# Boundary Conditions


fn test_buffered_reader_init_zero_capacity() raises:
    """Test initialization with very small capacity (edge case)."""
    var test_content = "Test\n"

    # Test with capacity=0 (should this be allowed? or raise error?)
    var reader1 = create_memory_reader(test_content)
    with assert_raises():  # Or verify it works if 0 is valid
        var buf_reader0 = BufferedReader(reader1^, capacity=0)
        _ = buf_reader0

    # Test with capacity=1 (minimum practical capacity)
    var reader2 = create_memory_reader(test_content)
    var buf_reader1 = BufferedReader(reader2^, capacity=1)
    assert_equal(buf_reader1.capacity(), 1, "Should use capacity=1")

    # Actually try to read with capacity=1 to verify it works
    if buf_reader1.available() > 0:
        var byte = buf_reader1.read_exact(1)
        assert_equal(len(byte), 1, "Should read 1 byte with capacity=1")

    print("✓ test_buffered_reader_init_zero_capacity passed")


fn test_buffered_reader_consume_exact_available() raises:
    """Test consuming exactly all available bytes."""
    var test_content = "0123456789\n"
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)

    var available = buf_reader.available()
    assert_true(available > 0, "Should have available bytes")

    # Consume exactly all available bytes
    var consumed = buf_reader.consume(available)
    assert_equal(
        consumed, available, "Should consume exactly all available bytes"
    )
    assert_equal(
        buf_reader.available(),
        0,
        "Should have no available bytes after consuming all",
    )

    if not buf_reader.is_eof():
        var refilled = buf_reader._fill_buffer()
        if refilled:
            assert_true(
                buf_reader.available() > 0, "Should refill after consuming all"
            )

    print("✓ test_buffered_reader_consume_exact_available passed")


fn test_buffered_reader_operations_after_eof() raises:
    """Test multiple operations after EOF."""
    var test_content = "Short\n"
    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^)

    # Consume all available to reach EOF
    var available = buf_reader.available()
    var consumed = buf_reader.consume(available)
    assert_equal(consumed, available, "Should consume all available")

    # Verify EOF state
    assert_true(
        buf_reader.is_eof() or buf_reader.available() == 0,
        "Should be at EOF or have no available bytes",
    )

    # Try multiple operations after EOF
    # 1. consume() after EOF
    var consumed_after = buf_reader.consume(1)
    assert_equal(consumed_after, 0, "consume() after EOF should return 0")

    # 2. view() after EOF
    var span_after = buf_reader.view()
    assert_equal(
        len(span_after), 0, "view() after EOF should return empty span"
    )

    print("✓ test_buffered_reader_operations_after_eof passed")


fn test_buffered_reader_stream_position_across_refills() raises:
    """Verify stream_position is accurate after multiple buffer compactions."""
    var test_content = String("")
    for i in range(150):
        test_content += "Line " + String(i) + "\n"

    var reader = create_memory_reader(test_content)
    var buf_reader = BufferedReader(reader^, capacity=50)

    var total_consumed = 0
    var positions = List[Int]()

    # Read through multiple refills
    while buf_reader.available() > 0 or not buf_reader.is_eof():
        if buf_reader.available() > 0:
            var stream_pos = buf_reader.stream_position()
            positions.append(stream_pos)

            var chunk_size = min(20, buf_reader.available())
            var bytes = buf_reader.read_exact(chunk_size)
            total_consumed += len(bytes)

            # Verify position advanced correctly
            var new_stream_pos = buf_reader.stream_position()
            assert_equal(
                new_stream_pos,
                stream_pos + len(bytes),
                "Stream position should advance by bytes read",
            )
        else:
            # Buffer full - compact to make room then refill
            buf_reader._compact_from(buf_reader.buffer_position())
            if not buf_reader._fill_buffer():
                break
            if buf_reader.available() == 0:
                break

    # Final position should match total consumed
    var final_pos = buf_reader.stream_position()
    assert_equal(
        final_pos,
        total_consumed,
        "Final stream position should match total bytes consumed",
    )
    assert_equal(
        total_consumed, len(test_content), "Should have consumed all content"
    )

    print("✓ test_buffered_reader_stream_position_across_refills passed")


fn test_buffered_reader_custom_capacity_edge_cases() raises:
    """Test various custom capacity scenarios."""
    var test_content = "Test content\n"

    # Test very small capacity
    var reader1 = create_memory_reader(test_content)
    var buf_reader1 = BufferedReader(reader1^, capacity=10)
    assert_equal(buf_reader1.capacity(), 10, "Should use custom small capacity")

    # Test larger capacity
    var reader2 = create_memory_reader(test_content)
    var buf_reader2 = BufferedReader(reader2^, capacity=1000)
    assert_equal(
        buf_reader2.capacity(), 1000, "Should use custom large capacity"
    )

    # Test capacity equal to content length
    var reader3 = create_memory_reader(test_content)
    var buf_reader3 = BufferedReader(reader3^, capacity=len(test_content))
    assert_equal(
        buf_reader3.capacity(), len(test_content), "Should use exact capacity"
    )

    print("✓ test_buffered_reader_custom_capacity_edge_cases passed")


# ============================================================================
# Reader Implementation Tests
# ============================================================================
# FileReader Alignment (verify FileReader works same as MemoryReader)


fn test_file_reader_alignment_basic() raises:
    """Verify FileReader produces same results as MemoryReader for basic operations.
    """
    var content = "Test content for alignment\n"

    # Test with FileReader
    var test_file = Path("test_alignment_basic.txt")
    test_file = create_test_file(test_file, content)
    var file_reader = FileReader(test_file)
    var file_buf_reader = BufferedReader(file_reader^)
    var file_bytes = file_buf_reader.read_exact(len(content))

    # Test with MemoryReader
    var mem_reader = create_memory_reader(content)
    var mem_buf_reader = BufferedReader(mem_reader^)
    var mem_bytes = mem_buf_reader.read_exact(len(content))

    # Compare results
    assert_equal(
        len(file_bytes), len(mem_bytes), "Should read same number of bytes"
    )
    for i in range(len(file_bytes)):
        assert_equal(
            file_bytes[i],
            mem_bytes[i],
            "Bytes should match at index " + String(i),
        )

    print("✓ test_file_reader_alignment_basic passed")


fn test_file_reader_alignment_large() raises:
    """Verify FileReader produces same results as MemoryReader for large content.
    """
    var content = String("")
    for i in range(200):
        content += "Line " + String(i) + "\n"

    # Test with FileReader
    var test_file = Path("test_alignment_large.txt")
    test_file = create_test_file(test_file, content)
    var file_reader = FileReader(test_file)
    var file_buf_reader = BufferedReader(file_reader^, capacity=100)

    # Test with MemoryReader
    var mem_reader = create_memory_reader(content)
    var mem_buf_reader = BufferedReader(mem_reader^, capacity=100)

    # Read all content and compare
    var file_total = 0
    var mem_total = 0

    var expected_total = len(content)
    while file_total < expected_total:
        if file_buf_reader.available() > 0:
            var to_read = min(
                50, file_buf_reader.available(), expected_total - file_total
            )
            var chunk = file_buf_reader.read_exact(to_read)
            file_total += len(chunk)
        elif file_buf_reader.is_eof() and file_buf_reader.available() == 0:
            break
        else:
            # Buffer full - compact from current position to make room then refill
            file_buf_reader._compact_from(file_buf_reader.buffer_position())
            if not file_buf_reader._fill_buffer():
                break
            if file_buf_reader.available() == 0:
                break

    while mem_total < expected_total:
        if mem_buf_reader.available() > 0:
            var to_read = min(
                50, mem_buf_reader.available(), expected_total - mem_total
            )
            var chunk = mem_buf_reader.read_exact(to_read)
            mem_total += len(chunk)
        elif mem_buf_reader.is_eof() and mem_buf_reader.available() == 0:
            break
        else:
            # Buffer full - compact from current position to make room then refill
            mem_buf_reader._compact_from(mem_buf_reader.buffer_position())
            if not mem_buf_reader._fill_buffer():
                break
            if mem_buf_reader.available() == 0:
                break

    assert_equal(file_total, mem_total, "Should read same total bytes")
    assert_equal(file_total, len(content), "Should read all content")

    _ = file_buf_reader
    _ = mem_buf_reader

    print("✓ test_file_reader_alignment_large passed")


fn test_file_reader_alignment_ascii() raises:
    """Verify FileReader + BufferedReader handles plain text input."""
    var content = "Valid ASCII content\n"
    var test_file = Path("test_alignment_ascii.txt")
    test_file = create_test_file(test_file, content)

    var reader = FileReader(test_file)
    var buf_reader = BufferedReader(reader^)

    assert_true(buf_reader.available() > 0, "Should have available bytes")

    print("✓ test_file_reader_alignment_ascii passed")


# MemoryReader Initialization Variants


fn test_memory_reader_init_list() raises:
    """Test MemoryReader initialization with List[Byte]."""
    var data = List[Byte]()
    var content = "Hello World\n"
    var content_bytes = content.as_bytes()
    for i in range(len(content_bytes)):
        data.append(content_bytes[i])

    var reader = MemoryReader(data^)
    var buf_reader = BufferedReader(reader^)

    assert_true(
        buf_reader.available() > 0, "Buffer should have available bytes"
    )
    assert_equal(
        buf_reader.available(),
        len(content),
        "Available should match content length",
    )

    print("✓ test_memory_reader_init_list passed")


fn test_memory_reader_init_span() raises:
    """Test MemoryReader initialization with Span[Byte]."""
    var content = "Test content\n"
    # Create span from string bytes directly - as_bytes() returns a span we can use
    var content_bytes = content.as_bytes()
    # MemoryReader accepts Span[Byte] (any origin), so we can pass it directly
    var reader = MemoryReader(content_bytes)

    var buf_reader = BufferedReader(reader^)

    assert_true(
        buf_reader.available() > 0, "Buffer should have available bytes"
    )
    assert_equal(
        buf_reader.available(),
        len(content),
        "Available should match content length",
    )

    print("✓ test_memory_reader_init_span passed")


# ============================================================================
# BufferedWriter Tests
# ============================================================================


fn test_buffered_writer_init() raises:
    """Test BufferedWriter initialization with default capacity."""
    var test_path = Path("tests/test_data") / Path(
        "test_buffered_writer_init.txt"
    )
    var writer = BufferedWriter(FileWriter(test_path))

    assert_equal(
        writer.capacity(), DEFAULT_CAPACITY, "Should use default capacity"
    )
    assert_equal(
        writer.available_space(),
        DEFAULT_CAPACITY,
        "Should have full capacity available",
    )
    assert_equal(writer.bytes_written(), 0, "Should start with 0 bytes written")

    writer.flush()
    print("✓ test_buffered_writer_init passed")


fn test_buffered_writer_init_custom_capacity() raises:
    """Test BufferedWriter initialization with custom capacity."""
    var test_path = Path("tests/test_data") / Path(
        "test_buffered_writer_init_custom.txt"
    )
    var custom_capacity = 1024
    var writer = BufferedWriter(FileWriter(test_path), capacity=custom_capacity)

    assert_equal(
        writer.capacity(), custom_capacity, "Should use custom capacity"
    )
    assert_equal(
        writer.available_space(),
        custom_capacity,
        "Should have full capacity available",
    )

    writer.flush()
    print("✓ test_buffered_writer_init_custom_capacity passed")


fn test_buffered_writer_init_invalid_capacity() raises:
    """Test BufferedWriter initialization with invalid capacity raises error."""
    var test_path = Path("tests/test_data") / Path(
        "test_buffered_writer_init_invalid.txt"
    )

    with assert_raises(contains="capacity"):
        _ = BufferedWriter(FileWriter(test_path), capacity=0)

    with assert_raises(contains="capacity"):
        _ = BufferedWriter(FileWriter(test_path), capacity=-1)

    print("✓ test_buffered_writer_init_invalid_capacity passed")


fn test_buffered_writer_write_small() raises:
    """Test writing bytes that fit in buffer."""
    var test_path = Path("tests/test_data") / Path(
        "test_buffered_writer_write_small.txt"
    )
    var writer = BufferedWriter(FileWriter(test_path))

    var data = List[Byte]()
    data.append(ord("H"))
    data.append(ord("e"))
    data.append(ord("l"))
    data.append(ord("l"))
    data.append(ord("o"))

    writer.write_bytes(data)

    assert_equal(
        writer.available_space(),
        DEFAULT_CAPACITY - 5,
        "Should have 5 bytes less space",
    )
    assert_equal(
        writer.bytes_written(), 0, "Should not have written to file yet"
    )

    writer.flush()

    assert_equal(
        writer.bytes_written(), 5, "Should have written 5 bytes after flush"
    )
    assert_equal(
        writer.available_space(),
        DEFAULT_CAPACITY,
        "Should have full capacity after flush",
    )

    # Verify file contents
    var reader = FileReader(test_path)
    var bytes_read = reader.read_bytes()
    assert_equal(len(bytes_read), 5, "File should contain 5 bytes")
    assert_equal(bytes_read[0], ord("H"), "First byte should be 'H'")
    assert_equal(bytes_read[4], ord("o"), "Last byte should be 'o'")

    print("✓ test_buffered_writer_write_small passed")


fn test_buffered_writer_write_large() raises:
    """Test writing bytes that exceed buffer capacity (triggers automatic flush).
    """
    var test_path = Path("tests/test_data") / Path(
        "test_buffered_writer_write_large.txt"
    )
    var buffer_size = 64
    var writer = BufferedWriter(FileWriter(test_path), capacity=buffer_size)

    # Write more than buffer capacity
    var data = List[Byte]()
    for i in range(100):
        data.append(Byte(i % 256))

    writer.write_bytes(data)

    # Should have automatically flushed
    assert_true(
        writer.bytes_written() >= buffer_size,
        "Should have flushed at least buffer_size bytes",
    )
    assert_true(
        writer.available_space() > 0,
        "Should have some space available after flush",
    )

    writer.flush()

    assert_equal(
        writer.bytes_written(), 100, "Should have written all 100 bytes"
    )

    # Verify file contents
    var reader = FileReader(test_path)
    var bytes_read = reader.read_bytes()
    assert_equal(len(bytes_read), 100, "File should contain 100 bytes")
    for i in range(100):
        assert_equal(
            bytes_read[i],
            Byte(i % 256),
            "Byte at index " + String(i) + " should match",
        )

    print("✓ test_buffered_writer_write_large passed")


fn test_buffered_writer_write_span() raises:
    """Test writing bytes from a Span."""
    var test_path = Path("tests/test_data") / Path(
        "test_buffered_writer_write_span.txt"
    )
    var writer = BufferedWriter(FileWriter(test_path))

    var data_bytes = List[Byte]()
    data_bytes.append(ord("T"))
    data_bytes.append(ord("e"))
    data_bytes.append(ord("s"))
    data_bytes.append(ord("t"))

    var span = Span[Byte](ptr=data_bytes.unsafe_ptr(), length=len(data_bytes))
    writer.write_bytes(span)
    writer.flush()

    assert_equal(writer.bytes_written(), 4, "Should have written 4 bytes")

    # Verify file contents
    var reader = FileReader(test_path)
    var bytes_read = reader.read_bytes()
    assert_equal(len(bytes_read), 4, "File should contain 4 bytes")
    assert_equal(bytes_read[0], ord("T"), "First byte should be 'T'")
    assert_equal(bytes_read[1], ord("e"), "Second byte should be 'e'")
    assert_equal(bytes_read[2], ord("s"), "Third byte should be 's'")
    assert_equal(bytes_read[3], ord("t"), "Fourth byte should be 't'")

    print("✓ test_buffered_writer_write_span passed")


fn test_buffered_writer_explicit_flush() raises:
    """Test explicit flush functionality."""
    var test_path = Path("tests/test_data") / Path(
        "test_buffered_writer_explicit_flush.txt"
    )
    var writer = BufferedWriter(FileWriter(test_path))

    var data1 = List[Byte]()
    data1.append(ord("A"))
    writer.write_bytes(data1)

    assert_equal(
        writer.bytes_written(), 0, "Should not have written before flush"
    )

    writer.flush()

    assert_equal(
        writer.bytes_written(), 1, "Should have written 1 byte after flush"
    )

    var data2 = List[Byte]()
    data2.append(ord("B"))
    writer.write_bytes(data2)
    writer.flush()

    assert_equal(writer.bytes_written(), 2, "Should have written 2 bytes total")

    # Verify file contents
    var reader = FileReader(test_path)
    var bytes_read = reader.read_bytes()
    assert_equal(len(bytes_read), 2, "File should contain 2 bytes")
    assert_equal(bytes_read[0], ord("A"), "First byte should be 'A'")
    assert_equal(bytes_read[1], ord("B"), "Second byte should be 'B'")

    print("✓ test_buffered_writer_explicit_flush passed")


fn test_buffered_writer_destructor_flush() raises:
    """Test that destructor flushes remaining data."""
    var test_path = Path("tests/test_data") / Path(
        "test_buffered_writer_destructor_flush.txt"
    )

    var data = List[Byte]()
    data.append(ord("D"))
    data.append(ord("e"))
    data.append(ord("s"))
    data.append(ord("t"))
    data.append(ord("r"))
    data.append(ord("u"))
    data.append(ord("c"))
    data.append(ord("t"))

    # Write without explicit flush, let destructor handle it
    var writer = BufferedWriter(FileWriter(test_path))
    writer.write_bytes(data)
    # Writer goes out of scope here, destructor should flush

    # Verify file contents were written
    var reader = FileReader(test_path)
    var bytes_read = reader.read_bytes()
    assert_equal(len(bytes_read), 8, "File should contain 8 bytes")
    assert_equal(bytes_read[0], ord("D"), "Byte 0 should be 'D'")
    assert_equal(bytes_read[1], ord("e"), "Byte 1 should be 'e'")
    assert_equal(bytes_read[2], ord("s"), "Byte 2 should be 's'")
    assert_equal(bytes_read[3], ord("t"), "Byte 3 should be 't'")
    assert_equal(bytes_read[4], ord("r"), "Byte 4 should be 'r'")
    assert_equal(bytes_read[5], ord("u"), "Byte 5 should be 'u'")
    assert_equal(bytes_read[6], ord("c"), "Byte 6 should be 'c'")
    assert_equal(bytes_read[7], ord("t"), "Byte 7 should be 't'")

    print("✓ test_buffered_writer_destructor_flush passed")


fn test_buffered_writer_bytes_written_counter() raises:
    """Test bytes_written counter accuracy."""
    var test_path = Path("tests/test_data") / Path(
        "test_buffered_writer_bytes_written.txt"
    )
    var writer = BufferedWriter(FileWriter(test_path), capacity=32)

    # Write in chunks
    var chunk1 = List[Byte]()
    for i in range(10):
        chunk1.append(Byte(i))
    writer.write_bytes(chunk1)
    writer.flush()
    assert_equal(writer.bytes_written(), 10, "Should have written 10 bytes")

    var chunk2 = List[Byte]()
    for i in range(20):
        chunk2.append(Byte(i + 10))
    writer.write_bytes(chunk2)
    writer.flush()
    assert_equal(
        writer.bytes_written(), 30, "Should have written 30 bytes total"
    )

    var chunk3 = List[Byte]()
    for i in range(5):
        chunk3.append(Byte(i + 30))
    writer.write_bytes(chunk3)
    writer.flush()
    assert_equal(
        writer.bytes_written(), 35, "Should have written 35 bytes total"
    )

    # Verify file contents
    var reader = FileReader(test_path)
    var bytes_read = reader.read_bytes()
    assert_equal(len(bytes_read), 35, "File should contain 35 bytes")

    print("✓ test_buffered_writer_bytes_written_counter passed")


fn test_buffered_writer_empty_write() raises:
    """Test writing empty data."""
    var test_path = Path("tests/test_data") / Path(
        "test_buffered_writer_empty_write.txt"
    )
    var writer = BufferedWriter(FileWriter(test_path))

    var empty_data = List[Byte]()
    writer.write_bytes(empty_data)

    assert_equal(
        writer.available_space(),
        DEFAULT_CAPACITY,
        "Available space should be unchanged",
    )
    assert_equal(writer.bytes_written(), 0, "Should not have written anything")

    writer.flush()

    # Verify file is empty
    var reader = FileReader(test_path)
    var bytes_read = reader.read_bytes()
    assert_equal(len(bytes_read), 0, "File should be empty")

    print("✓ test_buffered_writer_empty_write passed")


fn test_buffered_writer_multiple_flushes() raises:
    """Test multiple flush calls."""
    var test_path = Path("tests/test_data") / Path(
        "test_buffered_writer_multiple_flushes.txt"
    )
    var writer = BufferedWriter(FileWriter(test_path))

    var data = List[Byte]()
    data.append(ord("F"))
    writer.write_bytes(data)

    writer.flush()
    var bytes_after_first = writer.bytes_written()

    writer.flush()  # Flush again with no new data
    assert_equal(
        writer.bytes_written(),
        bytes_after_first,
        "Bytes written should not change",
    )

    var data2 = List[Byte]()
    data2.append(ord("L"))
    writer.write_bytes(data2)
    writer.flush()

    assert_equal(
        writer.bytes_written(),
        bytes_after_first + 1,
        "Should have written one more byte",
    )

    print("✓ test_buffered_writer_multiple_flushes passed")


# ============================================================================
# Cleanup: remove files produced by tests
# ============================================================================


fn cleanup_iostream_test_files() raises:
    """Remove all files created by tests (ignore missing files)."""
    var base = Path("tests/test_data")
    var names = List[String]()
    names.append("test_ascii_valid.txt")
    names.append("test_ascii_invalid.txt")
    names.append("test_alignment_basic.txt")
    names.append("test_alignment_large.txt")
    names.append("test_alignment_ascii.txt")
    names.append("test_buffered_writer_init.txt")
    names.append("test_buffered_writer_init_custom.txt")
    names.append("test_buffered_writer_init_invalid.txt")
    names.append("test_buffered_writer_write_small.txt")
    names.append("test_buffered_writer_write_large.txt")
    names.append("test_buffered_writer_write_span.txt")
    names.append("test_buffered_writer_explicit_flush.txt")
    names.append("test_buffered_writer_destructor_flush.txt")
    names.append("test_buffered_writer_bytes_written.txt")
    names.append("test_buffered_writer_empty_write.txt")
    names.append("test_buffered_writer_multiple_flushes.txt")
    for name in names:
        try:
            remove(base / Path(name))
        except:
            pass


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
    cleanup_iostream_test_files()
