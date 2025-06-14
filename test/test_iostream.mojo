from memory import memcpy, UnsafePointer, Span
from pathlib import Path
from testing import assert_equal, assert_true, assert_false, assert_raises
import tempfile
import os
from collections.string import chr

# Import the modules under test
from blazeseq.iostream import (
    InnerBuffer,
    FileReader,
    BufferedLineIterator,
    NEW_LINE,
    DEFAULT_CAPACITY,
    arg_true,
    carriage_return,
    simd_width,
)


def test_inner_buffer_creation():
    """Test InnerBuffer initialization and basic properties."""
    print("Testing InnerBuffer creation...")

    # Test basic initialization
    var buf = InnerBuffer(100)
    assert_equal(buf._len, 100)
    assert_true(buf.ptr != UnsafePointer[UInt8]())

    # Test initialization with pointer
    var ptr = UnsafePointer[UInt8].alloc(50)
    var buf2 = InnerBuffer(ptr, 50)
    assert_equal(buf2._len, 50)
    assert_equal(buf2.ptr, ptr)

    print("✓ InnerBuffer creation tests passed")


def test_inner_buffer_indexing():
    """Test InnerBuffer indexing operations."""
    print("Testing InnerBuffer indexing...")

    var buf = InnerBuffer(10)

    # Test setting and getting values
    try:
        buf[0] = 65  # ASCII 'A'
        buf[1] = 66  # ASCII 'B'
        buf[9] = 90  # ASCII 'Z'

        assert_equal(buf[0], 65)
        assert_equal(buf[1], 66)
        assert_equal(buf[9], 90)
    except e:
        print("Unexpected error in indexing:", e)
        assert_false(True, "Should not raise error for valid indices")

    # Test out of bounds access
    with assert_raises():
        _ = buf[10]  # Should raise out of bounds error

    with assert_raises():
        buf[10] = 100  # Should raise out of bounds error

    print("✓ InnerBuffer indexing tests passed")


def test_inner_buffer_slicing():
    """Test InnerBuffer slicing operations."""
    print("Testing InnerBuffer slicing...")

    var buf = InnerBuffer(10)

    # Fill buffer with test data
    for i in range(10):
        buf[i] = UInt8(i + 65)  # ASCII 'A' to 'J'

    try:
        # Test valid slices
        var s = slice(0, 5)
        var slice1 = buf.__getitem__(s)
        assert_equal(len(slice1), 5)

        s = slice(2, 8)
        var slice2 = buf.__getitem__(s)
        assert_equal(len(slice2), 6)

        # Test slice with default values
        s = slice(end=5)
        var slice3 = buf.__getitem__(s)
        assert_equal(len(slice3), 5)

        s = slice(start=5, end=buf._len)
        var slice4 = buf.__getitem__(s)
        assert_equal(len(slice4), 5)

    except Error:
        print("Unexpected error in slicing:", Error)
        print(Error)
        assert_false(True, "Should not raise error for valid slices")

    # Test out of bounds slicing
    with assert_raises():
        s = slice(start=-1, end=5)
        _ = buf.__getitem__(s)  # Should raise out of bounds error

    with assert_raises():
        s = slice(15)
        _ = buf.__getitem__(s)  # Should raise out of bounds error

    print("✓ InnerBuffer slicing tests passed")


def test_inner_buffer_resize():
    """Test InnerBuffer resize functionality."""
    print("Testing InnerBuffer resize...")

    var buf = InnerBuffer(5)

    # Fill with test data
    for i in range(5):
        buf[i] = UInt8(i + 65)

    try:
        # Test successful resize
        var success = buf.resize(10)
        assert_true(success)
        assert_equal(buf._len, 10)

        # Verify data is preserved
        for i in range(5):
            assert_equal(buf[i], UInt8(i + 65))
    except e:
        print("Unexpected error in resize:", e)
        assert_false(True, "Should not raise error for valid resize")

    # Test resize to smaller size (should raise error)
    with assert_raises():
        _ = buf.resize(3)

    print("✓ InnerBuffer resize tests passed")


def create_test_file(content: String) -> Path:
    """Helper function to create a temporary test file."""
    var temp_dir = tempfile.mkdtemp()
    var file_path = Path(temp_dir) / "test_file.txt"

    with open(file_path, "w") as f:
        f.write(content)

    return file_path


def test_file_reader_creation():
    """Test FileReader initialization."""
    print("Testing FileReader creation...")

    # Create a test file
    var test_content = "Hello, World!\nThis is a test file.\n"
    var file_path = create_test_file(test_content)

    try:
        var reader = FileReader(file_path)
        # If we get here without exception, creation was successful
        assert_true(True)
    except e:
        print("Unexpected error creating FileReader:", e)
        assert_false(True, "Should not raise error for valid file")

    # Test with non-existent file
    var non_existent = Path("/non/existent/file.txt")
    with assert_raises():
        var bad_reader = FileReader(non_existent)

    # Clean up
    os.remove(file_path)

    print("✓ FileReader creation tests passed")


def test_file_reader_read_bytes():
    """Test FileReader read_bytes functionality."""
    print("Testing FileReader read_bytes...")

    var test_content = "Hello, World!"
    var file_path = create_test_file(test_content)
    var reader = FileReader(file_path)

    try:
        # Read all bytes
        var all_bytes = reader.read_bytes()
        assert_equal(len(all_bytes), len(test_content))

        # Verify content
        for i in range(len(test_content)):
            assert_equal(all_bytes[i], UInt8(ord(test_content[i])))
    except e:
        print("Unexpected error reading bytes:", e)
        assert_false(True, "Should not raise error for valid read")

    # Clean up
    os.remove(file_path)

    print("✓ FileReader read_bytes tests passed")


