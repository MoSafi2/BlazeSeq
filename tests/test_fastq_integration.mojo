"""Integration tests: FASTQ read → parse → write (plain/gzip) → read → parse → compare.

Round-trips FASTQ through plain and gzipped paths and asserts re-parsed records
match the originals (full record equality: SeqHeader, SeqStr, QuHeader, QuStr, quality_offset).

Small fixtures: tests/test_data/fastq_parser/example.fastq (3 records).
Large fixtures: generated synthetic reads written to tests/test_data/ (see
generate_synthetic_fastq_fixtures) so round-trip tests can run on larger data.
"""

from pathlib import Path
from os import remove
from testing import assert_equal, TestSuite
from blazeseq.record import FastqRecord
from blazeseq.parser import FastqParser
from blazeseq.readers import FileReader, GZFile
from blazeseq.writers import WriterBackend
from blazeseq.iostream import (
    BufferedWriter,
    buffered_writer_for_file,
    buffered_writer_for_gzip,
)
from blazeseq.utils import generate_synthetic_fastq_buffer

comptime EXAMPLE_FASTQ = "tests/test_data/fastq_parser/example.fastq"
comptime SCHEMA = "sanger"

# Synthetic fixture size (number of reads) for large round-trip tests
comptime NUM_SYNTHETIC_READS = 1000
comptime SYNTHETIC_MIN_LEN = 50
comptime SYNTHETIC_MAX_LEN = 150
comptime SYNTHETIC_MIN_PHRED = 0
comptime SYNTHETIC_MAX_PHRED = 40

comptime SYNTHETIC_PLAIN_PATH = "tests/test_data/fastq_integration_synthetic.fastq"
comptime SYNTHETIC_GZ_PATH = "tests/test_data/fastq_integration_synthetic.fastq.gz"


# ---------------------------------------------------------------------------
# Helper: full record comparison
# ---------------------------------------------------------------------------


fn assert_fastq_records_equal(a: FastqRecord, b: FastqRecord, msg: String = "") raises:
    """Assert two FastqRecords are equal on all fields (not just SeqStr)."""
    assert_equal(
        a.SeqHeader.to_string(),
        b.SeqHeader.to_string(),
        "SeqHeader mismatch" + (" " + msg) if len(msg) else "",
    )
    assert_equal(
        a.SeqStr.to_string(),
        b.SeqStr.to_string(),
        "SeqStr mismatch" + (" " + msg) if len(msg) else "",
    )
    assert_equal(
        a.QuHeader.to_string(),
        b.QuHeader.to_string(),
        "QuHeader mismatch" + (" " + msg) if len(msg) else "",
    )
    assert_equal(
        a.QuStr.to_string(),
        b.QuStr.to_string(),
        "QuStr mismatch" + (" " + msg) if len(msg) else "",
    )
    assert_equal(
        a.quality_offset,
        b.quality_offset,
        "quality_offset mismatch" + (" " + msg) if len(msg) else "",
    )


# ---------------------------------------------------------------------------
# Helper: write records to a BufferedWriter
# ---------------------------------------------------------------------------


fn write_fastq_records[W: WriterBackend](
    mut writer: BufferedWriter[W], records: List[FastqRecord]
) raises:
    """Write FASTQ records to a BufferedWriter (4 lines per record)."""
    for i in range(len(records)):
        var s = records[i].__str__()
        var bytes = List(s.as_bytes())
        writer.write_bytes(bytes)
    writer.flush()


# ---------------------------------------------------------------------------
# Helper: parse all records from a plain file
# ---------------------------------------------------------------------------


fn parse_plain_fastq(path: String) raises -> List[FastqRecord]:
    """Parse a plain FASTQ file into a list of FastqRecords."""
    var records = List[FastqRecord]()
    var parser = FastqParser[FileReader](FileReader(Path(path)), SCHEMA)
    for record in parser.records():
        records.append(record^)
    return records^


# ---------------------------------------------------------------------------
# Helper: generate synthetic FASTQ and write to plain + gzip (large fixtures)
# ---------------------------------------------------------------------------


fn generate_synthetic_fastq_fixtures() raises:
    """Generate synthetic reads, write to plain and gzip files for large fixtures.
    Writes to SYNTHETIC_PLAIN_PATH and SYNTHETIC_GZ_PATH.
    """
    var buf = generate_synthetic_fastq_buffer(
        NUM_SYNTHETIC_READS,
        SYNTHETIC_MIN_LEN,
        SYNTHETIC_MAX_LEN,
        SYNTHETIC_MIN_PHRED,
        SYNTHETIC_MAX_PHRED,
        SCHEMA,
    )
    var plain_writer = buffered_writer_for_file(Path(SYNTHETIC_PLAIN_PATH))
    plain_writer.write_bytes(buf)
    plain_writer.flush()
    var gz_writer = buffered_writer_for_gzip(SYNTHETIC_GZ_PATH)
    gz_writer.write_bytes(buf)
    gz_writer.flush()


