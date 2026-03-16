"""Tests for FaiParser and FaiRecord based on samtools faidx specification."""

from blazeseq import FaiParser, FaiRecord, FileReader
from blazeseq.io import MemoryReader
from std.collections import List
from std.collections.string import String
from std.testing import assert_equal, assert_true, assert_raises, TestSuite


fn _bytes(s: String) -> List[Byte]:
    var out = List[Byte]()
    for b in s.as_bytes():
        out.append(b)
    return out^


fn test_fasta_fai_unix() raises:
    """Parse the example FASTA .fai with Unix line endings."""
    var data = "one\t66\t5\t30\t31\ntwo\t28\t98\t14\t15\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FaiParser[MemoryReader](reader^)

    var rec1 = parser.next_record()
    assert_equal(rec1.name(), "one")
    assert_equal(rec1.length(), 66)
    assert_equal(rec1.offset(), 5)
    assert_equal(rec1.line_bases(), 30)
    assert_equal(rec1.line_width(), 31)
    assert_true(not rec1.qual_offset(), "FASTA FAI should have no qual offset")

    var rec2 = parser.next_record()
    assert_equal(rec2.name(), "two")
    assert_equal(rec2.length(), 28)
    assert_equal(rec2.offset(), 98)
    assert_equal(rec2.line_bases(), 14)
    assert_equal(rec2.line_width(), 15)
    assert_true(not rec2.qual_offset(), "FASTA FAI should have no qual offset")


fn test_fasta_fai_windows() raises:
    """Parse the example FASTA .fai with Windows CRLF semantics."""
    var data = "one\t66\t6\t30\t32\ntwo\t28\t103\t14\t16\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FaiParser[MemoryReader](reader^)

    var rec1 = parser.next_record()
    assert_equal(rec1.name(), "one")
    assert_equal(rec1.length(), 66)
    assert_equal(rec1.offset(), 6)
    assert_equal(rec1.line_bases(), 30)
    assert_equal(rec1.line_width(), 32)

    var rec2 = parser.next_record()
    assert_equal(rec2.name(), "two")
    assert_equal(rec2.length(), 28)
    assert_equal(rec2.offset(), 103)
    assert_equal(rec2.line_bases(), 14)
    assert_equal(rec2.line_width(), 16)


fn test_fastq_fai_example() raises:
    """Parse the example FASTQ .fai with QUALOFFSET column."""
    var data = "fastq1\t66\t8\t30\t31\t79\nfastq2\t28\t156\t14\t15\t188\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FaiParser[MemoryReader](reader^)

    var rec1 = parser.next_record()
    assert_equal(rec1.name(), "fastq1")
    assert_equal(rec1.length(), 66)
    assert_equal(rec1.offset(), 8)
    assert_equal(rec1.line_bases(), 30)
    assert_equal(rec1.line_width(), 31)
    assert_true(rec1.qual_offset().value())
    assert_equal(rec1.qual_offset().value(), 79)

    var rec2 = parser.next_record()
    assert_equal(rec2.name(), "fastq2")
    assert_equal(rec2.length(), 28)
    assert_equal(rec2.offset(), 156)
    assert_equal(rec2.line_bases(), 14)
    assert_equal(rec2.line_width(), 15)
    assert_true(rec2.qual_offset().value())
    assert_equal(rec2.qual_offset().value(), 188)


fn test_collect_helper() raises:
    """collect() reads all rows into a list."""
    var data = "one\t10\t0\t10\t11\ntwo\t20\t100\t10\t11\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FaiParser[MemoryReader](reader^)
    var items = parser.collect()
    assert_equal(len(items), 2)
    assert_equal(items[0].name(), "one")
    assert_equal(items[1].name(), "two")


fn test_invalid_column_count() raises:
    """Rows with wrong number of columns raise an Error."""
    var data = "one\t10\t0\t10\n"  # only 4 columns
    var reader = MemoryReader(_bytes(data))
    var parser = FaiParser[MemoryReader](reader^)
    with assert_raises():
        _ = parser.next_record()


fn test_non_integer_field() raises:
    """Non-numeric numeric columns raise an Error."""
    var data = "one\tNaN\t0\t10\t11\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FaiParser[MemoryReader](reader^)
    with assert_raises():
        _ = parser.next_record()


fn test_iterator_over_records() raises:
    """for-in iteration over FaiParser yields all records."""
    var data = (
        "one\t10\t0\t10\t11\ntwo\t20\t100\t10\t11\nthree\t30\t200\t10\t11\n"
    )
    var reader = MemoryReader(_bytes(data))
    var parser = FaiParser[MemoryReader](reader^)
    var names = List[String]()
    for rec in parser:
        names.append(rec.name())
    assert_equal(len(names), 3)
    assert_equal(names[0], "one")
    assert_equal(names[1], "two")
    assert_equal(names[2], "three")


fn test_next_record_view_and_to_record() raises:
    """next_record_view() returns a view; view.to_record() equals next_record()."""
    # Use consistent column count (6) so DelimitedReader accepts both rows.
    var data = "seq1\t100\t0\t80\t81\t90\nseq2\t200\t500\t80\t81\t600\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FaiParser[MemoryReader](reader^)

    var view1 = parser.next_record_view()
    assert_equal(String(view1.name()), "seq1")
    assert_equal(view1.length(), 100)
    assert_equal(view1.offset(), 0)
    assert_equal(view1.line_bases(), 80)
    assert_equal(view1.line_width(), 81)
    assert_equal(view1.qual_offset().value(), 90)
    var rec1 = view1.to_record()
    assert_equal(rec1.name(), "seq1")
    assert_equal(rec1.length(), 100)

    var view2 = parser.next_record_view()
    assert_equal(String(view2.name()), "seq2")
    assert_equal(view2.length(), 200)
    assert_equal(view2.qual_offset().value(), 600)
    var rec2 = view2.to_record()
    assert_equal(rec2.name(), "seq2")
    assert_equal(rec2.qual_offset().value(), 600)


fn main() raises:
    var suite = TestSuite.discover_tests[__functions_in_module()]().run()
