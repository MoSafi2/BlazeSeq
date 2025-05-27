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

    var test_content = "Hello, World!\nThis is a test.\n"
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
        # test_file_reader_creation()
        # test_file_reader_read_bytes()
        # test_buffered_line_iterator_creation()
        # test_buffered_line_iterator_state_methods()
        # test_buffered_line_iterator_fill_buffer()
        # test_buffered_line_iterator_left_shift()
        # test_edge_cases()

        # print("=" * 50)
        # print("✅ ALL TESTS PASSED!")
        # print("=" * 50)

    except Error:
        print("=" * 50)
        print("❌ TEST FAILED")
        print("=" * 50)
        raise


def main():
    run_all_tests()
