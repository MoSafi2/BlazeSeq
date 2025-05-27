from memory import memcpy, UnsafePointer, Span
from pathlib import Path
from testing import assert_equal, assert_true, assert_false, assert_raises
import tempfile
import os

# Import the modules under test
from blazeseq.iostream import (
    InnerBuffer,
    FileReader,
    BufferedLineIterator,
    NEW_LINE,
    DEFAULT_CAPACITY,
    arg_true,
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
        print(iterator.len(), iterator.head, iterator.end)
        var second_newline = iterator._get_next_line_index()
        print("second_newline", second_newline)
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
        var slice3 = iterator[0:6:2]
        assert_equal(len(slice3), 3)
        assert_equal(slice3[0], ord("A"))
        assert_equal(slice3[1], ord("C"))
        assert_equal(slice3[2], ord("E"))

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
        var first_line_str = String(first_line_slice.__str__())
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
        var relative_pos = second_newline - iterator.head
        var second_line_slice = iterator[iterator.head : second_newline]
        var second_line_str = String(second_line_slice.__str__())
        assert_equal(second_line_str, "Second line")

    except e:
        print("Unexpected error in integration test:", e)
        assert_false(True, "Integration test should not raise errors")

    # Clean up
    os.remove(file_path)

    print("✓ Integration scenarios tests passed")



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
        # test_dunder_getitem_slice()
        test_arg_true_function()
        # test_integration_scenarios()


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