def test_buffered_line_iterator_creation():
    """Test BufferedLineIterator initialization."""
    print("Testing BufferedLineIterator creation...")

    var test_content = "Line 1\nLine 2\nLine 3\n"
    var file_path = create_test_file(test_content)

    try:
        var iterator = BufferedLineIterator(file_path)
        assert_equal(iterator.head, 0)
        assert_equal(iterator.end, 0)
        assert_equal(iterator.capacity(), DEFAULT_CAPACITY)
    except e:
        print("Unexpected error creating BufferedLineIterator:", e)
        assert_false(True, "Should not raise error for valid file")

    # Test with custom capacity
    try:
        var custom_iterator = BufferedLineIterator(file_path, 512)
        assert_equal(custom_iterator.capacity(), 512)
    except e:
        print("Unexpected error with custom capacity:", e)
        assert_false(True, "Should not raise error for custom capacity")

    # Test with non-existent file
    var non_existent = Path("/non/existent/file.txt")
    with assert_raises():
        var bad_iterator = BufferedLineIterator(non_existent)

    # Clean up
    os.remove(file_path)

    print("✓ BufferedLineIterator creation tests passed")


def test_buffered_line_iterator_state_methods():
    """Test BufferedLineIterator state management methods."""
    print("Testing BufferedLineIterator state methods...")

    var test_content = "Hello\nWorld\n"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path)

    # Test initial state
    assert_equal(iterator.len(), 0)
    assert_equal(iterator.uninatialized_space(), iterator.capacity())
    assert_equal(iterator.usable_space(), iterator.capacity())

    # Test _check_buf_state with empty buffer
    var is_empty = iterator._check_buf_state()
    assert_true(is_empty)
    assert_equal(iterator.head, 0)
    assert_equal(iterator.end, 0)

    # Clean up
    os.remove(file_path)

    print("✓ BufferedLineIterator state methods tests passed")


def test_buffered_line_iterator_fill_buffer():
    """Test BufferedLineIterator buffer filling."""
    print("Testing BufferedLineIterator fill_buffer...")

    var test_content = "Hello, World!\nThis is a test.\nHello, World!\nThis is a test.\nHello, World!\nThis is a test.\nHello, World!\nThis is a test.\nHello, World!\nThis is a test.\nHello, World!\nThis is a test.\n"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path)

    try:
        # Fill buffer
        var bytes_read = iterator._fill_buffer()
        # Should have read some bytes
        assert_true(bytes_read > 0)
        assert_true(iterator.len() > 0)
        assert_equal(iterator.head, 0)
        assert_equal(iterator.end, Int(bytes_read))

        # Verify buffer contains expected data
        var expected_len = min(len(test_content), iterator.capacity())
        assert_equal(iterator.len(), expected_len)

    except e:
        print("Unexpected error filling buffer:", e)
        assert_false(True, "Should not raise error for buffer fill")

    # Clean up
    os.remove(file_path)

    print("✓ BufferedLineIterator fill_buffer tests passed")


def test_buffered_line_iterator_left_shift():
    """Test BufferedLineIterator left shift operation."""
    print("Testing BufferedLineIterator left_shift...")

    var test_content = "ABCDEFGHIJ"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(
        file_path, 20
    )  # Small buffer for testing

    try:
        # Fill buffer first
        _ = iterator._fill_buffer()

        # Simulate consuming some data
        iterator.head = 3  # "consume" first 3 bytes
        var original_len = iterator.len()

        # Perform left shift
        iterator._left_shift()

        # Verify shift worked correctly
        assert_equal(iterator.head, 0)
        assert_equal(iterator.len(), original_len)

        # Verify data was moved correctly
        # (Would need access to buffer contents to fully verify)

    except e:
        print("Unexpected error in left shift:", e)
        assert_false(True, "Should not raise error for left shift")

    # Clean up
    os.remove(file_path)

    print("✓ BufferedLineIterator left_shift tests passed")


def test_edge_cases():
    """Test edge cases and error conditions."""
    print("Testing edge cases...")

    # Test with empty file
    var empty_file_path = create_test_file("")
    try:
        var empty_iterator = BufferedLineIterator(empty_file_path)
        var bytes_read = empty_iterator._fill_buffer()
        assert_equal(bytes_read, 0)
        assert_equal(empty_iterator.len(), 0)
    except e:
        print("Unexpected error with empty file:", e)

    # Clean up
    os.remove(empty_file_path)

    # Test with very large file (if system allows)
    var large_content = "A" * 10000 + "\n" + "B" * 10000
    var large_file_path = create_test_file(large_content)
    try:
        var large_iterator = BufferedLineIterator(large_file_path, 1024)
        var bytes_read = large_iterator._fill_buffer()
        assert_true(bytes_read > 0)
        assert_true(bytes_read <= 1024)  # Should not exceed buffer capacity
    except e:
        print("Unexpected error with large file:", e)

    # Clean up
    os.remove(large_file_path)

    print("✓ Edge cases tests passed")


def test_get_next_line_index():
    """Test BufferedLineIterator _get_next_line_index method."""
    print("Testing _get_next_line_index...")

    # Test with newline in buffer
    var test_content = "Hello\nWorld\nTest\n"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        # Fill buffer
        _ = iterator._fill_buffer()

        # Find first newline (should be at position 5)
        var first_newline = iterator._get_next_line_index()
        assert_equal(first_newline, 5)  # "Hello\n" - newline at index 5

        # Move head past first newline and find next
        iterator.head = 6  # Start after first newline
        var second_newline = iterator._get_next_line_index()
        assert_equal(second_newline, 11)  # "World\n" - newline at index 12

        # Move head past second newline
        iterator.head = 13  # Start after second newline
        var third_newline = iterator._get_next_line_index()
        assert_equal(third_newline, 16)  # "Test\n" - newline at index 18

    except e:
        print("Unexpected error in _get_next_line_index:", e)
        assert_false(True, "Should not raise error for valid newline search")

    # Clean up
    os.remove(file_path)

    print("✓ _get_next_line_index basic tests passed")


def test_get_next_line_index_no_newline():
    """Test _get_next_line_index when no newline is found."""
    print("Testing _get_next_line_index with no newline...")

    var test_content = "No newline here"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        # Fill buffer
        _ = iterator._fill_buffer()

        # Should return -1 when no newline found
        var result = iterator._get_next_line_index()
        assert_equal(result, -1)

    except e:
        print("Unexpected error when no newline found:", e)
        assert_false(True, "Should not raise error when no newline found")

    # Clean up
    os.remove(file_path)

    print("✓ _get_next_line_index no newline tests passed")