# ---------------------------------------------------------------------------
# Helper: parse all records from a gzipped file
# ---------------------------------------------------------------------------


fn parse_gzip_fastq(path: String) raises -> List[FastqRecord]:
    """Parse a gzipped FASTQ file into a list of FastqRecords."""
    var records = List[FastqRecord]()
    var parser = FastqParser[GZFile](GZFile(path, "rb"), SCHEMA)
    for record in parser.records():
        records.append(record^)
    return records^


# ---------------------------------------------------------------------------
# Plain round-trip: example.fastq → parse → write plain → read → parse → compare
# ---------------------------------------------------------------------------


fn test_plain_roundtrip() raises:
    var original = parse_plain_fastq(EXAMPLE_FASTQ)
    var out_path = Path("tests/test_data/fastq_integration_plain.fastq")
    var writer = buffered_writer_for_file(out_path)
    write_fastq_records(writer, original)

    var reread = parse_plain_fastq("tests/test_data/fastq_integration_plain.fastq")
    assert_equal(len(original), len(reread), "Record count mismatch")
    for i in range(len(original)):
        assert_fastq_records_equal(original[i], reread[i], "record " + String(i))
    print("✓ test_plain_roundtrip passed")


# ---------------------------------------------------------------------------
# Plain → gzip round-trip: example.fastq → parse → write gzip → read gzip → parse → compare
# ---------------------------------------------------------------------------


fn test_plain_to_gzip_roundtrip() raises:
    var original = parse_plain_fastq(EXAMPLE_FASTQ)
    var gz_path = "tests/test_data/fastq_integration_plain2gz.fastq.gz"
    var writer = buffered_writer_for_gzip(gz_path)
    write_fastq_records(writer, original)

    var reread = parse_gzip_fastq(gz_path)
    assert_equal(len(original), len(reread), "Record count mismatch")
    for i in range(len(original)):
        assert_fastq_records_equal(original[i], reread[i], "record " + String(i))
    print("✓ test_plain_to_gzip_roundtrip passed")


# ---------------------------------------------------------------------------
# Gzip round-trip: generate .fastq.gz from example.fastq → parse gzip → write plain → read → parse → compare
# ---------------------------------------------------------------------------


fn test_gzip_roundtrip() raises:
    var original = parse_plain_fastq(EXAMPLE_FASTQ)
    var gz_path = "tests/test_data/fastq_integration_roundtrip.fastq.gz"
    var gz_writer = buffered_writer_for_gzip(gz_path)
    write_fastq_records(gz_writer, original)

    var from_gz = parse_gzip_fastq(gz_path)
    var plain_path = "tests/test_data/fastq_integration_from_gz_plain.fastq"
    var plain_writer = buffered_writer_for_file(Path(plain_path))
    write_fastq_records(plain_writer, from_gz)

    var reread = parse_plain_fastq(plain_path)
    assert_equal(len(from_gz), len(reread), "Record count mismatch")
    for i in range(len(from_gz)):
        assert_fastq_records_equal(from_gz[i], reread[i], "record " + String(i))
    print("✓ test_gzip_roundtrip passed")


# ---------------------------------------------------------------------------
# Gzip → gzip round-trip: generated .fastq.gz → parse → write gzip → read gzip → parse → compare
# ---------------------------------------------------------------------------


fn test_gzip_to_gzip_roundtrip() raises:
    var original = parse_plain_fastq(EXAMPLE_FASTQ)
    var gz_in_path = "tests/test_data/fastq_integration_input.fastq.gz"
    var gz_in_writer = buffered_writer_for_gzip(gz_in_path)
    write_fastq_records(gz_in_writer, original)

    var from_gz = parse_gzip_fastq(gz_in_path)
    var gz_out_path = "tests/test_data/fastq_integration_gz2gz.fastq.gz"
    var gz_out_writer = buffered_writer_for_gzip(gz_out_path)
    write_fastq_records(gz_out_writer, from_gz)

    var reread = parse_gzip_fastq(gz_out_path)
    assert_equal(len(from_gz), len(reread), "Record count mismatch")
    for i in range(len(from_gz)):
        assert_fastq_records_equal(from_gz[i], reread[i], "record " + String(i))
    print("✓ test_gzip_to_gzip_roundtrip passed")


# ---------------------------------------------------------------------------
# Synthetic (large) fixtures: generate then round-trip on synthetic plain/gzip
# ---------------------------------------------------------------------------


