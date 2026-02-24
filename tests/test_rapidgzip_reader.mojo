"""Tests for RapidgzipReader from blazeseq.io.readers."""

from testing import assert_equal, assert_raises, assert_true, TestSuite
from pathlib import Path
from os import remove
from memory import alloc, Span, memcpy
from blazeseq.io.readers import RapidgzipReader
from blazeseq.io.writers import GZWriter
from blazeseq.io.buffered import LineIterator, buffered_writer_for_gzip
from blazeseq.parser import FastqParser
from blazeseq.record import FastqRecord


# ============================================================================
# Helper Functions
# ============================================================================


fn create_gz_file(path: String, content: List[Byte]) raises:
    """Create a gzip file with the given content."""
    var writer = GZWriter(path)
    var buf = alloc[Byte](len(content))
    memcpy(dest=buf, src=content.unsafe_ptr(), count=len(content))
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=len(content))
    _ = writer.write_from_buffer(span, len(content), 0)
    buf.free()


fn create_fastq_gz_file(path: String, content: String) raises:
    """Create a .fastq.gz file with the given FASTQ content."""
    var writer = buffered_writer_for_gzip(path)
    var bytes = List(content.as_bytes())
    writer.write_bytes(bytes)
    writer.flush()


# ============================================================================
# RapidgzipReader Basic Tests
# ============================================================================


fn test_rapidgzip_reader_init() raises:
    """Test RapidgzipReader initialization."""
    var content = List[Byte]()
    content.append(72)  # 'H'
    content.append(101)  # 'e'
    content.append(108)  # 'l'
    content.append(108)  # 'l'
    content.append(111)  # 'o'
    create_gz_file("tests/test_data/test_rapidgzip_init.gz", content)

    var reader = RapidgzipReader("tests/test_data/test_rapidgzip_init.gz")
    var buf = alloc[Byte](5)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=5)
    var bytes_read = reader.read_to_buffer(span, 5, pos=0)

    assert_equal(bytes_read, 5, "Should read 5 bytes")
    assert_equal(span[0], 72, "First byte should be 'H'")
    assert_equal(span[4], 111, "Fifth byte should be 'o'")

    buf.free()
    print("✓ test_rapidgzip_reader_init passed")


fn test_rapidgzip_reader_init_path() raises:
    """Test RapidgzipReader initialization with Path."""
    var content = List[Byte]()
    content.append(65)  # 'A'
    content.append(66)  # 'B'
    create_gz_file("tests/test_data/test_rapidgzip_init_path.gz", content)

    var path = Path("tests/test_data") / Path("test_rapidgzip_init_path.gz")
    var reader = RapidgzipReader(path)
    var buf = alloc[Byte](2)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=2)
    var bytes_read = reader.read_to_buffer(span, 2, pos=0)

    assert_equal(bytes_read, 2, "Should read 2 bytes")
    assert_equal(span[0], 65, "First byte should be 'A'")
    assert_equal(span[1], 66, "Second byte should be 'B'")

    buf.free()
    print("✓ test_rapidgzip_reader_init_path passed")


fn test_rapidgzip_reader_read_to_buffer() raises:
    """Test RapidgzipReader read_to_buffer basic functionality."""
    var content = List[Byte]()
    for i in range(20):
        content.append(Byte(i))
    create_gz_file("tests/test_data/test_rapidgzip_read.gz", content)

    var reader = RapidgzipReader("tests/test_data/test_rapidgzip_read.gz")
    var buf = alloc[Byte](20)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=20)
    var bytes_read = reader.read_to_buffer(span, 20, pos=0)

    assert_equal(bytes_read, 20, "Should read 20 bytes")
    for i in range(20):
        assert_equal(span[i], Byte(i), "Byte should match")

    buf.free()
    print("✓ test_rapidgzip_reader_read_to_buffer passed")


fn test_rapidgzip_reader_read_to_buffer_partial() raises:
    """Test RapidgzipReader read_to_buffer with partial reads."""
    var content = List[Byte]()
    for i in range(10):
        content.append(Byte(i + 65))  # 'A'-'J'
    create_gz_file("tests/test_data/test_rapidgzip_partial.gz", content)

    var reader = RapidgzipReader("tests/test_data/test_rapidgzip_partial.gz")
    var buf = alloc[Byte](5)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=5)

    var bytes_read1 = reader.read_to_buffer(span, 5, pos=0)
    assert_equal(bytes_read1, 5, "First read should return 5 bytes")
    assert_equal(span[0], 65, "First byte should be 'A'")

    var bytes_read2 = reader.read_to_buffer(span, 5, pos=0)
    assert_equal(bytes_read2, 5, "Second read should return 5 bytes")
    assert_equal(span[0], 70, "First byte of second read should be 'F'")

    var bytes_read3 = reader.read_to_buffer(span, 5, pos=0)
    assert_equal(bytes_read3, 0, "Third read should return 0 (EOF)")

    buf.free()
    print("✓ test_rapidgzip_reader_read_to_buffer_partial passed")