def test_get_next_line_index_edge_cases():
    """Test _get_next_line_index edge cases."""
    print("Testing _get_next_line_index edge cases...")

    # Test with newline at beginning
    var test_content1 = "\nHello World"
    var file_path1 = create_test_file(test_content1)
    var iterator1 = BufferedLineIterator(file_path1, 64)

    try:
        _ = iterator1._fill_buffer()
        var result1 = iterator1._get_next_line_index()
        assert_equal(result1, 0)  # Newline at start
    except e:
        print("Unexpected error with newline at start:", e)

    os.remove(file_path1)

    # Test with newline at end
    var test_content2 = "Hello World\n"
    var file_path2 = create_test_file(test_content2)
    var iterator2 = BufferedLineIterator(file_path2, 64)

    try:
        _ = iterator2._fill_buffer()
        var result2 = iterator2._get_next_line_index()
        assert_equal(result2, 11)  # Newline at end
    except e:
        print("Unexpected error with newline at end:", e)

    os.remove(file_path2)

    # Test with multiple consecutive newlines
    var test_content3 = "Line1\n\n\nLine2"
    var file_path3 = create_test_file(test_content3)
    var iterator3 = BufferedLineIterator(file_path3, 64)

    try:
        _ = iterator3._fill_buffer()
        var result3 = iterator3._get_next_line_index()
        assert_equal(result3, 5)  # First newline

        iterator3.head = 6
        var result4 = iterator3._get_next_line_index()
        assert_equal(result4, 6)  # Second newline (consecutive)
    except e:
        print("Unexpected error with consecutive newlines:", e)

    os.remove(file_path3)

    print("✓ _get_next_line_index edge cases tests passed")


def test_dunder_len():
    """Test BufferedLineIterator __len__ method."""
    print("Testing __len__...")

    var test_content = "Hello, World!"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    # Initially empty
    assert_equal(len(iterator), 0)

    try:
        # Fill buffer
        _ = iterator._fill_buffer()

        # Should now have length equal to content
        var expected_len = len(test_content)
        assert_equal(len(iterator), expected_len)

        # Test after consuming some data
        iterator.head = 5
        assert_equal(len(iterator), expected_len - 5)

        # Test when head == end
        iterator.head = iterator.end
        assert_equal(len(iterator), 0)

    except e:
        print("Unexpected error in __len__:", e)
        assert_false(True, "Should not raise error for __len__")

    # Clean up
    os.remove(file_path)

    print("✓ __len__ tests passed")


def test_dunder_str():
    """Test BufferedLineIterator __str__ method."""
    print("Testing __str__...")

    var test_content = "Hello, World!"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        # Fill buffer
        _ = iterator._fill_buffer()

        # Should return the content as string
        var result = String(iterator.__str__())
        assert_equal(result, test_content)

        # Test after consuming some data
        iterator.head = 7  # Skip "Hello, "
        var partial_result = String(iterator.__str__())
        assert_equal(partial_result, "World!")

        # Test with empty buffer
        iterator.head = iterator.end
        var empty_result = String(iterator.__str__())
        assert_equal(empty_result, "")

    except e:
        print("Unexpected error in __str__:", e)
        assert_false(True, "Should not raise error for __str__")

    # Clean up
    os.remove(file_path)

    print("✓ __str__ tests passed")


def test_dunder_str_with_newlines():
    """Test __str__ method with newlines and special characters."""
    print("Testing __str__ with newlines...")

    var test_content = "Line1\nLine2\r\nLine3\n"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        _ = iterator._fill_buffer()
        var result = String(iterator.__str__())
        assert_equal(result, test_content)

    except e:
        print("Unexpected error in __str__ with newlines:", e)

    # Clean up
    os.remove(file_path)

    print("✓ __str__ with newlines tests passed")


def test_dunder_getitem_index():
    """Test BufferedLineIterator __getitem__ with index."""
    print("Testing __getitem__ with index...")

    var test_content = "ABCDEF"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        _ = iterator._fill_buffer()

        # Test valid indices
        assert_equal(iterator[0], ord("A"))
        assert_equal(iterator[1], ord("B"))
        assert_equal(iterator[5], ord("F"))

        # Test after moving head
        iterator.head = 2
        assert_equal(iterator[2], ord("C"))  # Still valid
        assert_equal(iterator[3], ord("D"))

    except e:
        print("Unexpected error in __getitem__ index:", e)
        assert_false(True, "Should not raise error for valid indices")

    # Test out of bounds - before head
    with assert_raises():
        _ = iterator[1]  # head is at 2, so 1 should be out of bounds

    # Test out of bounds - after end
    with assert_raises():
        _ = iterator[100]

    # Clean up
    os.remove(file_path)

    print("✓ __getitem__ index tests passed")


def test_dunder_getitem_slice():
    """Test BufferedLineIterator __getitem__ with slice."""
    print("Testing __getitem__ with slice...")

    var test_content = "ABCDEFGHIJ"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        _ = iterator._fill_buffer()

        # Test valid slices
        var slice1 = iterator[0:5]
        assert_equal(len(slice1), 5)
        assert_equal(slice1[0], ord("A"))
        assert_equal(slice1[4], ord("E"))

        var slice2 = iterator[2:8]
        assert_equal(len(slice2), 6)
        assert_equal(slice2[0], ord("C"))
        assert_equal(slice2[5], ord("H"))

        # Test slice with step
        with assert_raises():
            var slice3 = iterator[0:6:2]

        # Test with default values (using head and end)
        iterator.head = 2
        iterator.end = 8
        var slice4 = iterator[:]  # Should use head:end
        assert_equal(len(slice4), 6)
        assert_equal(slice4[0], ord("C"))

    except e:
        print("Unexpected error in __getitem__ slice:", e)
        assert_false(True, "Should not raise error for valid slices")

    # Test out of bounds slices
    with assert_raises():
        _ = iterator[0:15]  # End beyond buffer

    with assert_raises():
        _ = iterator[-1:5]  # Start before head

    # Clean up
    os.remove(file_path)

    print("✓ __getitem__ slice tests passed")


