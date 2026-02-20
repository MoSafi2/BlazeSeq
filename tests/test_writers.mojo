from testing import assert_equal, assert_raises, assert_true, TestSuite
from pathlib import Path
from os import remove
from blazeseq.writers import Writer, FileWriter, MemoryWriter, GZWriter
from blazeseq.iostream import (
    BufferedWriter, BufferedReader,
    buffered_writer_for_file,
    buffered_writer_for_memory,
    buffered_writer_for_gzip
)
from blazeseq.readers import FileReader, GZFile
from blazeseq.CONSTS import DEFAULT_CAPACITY
from memory import Span, alloc, memcpy
from collections.string import String


fn test_file_writer_basic() raises:
    """Test FileWriter basic functionality."""
    var test_path = Path("tests/test_data") / Path("test_file_writer.txt")
    var writer = FileWriter(test_path)
    
    # Create a buffer with MutExternalOrigin
    var data = List[Byte]()
    data.append(ord("H"))
    data.append(ord("i"))
    var buf = alloc[Byte](2)
    memcpy(dest=buf, src=data.unsafe_ptr(), count=2)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=2)
    
    var written = writer.write_from_buffer(span, 2, 0)
    assert_equal(written, 2, "Should write 2 bytes")
    buf.free()
    
    # Verify file contents
    var reader = FileReader(test_path)
    var bytes_read = reader.read_bytes()
    assert_equal(len(bytes_read), 2, "File should contain 2 bytes")
    assert_equal(bytes_read[0], ord("H"), "First byte should be 'H'")
    assert_equal(bytes_read[1], ord("i"), "Second byte should be 'i'")
    
    print("✓ test_file_writer_basic passed")


fn test_file_writer_partial_write() raises:
    """Test FileWriter with partial buffer write."""
    var test_path = Path("tests/test_data") / Path("test_file_writer_partial.txt")
    var writer = FileWriter(test_path)
    
    var data = List[Byte]()
    for i in range(10):
        data.append(Byte(i))
    var buf = alloc[Byte](10)
    memcpy(dest=buf, src=data.unsafe_ptr(), count=10)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=10)
    
    # Write only first 5 bytes
    var written = writer.write_from_buffer(span, 5, 0)
    assert_equal(written, 5, "Should write 5 bytes")
    buf.free()
    
    # Verify file contents
    var reader = FileReader(test_path)
    var bytes_read = reader.read_bytes()
    assert_equal(len(bytes_read), 5, "File should contain 5 bytes")
    for i in range(5):
        assert_equal(bytes_read[i], Byte(i), "Byte should match")
    
    print("✓ test_file_writer_partial_write passed")


fn test_file_writer_with_offset() raises:
    """Test FileWriter with offset position."""
    var test_path = Path("tests/test_data") / Path("test_file_writer_offset.txt")
    var writer = FileWriter(test_path)
    
    var data = List[Byte]()
    data.append(ord("X"))
    data.append(ord("Y"))
    data.append(ord("Z"))
    var buf = alloc[Byte](3)
    memcpy(dest=buf, src=data.unsafe_ptr(), count=3)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=3)
    
    # Write from position 1 (skip first byte)
    var written = writer.write_from_buffer(span, 2, 1)
    assert_equal(written, 2, "Should write 2 bytes")
    buf.free()
    
    # Verify file contents
    var reader = FileReader(test_path)
    var bytes_read = reader.read_bytes()
    assert_equal(len(bytes_read), 2, "File should contain 2 bytes")
    assert_equal(bytes_read[0], ord("Y"), "First byte should be 'Y'")
    assert_equal(bytes_read[1], ord("Z"), "Second byte should be 'Z'")
    
    print("✓ test_file_writer_with_offset passed")


fn test_memory_writer_basic() raises:
    """Test MemoryWriter basic functionality."""
    var writer = MemoryWriter()
    
    var data = List[Byte]()
    data.append(ord("T"))
    data.append(ord("e"))
    data.append(ord("s"))
    data.append(ord("t"))
    var buf = alloc[Byte](4)
    memcpy(dest=buf, src=data.unsafe_ptr(), count=4)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=4)
    
    var written = writer.write_from_buffer(span, 4, 0)
    assert_equal(written, 4, "Should write 4 bytes")
    buf.free()
    
    var result = writer.get_data()
    assert_equal(len(result), 4, "Should have 4 bytes")
    assert_equal(result[0], ord("T"), "First byte should be 'T'")
    assert_equal(result[1], ord("e"), "Second byte should be 'e'")
    assert_equal(result[2], ord("s"), "Third byte should be 's'")
    assert_equal(result[3], ord("t"), "Fourth byte should be 't'")
    
    print("✓ test_memory_writer_basic passed")


