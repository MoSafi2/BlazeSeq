"""Tests for the zero-copy memory-mapped FASTQ parser.

Cross-checks MmapFastqParser against the buffered FastqParser on identical
data (record counts, base pairs, record contents) and covers edge cases:
empty files and a final quality line without trailing newline.
"""

from std.pathlib import Path
from std.os import remove
from std.os.path import exists
from std.testing import assert_equal, assert_true, TestSuite
from blazeseq.fastq.parser import FastqParser
from blazeseq.fastq.parser import MmapFastqParser
from blazeseq.io.readers import FileReader
from blazeseq.io.buffered import buffered_writer_for_file
from blazeseq.fastq.synthetic import generate_synthetic_fastq_to_writer

comptime TMP_FASTQ = "tests/test_data/mmap_parser_tmp.fastq"
comptime NUM_READS = 500


def _write_synthetic_fastq() raises:
    if exists(TMP_FASTQ):
        remove(TMP_FASTQ)
    var writer = buffered_writer_for_file(TMP_FASTQ)
    generate_synthetic_fastq_to_writer(
        writer, NUM_READS, 60, 120, 33, 40, "generic"
    )
    writer.flush()


def test_mmap_matches_buffered() raises:
    _write_synthetic_fastq()

    var buffered = FastqParser[FileReader](
        FileReader(Path(TMP_FASTQ))
    )
    var buffered_reads = 0
    var buffered_bp = 0
    for view in buffered.views():
        buffered_reads += 1
        buffered_bp += len(view)

    var mmap_parser = MmapFastqParser(Path(TMP_FASTQ))
    var mmap_reads = 0
    var mmap_bp = 0
    for view in mmap_parser.views():
        mmap_reads += 1
        mmap_bp += len(view)

    assert_equal(mmap_reads, NUM_READS)
    assert_equal(mmap_reads, buffered_reads)
    assert_equal(mmap_bp, buffered_bp)


def test_mmap_record_contents_match() raises:
    _write_synthetic_fastq()
    var buffered = FastqParser[FileReader](FileReader(Path(TMP_FASTQ)))
    var mmap_parser = MmapFastqParser(Path(TMP_FASTQ))

    var checked = 0
    for bv in buffered.views():
        var mv = mmap_parser.next_view()
        assert_equal(bv.id(), mv.id())
        assert_equal(bv.sequence(), mv.sequence())
        assert_equal(bv.quality(), mv.quality())
        checked += 1
    assert_equal(checked, NUM_READS)


def test_mmap_next_record_matches_view_length() raises:
    var mmap_parser = MmapFastqParser(Path(TMP_FASTQ))
    var total = 0
    while mmap_parser.has_more():
        var rec = mmap_parser.next_record()
        assert_equal(rec.sequence().byte_length(), rec.quality().byte_length())
        total += 1
    assert_equal(total, NUM_READS)


def test_mmap_empty_file() raises:
    if exists(TMP_FASTQ + ".empty"):
        remove(TMP_FASTQ + ".empty")
    var writer = buffered_writer_for_file(TMP_FASTQ + ".empty")
    writer.flush()
    var parser = MmapFastqParser(Path(TMP_FASTQ + ".empty"))
    assert_equal(parser.has_more(), False)
    var count = 0
    for _view in parser.views():
        count += 1
    assert_equal(count, 0)


def test_mmap_missing_trailing_newline() raises:
    comptime path = TMP_FASTQ + ".notrailingnl"
    if exists(path):
        remove(path)
    var writer = buffered_writer_for_file(path)
    var raw = "@r1\nACGTACGT\n+\nIIIIIIII"
    writer.write_bytes(raw.as_bytes())
    writer.flush()
    var parser = MmapFastqParser(Path(path))
    var rec = parser.next_record()
    assert_equal(StringSlice(rec.id()), StringSlice("r1"))
    assert_equal(StringSlice(rec.sequence()), StringSlice("ACGTACGT"))
    assert_equal(StringSlice(rec.quality()), StringSlice("IIIIIIII"))
    assert_equal(parser.has_more(), False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