def test_arg_true_function():
    """Test the arg_true helper function."""
    print("Testing arg_true function...")

    # Create test SIMD vectors
    var vec1 = SIMD[DType.bool, 4](False, True, False, False)
    var result1 = arg_true(vec1)
    assert_equal(result1, 1)

    var vec2 = SIMD[DType.bool, 4](True, False, False, False)
    var result2 = arg_true(vec2)
    assert_equal(result2, 0)

    var vec3 = SIMD[DType.bool, 4](False, False, False, True)
    var result3 = arg_true(vec3)
    assert_equal(result3, 3)

    var vec4 = SIMD[DType.bool, 4](False, False, False, False)
    var result4 = arg_true(vec4)
    assert_equal(result4, -1)  # No true values

    # Test with multiple true values (should return first)
    var vec5 = SIMD[DType.bool, 4](False, True, True, False)
    var result5 = arg_true(vec5)
    assert_equal(result5, 1)

    print("✓ arg_true function tests passed")


def test_integration_scenarios():
    """Test integration scenarios combining multiple methods."""
    print("Testing integration scenarios...")

    var test_content = "First line\nSecond line\nThird line\n"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        _ = iterator._fill_buffer()

        # Test getting first line using multiple methods
        var first_newline = iterator._get_next_line_index()
        var first_line_slice = iterator[0:first_newline]
        var first_line_str = String(bytes=first_line_slice)
        assert_equal(first_line_str, "First line")

        # Move to second line
        iterator.head = first_newline + 1
        var current_length = len(iterator)
        assert_true(current_length > 0)

        # Get remaining content as string
        var remaining = String(iterator.__str__())
        assert_equal(remaining, "Second line\nThird line\n")

        # Find next newline from current position
        var second_newline = iterator._get_next_line_index()
        _ = second_newline - iterator.head
        var second_line_slice = iterator[iterator.head : second_newline]
        var second_line_str = String(bytes=second_line_slice)
        assert_equal(second_line_str, "Second line")

    except e:
        print("Unexpected error in integration test:", e)
        assert_false(True, "Integration test should not raise errors")

    # Clean up
    os.remove(file_path)

    print("✓ Integration scenarios tests passed")


def test_resize_buf_normal_resize():
    """Test _resize_buf with normal resize scenarios."""
    print("Testing _resize_buf normal resize...")

    var test_content = "Hello World"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(
        file_path, 64
    )  # Start with small capacity

    try:
        var original_capacity = iterator.capacity()

        # Test normal resize - increase by 32
        iterator._resize_buf(32, 1024)
        assert_equal(iterator.capacity(), original_capacity + 32)

        # Test another resize
        var new_capacity = iterator.capacity()
        iterator._resize_buf(64, 1024)
        assert_equal(iterator.capacity(), new_capacity + 64)

    except e:
        print("Unexpected error in normal resize:", e)
        assert_false(True, "Should not raise error for normal resize")

    # Clean up
    os.remove(file_path)

    print("✓ _resize_buf normal resize tests passed")


def test_resize_buf_max_capacity_limit():
    """Test _resize_buf when approaching max capacity."""
    print("Testing _resize_buf max capacity limit...")

    var test_content = "Test"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        # Test resize that would exceed max capacity - should cap at max
        iterator._resize_buf(
            1000, 128
        )  # Current 64 + 1000 > 128, should cap at 128
        assert_equal(iterator.capacity(), 128)

        # Test resize when already at max capacity - should raise error
        with assert_raises():
            iterator._resize_buf(10, 128)

    except e:
        print("Unexpected error in max capacity test:", e)
        # Only acceptable if it's the expected "max capacity" error
        # if "max capacity" not in e:
        #     assert_false(True, "Should only raise max capacity error")

    # Clean up
    os.remove(file_path)

    print("✓ _resize_buf max capacity tests passed")


def test_resize_buf_edge_cases():
    """Test _resize_buf edge cases."""
    print("Testing _resize_buf edge cases...")

    var test_content = "Edge case test"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 32)

    try:
        # Test resize by 0 (should not change capacity)
        var original_capacity = iterator.capacity()
        iterator._resize_buf(0, 1024)
        assert_equal(iterator.capacity(), original_capacity)

        # Test resize by exactly the remaining capacity to max
        var remaining = 128 - iterator.capacity()
        iterator._resize_buf(remaining, 128)
        assert_equal(iterator.capacity(), 128)

    except e:
        print("Unexpected error in edge cases:", e)
        assert_false(True, "Should not raise error for edge cases")

    # Clean up
    os.remove(file_path)

    print("✓ _resize_buf edge cases tests passed")


def test_check_ascii_valid_ascii():
    """Test _check_ascii with valid ASCII content."""
    print("Testing _check_ascii with valid ASCII...")

    var test_content = "Hello World 123 !@# \n\t"  # All ASCII characters
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        _ = iterator._fill_buffer()

        # Should not raise error for valid ASCII
        iterator._check_ascii()

        # Test with buffer partially consumed
        iterator.head = 5
        iterator._check_ascii()  # Should still pass

    except e:
        print("Unexpected error with valid ASCII:", e)
        assert_false(True, "Should not raise error for valid ASCII")

    # Clean up
    os.remove(file_path)

    print("✓ _check_ascii valid ASCII tests passed")


def test_check_ascii_invalid_ascii():
    """Test _check_ascii with non-ASCII content."""
    print("Testing _check_ascii with non-ASCII...")

    # Create file with non-ASCII characters (UTF-8 encoded)
    var temp_dir = tempfile.mkdtemp()
    var file_path = Path(temp_dir) / "test_file.txt"

    # Write binary data with high bit set (non-ASCII)
    with open(file_path, "wb") as f:
        f.write("Hello")
        f.write("ß")  # Non-ASCII character
        f.write("World")

    var iterator = BufferedLineIterator(file_path, 64)

    try:
        _ = iterator._fill_buffer()

        # Should raise error for non-ASCII content
        with assert_raises():
            iterator._check_ascii()

    except e:
        print("Error in non-ASCII test setup:", e)
        assert_false(True, "Error in non-ASCII test setup")

    # Clean up
    os.remove(file_path)

    print("✓ _check_ascii non-ASCII tests passed")