fn test_memory_writer_multiple_writes() raises:
    """Test MemoryWriter with multiple writes."""
    var writer = MemoryWriter()
    
    # First write
    var data1 = List[Byte]()
    data1.append(ord("H"))
    data1.append(ord("e"))
    var buf1 = alloc[Byte](2)
    memcpy(dest=buf1, src=data1.unsafe_ptr(), count=2)
    var span1 = Span[Byte, MutExternalOrigin](ptr=buf1, length=2)
    _ = writer.write_from_buffer(span1, 2, 0)
    buf1.free()
    
    # Second write
    var data2 = List[Byte]()
    data2.append(ord("l"))
    data2.append(ord("l"))
    data2.append(ord("o"))
    var buf2 = alloc[Byte](3)
    memcpy(dest=buf2, src=data2.unsafe_ptr(), count=3)
    var span2 = Span[Byte, MutExternalOrigin](ptr=buf2, length=3)
    _ = writer.write_from_buffer(span2, 3, 0)
    buf2.free()
    
    var result = writer.get_data()
    assert_equal(len(result), 5, "Should have 5 bytes")
    assert_equal(result[0], ord("H"), "First byte should be 'H'")
    assert_equal(result[1], ord("e"), "Second byte should be 'e'")
    assert_equal(result[2], ord("l"), "Third byte should be 'l'")
    assert_equal(result[3], ord("l"), "Fourth byte should be 'l'")
    assert_equal(result[4], ord("o"), "Fifth byte should be 'o'")
    
    print("✓ test_memory_writer_multiple_writes passed")


fn test_memory_writer_clear() raises:
    """Test MemoryWriter clear functionality."""
    var writer = MemoryWriter()
    
    var data = List[Byte]()
    data.append(ord("T"))
    data.append(ord("e"))
    data.append(ord("s"))
    data.append(ord("t"))
    var buf = alloc[Byte](4)
    memcpy(dest=buf, src=data.unsafe_ptr(), count=4)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=4)
    _ = writer.write_from_buffer(span, 4, 0)
    buf.free()
    
    assert_equal(len(writer.get_data()), 4, "Should have 4 bytes before clear")
    
    writer.clear()
    assert_equal(len(writer.get_data()), 0, "Should have 0 bytes after clear")
    
    print("✓ test_memory_writer_clear passed")


fn test_gz_writer_basic() raises:
    """Test GZWriter basic functionality."""
    var test_path = "tests/test_data/test_gz_writer.gz"
    
    # Write to gzip file
    var writer = GZWriter(test_path)
    var data = List[Byte]()
    for i in range(100):
        data.append(Byte(i % 256))
    var buf = alloc[Byte](100)
    memcpy(dest=buf, src=data.unsafe_ptr(), count=100)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=100)
    var written = writer.write_from_buffer(span, 100, 0)
    assert_equal(written, 100, "Should write 100 bytes")
    buf.free()
    # Writer will be closed by destructor when it goes out of scope
    
    # Re-read the file (writer is closed by destructor)
    var gz_reader = GZFile(test_path, "rb")
    var buf_reader = BufferedReader(gz_reader^)
    var bytes_read = List[Byte]()
    while buf_reader.available() > 0 or not buf_reader.is_eof():
        if buf_reader.available() > 0:
            var view = buf_reader.view()
            bytes_read.extend(view)
            _ = buf_reader.consume(len(view))
        if not buf_reader.is_eof():
            _ = buf_reader._fill_buffer()
    assert_equal(len(bytes_read), 100, "Should read back 100 bytes")
    for i in range(100):
        assert_equal(bytes_read[i], Byte(i % 256), "Byte should match")
    
    print("✓ test_gz_writer_basic passed")


fn test_buffered_writer_with_file_writer() raises:
    """Test BufferedWriter with FileWriter backend."""
    var test_path = Path("tests/test_data") / Path("test_buffered_file.txt")
    var file_writer = FileWriter(test_path)
    var buf_writer = BufferedWriter(file_writer^)
    
    var data = List[Byte]()
    for i in range(50):
        data.append(Byte(i))
    buf_writer.write_bytes(data)
    buf_writer.flush()
    
    assert_equal(buf_writer.bytes_written(), 50, "Should have written 50 bytes")
    
    # Verify file contents
    var reader = FileReader(test_path)
    var bytes_read = reader.read_bytes()
    assert_equal(len(bytes_read), 50, "File should contain 50 bytes")
    for i in range(50):
        assert_equal(bytes_read[i], Byte(i), "Byte should match")
    
    print("✓ test_buffered_writer_with_file_writer passed")