fn test_rapidgzip_reader_eof() raises:
    """Test RapidgzipReader returns 0 at EOF."""
    var content = List[Byte]()
    content.append(1)
    create_gz_file("tests/test_data/test_rapidgzip_eof.gz", content)

    var reader = RapidgzipReader("tests/test_data/test_rapidgzip_eof.gz")
    var buf = alloc[Byte](10)
    var span = Span[Byte, MutExternalOrigin](ptr=buf, length=10)

    var bytes_read1 = reader.read_to_buffer(span, 10, pos=0)
    assert_equal(bytes_read1, 1, "Should read 1 byte")

    var bytes_read2 = reader.read_to_buffer(span, 10, pos=0)
    assert_equal(bytes_read2, 0, "Should return 0 at EOF")

    buf.free()
    print("✓ test_rapidgzip_reader_eof passed")


fn test_rapidgzip_reader_with_buffered_reader() raises:
    """Test RapidgzipReader works with BufferedReader (same as GZFile)."""
    var content = "Hello World\nLine 2\n"
    var content_bytes = List(content.as_bytes())
    create_gz_file("tests/test_data/test_rapidgzip_buffered.gz", content_bytes)

    var reader = RapidgzipReader("tests/test_data/test_rapidgzip_buffered.gz")
    var line_iter = LineIterator(reader^)
    var bytes_read = line_iter.read_exact(18)
    assert_equal(len(bytes_read), 18, "Should read 18 bytes")
    assert_equal(bytes_read[0], 72, "First byte should be 'H'")
    assert_equal(bytes_read[12], 76, "Byte 13 (L) should be 'L'")
    _ = line_iter

    print("✓ test_rapidgzip_reader_with_buffered_reader passed")


fn test_rapidgzip_reader_fastq_parser() raises:
    """Test FastqParser with RapidgzipReader on .fastq.gz file."""
    var fastq_content = "@r1\nACGT\n+\n!!!!\n@r2\nTGCA\n+\n####\n"
    create_fastq_gz_file("tests/test_data/test_rapidgzip_fastq.fastq.gz", fastq_content)

    var reader = RapidgzipReader("tests/test_data/test_rapidgzip_fastq.fastq.gz")
    var parser = FastqParser[RapidgzipReader](reader^, "generic")
    var records = List[FastqRecord]()
    for record in parser.records():
        records.append(record^)

    assert_equal(len(records), 2, "Should parse 2 records")
    assert_equal(records[0].id.to_string(), "@r1", "First record id should match")
    assert_equal(records[0].sequence.to_string(), "ACGT", "First record sequence should match")
    assert_equal(records[1].id.to_string(), "@r2", "Second record id should match")
    assert_equal(records[1].sequence.to_string(), "TGCA", "Second record sequence should match")

    print("✓ test_rapidgzip_reader_fastq_parser passed")


fn test_rapidgzip_reader_init_nonexistent() raises:
    """Test RapidgzipReader initialization with nonexistent file."""
    with assert_raises():
        var reader = RapidgzipReader("tests/test_data/nonexistent_rapidgzip.gz")
        _ = reader

    print("✓ test_rapidgzip_reader_init_nonexistent passed")


# ============================================================================
# Cleanup
# ============================================================================


fn cleanup_rapidgzip_test_files() raises:
    """Remove test files created by RapidgzipReader tests."""
    var names = List[String]()
    names.append("test_rapidgzip_init.gz")
    names.append("test_rapidgzip_init_path.gz")
    names.append("test_rapidgzip_read.gz")
    names.append("test_rapidgzip_partial.gz")
    names.append("test_rapidgzip_eof.gz")
    names.append("test_rapidgzip_buffered.gz")
    names.append("test_rapidgzip_fastq.fastq.gz")
    for name in names:
        try:
            remove(Path("tests/test_data") / Path(name))
        except:
            pass


# ============================================================================
# Test Suite
# ============================================================================


fn main() raises:
    """Run all RapidgzipReader tests."""
    print("Running RapidgzipReader tests...\n")
    TestSuite.discover_tests[__functions_in_module()]().run()
    cleanup_rapidgzip_test_files()
    print("\n✓ All RapidgzipReader tests passed!")