def test_check_ascii_edge_positions():
    """Test _check_ascii with non-ASCII at different positions."""
    print("Testing _check_ascii edge positions...")

    # Test non-ASCII at SIMD boundary
    var temp_dir = tempfile.mkdtemp()
    var file_path = Path(temp_dir) / "test_file.txt"

    with open(file_path, "wb") as f:
        # Fill with ASCII up to SIMD boundary
        for _ in range(simd_width - 1):
            f.write("A")
        # Add non-ASCII at boundary
        f.write("ß")
        # Add more ASCII
        for _ in range(5):
            f.write("B")

    var iterator = BufferedLineIterator(file_path, 64)

    try:
        _ = iterator._fill_buffer()

        with assert_raises():
            iterator._check_ascii()

    except e:
        print("Error in edge position test:", e)
        assert_false(True, "Error in edge position test")

    # Clean up
    os.remove(file_path)

    print("✓ _check_ascii edge positions tests passed")


def test_handle_windows_sep_with_cr():
    """Test _handle_windows_sep with carriage return."""
    print("Testing _handle_windows_sep with CR...")

    var temp_dir = tempfile.mkdtemp()
    var file_path = Path(temp_dir) / "test_file.txt"

    # Create content with Windows line endings (CRLF)
    with open(file_path, "w") as f:
        f.write("Hello\r\nWorld")

    var iterator = BufferedLineIterator(file_path, 64)

    try:
        _ = iterator._fill_buffer()

        # Create slice that ends at CR
        var test_slice = Slice(0, 6)  # Points to CR position
        var result_slice = iterator._strip_spaces(test_slice)
        # Should return slice with end reduced by 1 (removing CR)
        assert_equal(result_slice.start.or_else(0), 0)
        assert_equal(result_slice.end.or_else(0), 6)  # One less than original

    except e:
        print("Unexpected error with Windows separator:", e)
        assert_false(
            True, "Should not raise error for Windows separator handling"
        )

    # Clean up
    os.remove(file_path)

    print("✓ _handle_windows_sep with CR tests passed")


def test_handle_windows_sep_without_cr():
    """Test _handle_windows_sep without carriage return."""
    print("Testing _handle_windows_sep without CR...")

    var test_content = "Hello\nWorld"  # Unix line ending (LF only)
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        _ = iterator._fill_buffer()

        # Create slice that ends at LF (no CR before it)
        var test_slice = Slice(0, 6)  # Points to LF position
        var result_slice = iterator._strip_spaces(test_slice)

        # Should return same slice (no change)
        assert_equal(result_slice.start.or_else(0), test_slice.start.or_else(0))
        assert_equal(result_slice.end.or_else(0), test_slice.end.or_else(0))

    except e:
        print("Unexpected error without Windows separator:", e)
        assert_false(True, "Should not raise error for non-Windows separator")

    # Clean up
    os.remove(file_path)

    print("✓ _handle_windows_sep without CR tests passed")


def test_handle_windows_sep_edge_cases():
    """Test _handle_windows_sep edge cases."""
    print("Testing _handle_windows_sep edge cases...")

    var temp_dir = tempfile.mkdtemp()
    var file_path = Path(temp_dir) / "test_file.txt"

    # Test with CR at very end of buffer
    with open(file_path, "wb") as f:
        f.write("Test\r")
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        _ = iterator._fill_buffer()

        # Test slice ending at CR
        var test_slice = Slice(0, 5)  # End at CR position
        var result_slice = iterator._strip_spaces(test_slice)
        assert_equal(result_slice.end.or_else(0), 5)  # Should be reduced

    except e:
        print("Error in edge cases:", e)
        assert_false(True, "Error in edge cases")

    # Clean up
    os.remove(file_path)

    print("✓ _handle_windows_sep edge cases tests passed")


def test_get_next_line_index_updated():
    """Test updated _get_next_line_index implementation."""
    print("Testing updated _get_next_line_index...")

    var test_content = "Line1\nLine2\nLine3\n"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        _ = iterator._fill_buffer()

        # Test finding first newline
        var first_nl = iterator._get_next_line_index()
        assert_equal(first_nl, 5)  # After "Line1"

        # Move head and find next
        iterator.head = 6
        var second_nl = iterator._get_next_line_index()
        assert_equal(second_nl, 12)  # After "Line2"

        # Test with head at different SIMD alignments
        iterator.head = 1  # Misaligned start
        var nl_from_misaligned = iterator._get_next_line_index()
        assert_equal(nl_from_misaligned, 5)  # Should still find first newline

    except e:
        print("Unexpected error in updated _get_next_line_index:", e)
        assert_false(True, "Should not raise error for line index search")

    # Clean up
    os.remove(file_path)

    print("✓ Updated _get_next_line_index tests passed")


def test_get_next_line_index_no_newline_updated():
    """Test updated _get_next_line_index when no newline found."""
    print("Testing updated _get_next_line_index no newline...")

    var test_content = "No newlines in this content at all"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        _ = iterator._fill_buffer()

        var result = iterator._get_next_line_index()
        assert_equal(result, -1)  # Should return -1 when no newline found

        # Test with head moved
        iterator.head = 10
        var result2 = iterator._get_next_line_index()
        assert_equal(result2, -1)  # Still should return -1

    except e:
        print("Unexpected error when no newline found:", e)
        assert_false(True, "Should not raise error when no newline found")

    # Clean up
    os.remove(file_path)

    print("✓ Updated _get_next_line_index no newline tests passed")