fn test_synthetic_plain_roundtrip() raises:
    """Round-trip on large synthetic plain fixture."""
    var original = parse_plain_fastq(SYNTHETIC_PLAIN_PATH)
    var out_path = Path("tests/test_data/fastq_integration_synthetic_plain_out.fastq")
    var writer = buffered_writer_for_file(out_path)
    write_fastq_records(writer, original)
    var reread = parse_plain_fastq("tests/test_data/fastq_integration_synthetic_plain_out.fastq")
    assert_equal(len(original), len(reread), "Record count mismatch (synthetic plain)")
    for i in range(len(original)):
        assert_fastq_records_equal(original[i], reread[i], "synthetic plain record " + String(i))
    print("✓ test_synthetic_plain_roundtrip passed (" + String(len(original)) + " records)")


fn test_synthetic_plain_to_gzip_roundtrip() raises:
    """Round-trip: large synthetic plain → write gzip → read gzip → compare."""
    var original = parse_plain_fastq(SYNTHETIC_PLAIN_PATH)
    var gz_path = "tests/test_data/fastq_integration_synthetic_plain2gz_out.fastq.gz"
    var writer = buffered_writer_for_gzip(gz_path)
    write_fastq_records(writer, original)
    var reread = parse_gzip_fastq(gz_path)
    assert_equal(len(original), len(reread), "Record count mismatch (synthetic plain→gzip)")
    for i in range(len(original)):
        assert_fastq_records_equal(original[i], reread[i], "synthetic plain→gzip record " + String(i))
    print("✓ test_synthetic_plain_to_gzip_roundtrip passed (" + String(len(original)) + " records)")


fn test_synthetic_gzip_roundtrip() raises:
    """Round-trip: large synthetic gzip → write plain → read plain → compare."""
    var original = parse_gzip_fastq(SYNTHETIC_GZ_PATH)
    var plain_path = "tests/test_data/fastq_integration_synthetic_gz2plain_out.fastq"
    var writer = buffered_writer_for_file(Path(plain_path))
    write_fastq_records(writer, original)
    var reread = parse_plain_fastq(plain_path)
    assert_equal(len(original), len(reread), "Record count mismatch (synthetic gzip)")
    for i in range(len(original)):
        assert_fastq_records_equal(original[i], reread[i], "synthetic gzip record " + String(i))
    print("✓ test_synthetic_gzip_roundtrip passed (" + String(len(original)) + " records)")


fn test_synthetic_gzip_to_gzip_roundtrip() raises:
    """Round-trip: large synthetic gzip → write gzip → read gzip → compare."""
    var original = parse_gzip_fastq(SYNTHETIC_GZ_PATH)
    var gz_out_path = "tests/test_data/fastq_integration_synthetic_gz2gz_out.fastq.gz"
    var writer = buffered_writer_for_gzip(gz_out_path)
    write_fastq_records(writer, original)
    var reread = parse_gzip_fastq(gz_out_path)
    assert_equal(len(original), len(reread), "Record count mismatch (synthetic gzip→gzip)")
    for i in range(len(original)):
        assert_fastq_records_equal(original[i], reread[i], "synthetic gzip→gzip record " + String(i))
    print("✓ test_synthetic_gzip_to_gzip_roundtrip passed (" + String(len(original)) + " records)")


# ---------------------------------------------------------------------------
# Cleanup: remove files produced by tests
# ---------------------------------------------------------------------------


fn cleanup_fastq_integration_files() raises:
    """Remove all files written by integration tests (ignore missing files)."""
    var paths = List[String]()
    paths.append(SYNTHETIC_PLAIN_PATH)
    paths.append(SYNTHETIC_GZ_PATH)
    paths.append("tests/test_data/fastq_integration_plain.fastq")
    paths.append("tests/test_data/fastq_integration_plain2gz.fastq.gz")
    paths.append("tests/test_data/fastq_integration_roundtrip.fastq.gz")
    paths.append("tests/test_data/fastq_integration_from_gz_plain.fastq")
    paths.append("tests/test_data/fastq_integration_input.fastq.gz")
    paths.append("tests/test_data/fastq_integration_gz2gz.fastq.gz")
    paths.append("tests/test_data/fastq_integration_synthetic_plain_out.fastq")
    paths.append("tests/test_data/fastq_integration_synthetic_plain2gz_out.fastq.gz")
    paths.append("tests/test_data/fastq_integration_synthetic_gz2plain_out.fastq")
    paths.append("tests/test_data/fastq_integration_synthetic_gz2gz_out.fastq.gz")
    for s in paths:
        try:
            remove(Path(s))
        except:
            pass  # file may not exist if test failed or was skipped


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


fn main() raises:
    generate_synthetic_fastq_fixtures()  # create fixtures for synthetic round-trip tests
    TestSuite.discover_tests[__functions_in_module()]().run()
    cleanup_fastq_integration_files()