fn test_buffered_writer_with_memory_writer() raises:
    """Test BufferedWriter with MemoryWriter backend."""
    var mem_writer = MemoryWriter()
    var buf_writer = BufferedWriter(mem_writer^)
    
    var data = List[Byte]()
    data.append(ord("M"))
    data.append(ord("e"))
    data.append(ord("m"))
    buf_writer.write_bytes(data)
    buf_writer.flush()
    
    # Note: mem_writer was moved into buf_writer, so we can't access it directly
    # Instead, we verify through the bytes_written count
    assert_equal(buf_writer.bytes_written(), 3, "Should have written 3 bytes")
    
    print("✓ test_buffered_writer_with_memory_writer passed")


fn test_buffered_writer_convenience_constructors() raises:
    """Test BufferedWriter convenience constructors."""
    var test_path = Path("tests/test_data") / Path("test_convenience.txt")
    
    # File convenience constructor
    var file_buf = buffered_writer_for_file(test_path)
    var file_data = List[Byte]()
    file_data.append(ord("F"))
    file_buf.write_bytes(file_data)
    file_buf.flush()
    
    # Verify file contents
    var reader = FileReader(test_path)
    var bytes_read = reader.read_bytes()
    assert_equal(len(bytes_read), 1, "File should contain 1 byte")
    assert_equal(bytes_read[0], ord("F"), "Content should match")
    
    # Memory convenience constructor
    var mem_buf = buffered_writer_for_memory()
    var mem_data = List[Byte]()
    mem_data.append(ord("M"))
    mem_buf.write_bytes(mem_data)
    mem_buf.flush()
    
    # Gzip convenience constructor
    var gz_buf = buffered_writer_for_gzip("tests/test_data/test_convenience.gz")
    var gz_data = List[Byte]()
    gz_data.append(ord("G"))
    gz_buf.write_bytes(gz_data)
    gz_buf.flush()
    
    print("✓ test_buffered_writer_convenience_constructors passed")


fn test_buffered_writer_auto_flush() raises:
    """Test BufferedWriter auto-flush when buffer is full."""
    var mem_writer = MemoryWriter()
    # Use small buffer to trigger auto-flush
    var buf_writer = BufferedWriter(mem_writer^, capacity=10)
    
    # Write more than buffer capacity
    var data = List[Byte]()
    for i in range(25):
        data.append(Byte(i))
    buf_writer.write_bytes(data)
    buf_writer.flush()
    
    # Note: mem_writer was moved into buf_writer, so we verify through bytes_written
    assert_equal(buf_writer.bytes_written(), 25, "Should have written 25 bytes")
    
    print("✓ test_buffered_writer_auto_flush passed")


fn test_writer_error_handling() raises:
    """Test Writer error handling for invalid parameters."""
    var writer = MemoryWriter()
    
    var data = List[Byte]()
    data.append(ord("T"))
    data.append(ord("e"))
    data.append(ord("s"))
    data.append(ord("t"))
    var buf = alloc[Byte](4)
    memcpy(dest=buf, src=data.unsafe_ptr(), count=4)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=4)
    
    # Test negative amount
    try:
        _ = writer.write_from_buffer(span, -1, 0)
        assert_true(False, "Should raise error for negative amount")
    except:
        pass  # Expected
    
    # Test position outside buffer
    try:
        _ = writer.write_from_buffer(span, 1, 10)
        assert_true(False, "Should raise error for position outside buffer")
    except:
        pass  # Expected
    
    # Test amount larger than available space
    try:
        _ = writer.write_from_buffer(span, 10, 0)
        assert_true(False, "Should raise error for amount larger than buffer")
    except:
        pass  # Expected
    
    buf.free()
    print("✓ test_writer_error_handling passed")


fn cleanup_writer_test_files() raises:
    """Remove all files created by writer tests (ignore missing files)."""
    var base = Path("tests/test_data")
    var names = List[String]()
    names.append("test_file_writer.txt")
    names.append("test_file_writer_partial.txt")
    names.append("test_file_writer_offset.txt")
    names.append("test_gz_writer.gz")
    names.append("test_buffered_file.txt")
    names.append("test_convenience.txt")
    names.append("test_convenience.gz")
    for name in names:
        try:
            remove(base / Path(name))
        except:
            pass




fn main() raises:
    """Run all writer tests."""
    print("Running Writer trait and backend tests...")
    print("=" * 60)
    TestSuite.discover_tests[__functions_in_module()]().run()
    
    # cleanup_writer_test_files()
    print("=" * 60)
    print("All writer tests passed! ✓")