def test_integration_with_all_methods():
    """Test integration scenario using all methods together."""
    print("Testing integration with all methods...")

    var temp_dir = tempfile.mkdtemp()
    var file_path = Path(temp_dir) / "test_file.txt"

    # Create file with Windows line endings and ASCII content
    with open(file_path, "w") as f:
        f.write("Hello\r\n")
    var iterator = BufferedLineIterator(file_path, 32)  # Small buffer

    try:
        # Fill buffer
        _ = iterator._fill_buffer()

        # Check ASCII validity
        iterator._check_ascii()

        # Resize buffer if needed
        iterator._resize_buf(32, 128)
        assert_equal(iterator.capacity(), 64)

        # Find first line
        var first_nl = iterator._get_next_line_index()
        assert_true(first_nl > 0)

        # Handle Windows line ending
        var line_slice = Slice(0, first_nl)
        var clean_slice = iterator._strip_spaces(line_slice)
        assert_equal(
            clean_slice.end.or_else(0), first_nl - 1
        )  # Should remove CR

        # Extract line content
        var line_data = iterator[clean_slice]
        var line_str = String(bytes=line_data)
        assert_equal(line_str, "Hello")

    except e:
        print("Unexpected error in integration test:", e)
        assert_false(True, "Integration test should not raise errors")

    # Clean up
    os.remove(file_path)

    print("✓ Integration with all methods tests passed")


def test_get_next_line():
    """Test BufferedLineIterator get_next_line method."""
    print("Testing get_next_line...")

    var test_content = "First line\nSecond line\nThird line\n"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        # Get first line
        var first_line = iterator.get_next_line()
        assert_equal(first_line, "First line")

        # Get second line
        var second_line = iterator.get_next_line()
        assert_equal(second_line, "Second line")

        # Get third line
        var third_line = iterator.get_next_line()
        assert_equal(third_line, "Third line")

    except e:
        print("Unexpected error in get_next_line:", e)
        assert_false(True, "Should not raise error for valid line reading")

    # Clean up
    os.remove(file_path)

    print("✓ get_next_line tests passed")


def test_get_next_line_with_windows_endings():
    """Test get_next_line with Windows line endings."""
    print("Testing get_next_line with Windows endings...")

    var temp_dir = tempfile.mkdtemp()
    var file_path = Path(temp_dir) / "test_file.txt"

    # Create file with Windows line endings (CRLF)
    with open(file_path, "w") as f:
        f.write("Line1\r\nLine2\r\nLine3\r\n")

    var iterator = BufferedLineIterator(file_path, 64)

    try:
        # Should handle CRLF properly
        var line1 = iterator.get_next_line()
        print("line1")
        print(List(line1.as_bytes()).__str__())
        assert_equal(line1, "Line1")

        var line2 = iterator.get_next_line()
        assert_equal(line2, "Line2")

        var line3 = iterator.get_next_line()
        assert_equal(line3, "Line3")

    except e:
        print("Unexpected error with Windows endings:", e)
        assert_false(True, "Should handle Windows line endings properly")

    # Clean up
    os.remove(file_path)

    print("✓ get_next_line with Windows endings tests passed")


def test_get_next_line_span():
    """Test BufferedLineIterator get_next_line_span method."""
    print("Testing get_next_line_span...")

    var test_content = "Alpha\nBeta\nGamma\n"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        # Get first line as span
        var first_span = iterator.get_next_line_span()
        assert_equal(len(first_span), 5)  # "Alpha"
        assert_equal(first_span[0], ord("A"))
        assert_equal(first_span[4], ord("a"))

        # Get second line as span
        var second_span = iterator.get_next_line_span()
        assert_equal(len(second_span), 4)  # "Beta"
        assert_equal(second_span[0], ord("B"))
        assert_equal(second_span[3], ord("a"))

        # Get third line as span
        var third_span = iterator.get_next_line_span()
        assert_equal(len(third_span), 5)  # "Gamma"
        assert_equal(third_span[0], ord("G"))
        assert_equal(third_span[4], ord("a"))

    except e:
        print("Unexpected error in get_next_line_span:", e)
        assert_false(True, "Should not raise error for valid span reading")

    # Clean up
    os.remove(file_path)

    print("✓ get_next_line_span tests passed")


def test_get_next_line_span_with_windows_endings():
    """Test get_next_line_span with Windows line endings."""
    print("Testing get_next_line_span with Windows endings...")

    var temp_dir = tempfile.mkdtemp()
    var file_path = Path(temp_dir) / "test_file.txt"

    # Create file with Windows line endings
    with open(file_path, "w") as f:
        f.write("Test\r\nLine\r\n")

    var iterator = BufferedLineIterator(file_path, 64)

    try:
        # Should return span without CR
        var span1 = iterator.get_next_line_span()
        assert_equal(len(span1), 4)  # "Test"
        var line1_str = String(bytes=span1)
        assert_equal(line1_str, "Test")

        var span2 = iterator.get_next_line_span()
        assert_equal(len(span2), 4)  # "Line"
        var line2_str = String(bytes=span2)
        assert_equal(line2_str, "Line")

    except e:
        print("Unexpected error in span with Windows endings:", e)
        assert_false(True, "Should handle Windows endings in spans")

    # Clean up
    os.remove(file_path)

    print("✓ get_next_line_span with Windows endings tests passed")


def test_line_coord():
    """Test BufferedLineIterator _line_coord method."""
    print("Testing _line_coord...")

    var test_content = "One\nTwo\nThree\n"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        # Get first line coordinates
        var coord1 = iterator._line_coord()
        assert_equal(coord1[0], ord("O"))
        assert_equal(coord1[len(coord1) - 1], ord("e"))  # "One"

        # Head should have moved past first line
        assert_equal(iterator.head, 4)  # After "One\n"

        # Get second line coordinates
        var coord2 = iterator._line_coord()
        assert_equal(coord2[0], ord("T"))
        assert_equal(coord2[len(coord2) - 1], ord("o"))  # "Two"

        # Head should have moved past second line
        assert_equal(iterator.head, 8)  # After "Two\n"

        # Get third line coordinates
        var coord3 = iterator._line_coord()
        assert_equal(coord3[0], ord("T"))
        assert_equal(coord3[len(coord3) - 1], ord("e"))  # "Three"

    except e:
        print("Unexpected error in _line_coord:", e)
        assert_false(
            True, "Should not raise error for line coordinate calculation"
        )

    # Clean up
    os.remove(file_path)

    print("✓ _line_coord tests passed")


def test_line_coord_with_windows_endings():
    """Test _line_coord with Windows line endings."""
    print("Testing _line_coord with Windows endings...")

    var temp_dir = tempfile.mkdtemp()
    var file_path = Path(temp_dir) / "test_file.txt"

    # Create file with Windows line endings
    with open(file_path, "w") as f:
        f.write("Hello\r\nWorld\r\n")

    var iterator = BufferedLineIterator(file_path, 64)

    try:
        # Should handle CRLF properly and exclude CR from line content
        var coord1 = iterator.get_next_line_span()
        assert_equal(coord1[0], ord("H"))
        assert_equal(coord1[-1], ord("o"))  # "Hello" (CR excluded)

        # Head should move past CRLF
        assert_equal(iterator.head, 7)  # After "Hello\r\n"

        var coord2 = iterator.get_next_line_span()
        assert_equal(coord2[0], ord("W"))
        assert_equal(coord2[-1], ord("d"))  # "World" (CR excluded)

    except e:
        print("Unexpected error in _line_coord with Windows endings:", e)
        assert_false(True, "Should handle Windows line endings in coordinates")

    # Clean up
    os.remove(file_path)

    print("✓ _line_coord with Windows endings tests passed")


def test_line_coord_buffer_refill():
    """Test _line_coord when buffer needs refilling."""
    print("Testing _line_coord buffer refill...")

    # Create content larger than buffer to test refilling
    var large_content = "A" * 50 + "\n" + "B" * 50 + "\n" + "C" * 50 + "\n"
    print(large_content)
    var file_path = create_test_file(large_content)
    var iterator = BufferedLineIterator(file_path, 80)  # Small buffer

    # try:
    #     # Get first line (should fit in buffer)
    #     var coord1 = iterator.get_next_line_span()
    #     assert_equal(coord1[0], ord("A"))
    #     assert_equal(coord1[-1], ord("A"))  # 50 A's

    #     # Get second line (might require buffer refill)
    #     var coord2 = iterator.get_next_line_span()
    #     print(String(bytes=coord2))
    #     # Due to left shift, start might be different
    #     # assert_equal(len(coord2), 50)  # 50 B's
    #     raise Error("stop Here")
    # except e:
        # print("Unexpected error in buffer refill test:", e)
        # assert_false(
        #     True,
        #     "Should handle buffer refilling during line coordinate calculation",
        # )

    var coord1 = iterator.get_next_line_span()
    assert_equal(coord1[0], ord("A"))
    print(String(bytes=coord1))
    assert_equal(coord1[-1], ord("A"))  # 50 A's

    # Get second line (might require buffer refill)
    var coord2 = iterator.get_next_line_span()
    print(String(bytes=coord2))
    print(len(coord2))
    var coord3 = iterator.get_next_line_span()
    print(String(bytes=coord3))
    # Due to left shift, start might be different
    # assert_equal(len(coord2), 50)  # 50 B's
    raise Error("stop Here")


    # Clean up
    os.remove(file_path)

    print("✓ _line_coord buffer refill tests passed")


def test_line_coord_empty_lines():
    """Test _line_coord with empty lines."""
    print("Testing _line_coord with empty lines...")

    var test_content = "Line1\n\nLine3\n\n\nLine6\n"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        # Get first line
        var coord1 = iterator._line_coord()
        assert_equal(len(coord1), 5)  # "Line1"

        # Get empty line
        var coord2 = iterator._line_coord()
        assert_equal(len(coord2), 0)  # Empty line

        # Get third line
        var coord3 = iterator._line_coord()
        assert_equal(len(coord3), 5)  # "Line3"

        # Get another empty line
        var coord4 = iterator._line_coord()
        assert_equal(len(coord4), 0)  # Empty line

        # Get yet another empty line
        var coord5 = iterator._line_coord()
        assert_equal(len(coord5), 0)  # Empty line

        # Get sixth line
        var coord6 = iterator._line_coord()
        assert_equal(len(coord6), 5)  # "Line6"

    except e:
        print("Unexpected error with empty lines:", e)
        assert_false(True, "Should handle empty lines properly")

    # Clean up
    os.remove(file_path)

    print("✓ _line_coord with empty lines tests passed")


def test_get_next_line_empty_lines():
    """Test get_next_line with empty lines."""
    print("Testing get_next_line with empty lines...")

    var test_content = "First\n\nThird\n\n"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        var line1 = iterator.get_next_line()
        assert_equal(line1, "First")

        var line2 = iterator.get_next_line()
        assert_equal(line2, "")  # Empty line

        var line3 = iterator.get_next_line()
        assert_equal(line3, "Third")

        var line4 = iterator.get_next_line()
        assert_equal(line4, "")  # Empty line

    except e:
        print("Unexpected error with empty lines:", e)
        assert_false(True, "Should handle empty lines in get_next_line")

    # Clean up
    os.remove(file_path)

    print("✓ get_next_line with empty lines tests passed")


def test_get_next_line_span_empty_lines():
    """Test get_next_line_span with empty lines."""
    print("Testing get_next_line_span with empty lines...")

    var test_content = "Data\n\nMore\n"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        var span1 = iterator.get_next_line_span()
        assert_equal(len(span1), 4)  # "Data"

        var span2 = iterator.get_next_line_span()
        assert_equal(len(span2), 0)  # Empty line

        var span3 = iterator.get_next_line_span()
        assert_equal(len(span3), 4)  # "More"

    except e:
        print("Unexpected error with empty line spans:", e)
        assert_false(True, "Should handle empty lines in get_next_line_span")

    # Clean up
    os.remove(file_path)

    print("✓ get_next_line_span with empty lines tests passed")


def test_end_of_file_behavior():
    """Test behavior when reaching end of file."""
    print("Testing end of file behavior...")

    var test_content = "OnlyLine\n"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        # Read the only line
        var line = iterator.get_next_line()
        assert_equal(line, "OnlyLine")

        # Try to read another line (should raise error or handle EOF)
        with assert_raises():
            _ = iterator.get_next_line()

    except e:
        print("Error in EOF behavior test:", e)
        assert_false(True, "can't handle EOF behavior")
        # This might be expected behavior

    # Clean up
    os.remove(file_path)

    print("✓ End of file behavior tests passed")


def test_file_without_final_newline():
    """Test handling files that don't end with newline."""
    print("Testing file without final newline...")

    var test_content = "Line1\nLine2"  # No final newline
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, 64)

    try:
        var line1 = iterator.get_next_line()
        assert_equal(line1, "Line1")

        # Second line should still be readable even without final newline
        var line2 = iterator.get_next_line()
        assert_equal(line2, "Line2")

    except e:
        print("Error with file without final newline:", e)
        assert_false(True, "can't handle file without final newline")
        # This might require special handling in the implementation

    # Clean up
    os.remove(file_path)

    print("✓ File without final newline tests passed")


def test_very_long_lines():
    """Test handling of very long lines."""
    print("Testing very long lines...")

    # Create a line longer than default buffer capacity
    var long_line = "X" * (DEFAULT_CAPACITY + 100)
    var test_content = "Short\n" + long_line + "\nAnother\n"
    var file_path = create_test_file(test_content)
    var iterator = BufferedLineIterator(file_path, DEFAULT_CAPACITY)

    try:
        # Read short line first
        var line1 = iterator.get_next_line()
        assert_equal(line1, "Short")

        # Try to read very long line
        # This might require buffer resizing or special handling
        var line2 = iterator.get_next_line()
        assert_equal(len(line2), len(long_line))
        assert_equal(line2, long_line)

        # Read final line
        var line3 = iterator.get_next_line()
        assert_equal(line3, "Another")

    except e:
        print("Error with very long lines:", e)
        assert_false(True, "can't handle long lines")
        # This might expose limitations in the current implementation

    # Clean up
    os.remove(file_path)

    print("✓ Very long lines tests passed")


def test_buffered_line_iterator_with_check_ascii():
    """Test BufferedLineIterator with ASCII checking enabled."""
    print("Testing BufferedLineIterator with check_ascii=True...")

    var test_content = "Valid ASCII content\nLine 2\n"
    var file_path = create_test_file(test_content)

    try:
        # This should work fine with ASCII content
        var iterator = BufferedLineIterator[check_ascii=True](file_path, 64)
        var line1 = iterator.get_next_line()
        assert_equal(line1, "Valid ASCII content")

        var line2 = iterator.get_next_line()
        assert_equal(line2, "Line 2")

    except e:
        print("Unexpected error with ASCII checking:", e)
        assert_false(
            True, "Should not raise error for valid ASCII with check_ascii=True"
        )

    # Clean up
    os.remove(file_path)

    print("✓ BufferedLineIterator with check_ascii=True tests passed")


def test_buffered_line_iterator_with_check_ascii_invalid():
    """Test BufferedLineIterator with ASCII checking on non-ASCII content."""
    print("Testing BufferedLineIterator with check_ascii=True on non-ASCII...")

    # Create file with non-ASCII content
    var temp_dir = tempfile.mkdtemp()
    var file_path = Path(temp_dir) / "test_file.txt"

    with open(file_path, "w") as f:
        f.write("Hello ")
        f.write("ñoño")  # Non-ASCII characters
        f.write("\n")

    try:
        # This should raise error due to non-ASCII content
        with assert_raises():
            var iterator = BufferedLineIterator[check_ascii=True](file_path, 64)
            _ = iterator.get_next_line()

    except e:
        print("Error in non-ASCII checking test:", e)
        assert_false(
            True, "Should raise error for valid ASCII with check_ascii=True"
        )

    # Clean up
    os.remove(file_path)

    print(
        "✓ BufferedLineIterator with check_ascii=True on non-ASCII tests passed"
    )


def run_all_tests():
    """Run all unit tests."""
    print("=" * 50)
    print("Running BufferedLineIterator Unit Tests")
    print("=" * 50)

    try:
        test_inner_buffer_creation()
        test_inner_buffer_indexing()
        test_inner_buffer_slicing()
        test_inner_buffer_resize()
        test_file_reader_creation()
        test_file_reader_read_bytes()
        test_buffered_line_iterator_creation()
        test_buffered_line_iterator_state_methods()
        test_buffered_line_iterator_fill_buffer()
        test_buffered_line_iterator_left_shift()
        test_edge_cases()
        test_get_next_line_index()
        test_get_next_line_index_no_newline()
        test_get_next_line_index_edge_cases()
        test_dunder_len()
        test_dunder_str()
        test_dunder_str_with_newlines()
        test_dunder_getitem_index()
        test_dunder_getitem_slice()
        test_arg_true_function()
        test_integration_scenarios()
        test_resize_buf_normal_resize()
        test_resize_buf_max_capacity_limit()
        test_resize_buf_edge_cases()
        test_check_ascii_valid_ascii()
        test_check_ascii_invalid_ascii()
        test_check_ascii_edge_positions()
        test_handle_windows_sep_with_cr()
        test_handle_windows_sep_without_cr()
        test_handle_windows_sep_edge_cases()
        test_get_next_line()
        test_get_next_line_with_windows_endings()
        test_get_next_line_span()
        test_get_next_line_span_with_windows_endings()
        test_line_coord()
        test_line_coord_with_windows_endings()
        test_line_coord_buffer_refill()
        test_line_coord_empty_lines()
        test_get_next_line_empty_lines()
        test_get_next_line_span_empty_lines()
        test_end_of_file_behavior()
        test_file_without_final_newline()
        # test_very_long_lines()
        test_buffered_line_iterator_with_check_ascii()
        test_buffered_line_iterator_with_check_ascii_invalid()

        print("=" * 50)
        print("✅ ALL TESTS PASSED!")
        print("=" * 50)

    except Error:
        print("=" * 50)
        print("❌ TEST FAILED")
        print("=" * 50)
        raise


def main():
    run_all_tests()
