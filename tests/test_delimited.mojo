"""Tests for DelimitedRecord and DelimitedReader."""

from std.testing import assert_equal, assert_true, assert_raises, TestSuite
from std.collections import List
from std.collections.string import String

from blazeseq.io import DelimitedRecord, DelimitedReader, MemoryReader, EOFError


fn _memory_reader_from_string(content: String) -> MemoryReader:
    """Helper to build a MemoryReader from string content."""
    return MemoryReader(content.as_bytes())


fn test_delimited_reader_basic_tsv_with_header() raises:
    """Basic TSV with header: header() and next_record() fields match input."""
    var content = "col1\tcol2\n1\t2\n3\t4\n"
    var reader = _memory_reader_from_string(content)
    var delimited = DelimitedReader[MemoryReader](reader^, has_header=True)

    var header_opt = delimited.header()
    assert_true(
        header_opt.value(), "Header should be present when has_header=True"
    )
    var header = header_opt.value().copy()
    assert_equal(len(header), 2, "Header should have 2 columns")
    assert_equal(header[0].to_string(), "col1", "First header column")
    assert_equal(header[1].to_string(), "col2", "Second header column")

    var row1 = delimited.next_record()
    assert_equal(row1.num_fields(), 2, "First row should have 2 fields")
    assert_equal(row1[0].to_string(), "1", "First row, first column")
    assert_equal(row1[1].to_string(), "2", "First row, second column")

    var row2 = delimited.next_record()
    assert_equal(row2.num_fields(), 2, "Second row should have 2 fields")
    assert_equal(row2[0].to_string(), "3", "Second row, first column")
    assert_equal(row2[1].to_string(), "4", "Second row, second column")

    with assert_raises(contains="EOF"):
        _ = delimited.next_record()


fn test_delimited_reader_skips_empty_lines() raises:
    """Empty lines are skipped; record_number and records iterator behave correctly.
    """
    var content = "a\tb\n\n1\t2\n\n3\t4\n"
    var reader = _memory_reader_from_string(content)
    var delimited = DelimitedReader[MemoryReader](reader^)

    var records = List[DelimitedRecord]()
    for record in delimited.records():
        records.append(record.copy())

    assert_equal(len(records), 3, "Three non-empty records expected")
    assert_equal(records[0][0].to_string(), "a", "First record first field")
    assert_equal(records[1][0].to_string(), "1", "Second record first field")
    assert_equal(records[2][0].to_string(), "3", "Third record first field")
    assert_equal(
        delimited.get_record_number(),
        3,
        "Record number tracks consumed records",
    )


fn test_delimited_reader_inconsistent_num_fields_raises() raises:
    """Rows with inconsistent number of fields raise Error via next_record()."""
    var content = "c1\tc2\n1\t2\n3\t4\t5\n"
    var reader = _memory_reader_from_string(content)
    var delimited = DelimitedReader[MemoryReader](reader^, has_header=True)

    var first = delimited.next_record()
    assert_equal(
        first.num_fields(), 2, "First data row has expected field count"
    )

    with assert_raises(contains="inconsistent number of fields"):
        _ = delimited.next_record()


fn test_delimited_reader_records_for_loop() raises:
    """For record in reader.records() yields DelimitedRecord instances."""
    var content = "x\ty\n10\t20\n30\t40\n"
    var reader = _memory_reader_from_string(content)
    var delimited = DelimitedReader[MemoryReader](reader^, has_header=True)

    var rows = List[DelimitedRecord]()
    for record in delimited.records():
        rows.append(record.copy())

    assert_equal(len(rows), 2, "Iterator should yield 2 data rows")
    assert_equal(rows[0][0].to_string(), "10", "First row content")
    assert_equal(rows[1][1].to_string(), "40", "Second row content")


fn test_delimited_record_get_and_len() raises:
    """DelimitedRecord.get() returns Optional[BString] and __len__ mirrors num_fields().
    """
    var content = "a\tb\tc\n"
    var reader = _memory_reader_from_string(content)
    var delimited = DelimitedReader[MemoryReader](reader^)

    var record = delimited.next_record()
    assert_equal(record.num_fields(), 3, "Three fields expected")
    assert_equal(len(record), 3, "__len__ should equal num_fields()")

    var f0 = record.get(0)
    var f2 = record.get(2)
    var f3 = record.get(3)
    assert_true(f0, "Index 0 should be present")
    assert_true(f2, "Index 2 should be present")
    assert_true(not f3, "Out-of-range index should be None")
    assert_equal(f0.value().to_string(), "a", "First field value")
    assert_equal(f2.value().to_string(), "c", "Last field value")


fn main() raises:
    """Run all DelimitedRecord / DelimitedReader tests."""
    print("Running delimited IO tests...\n")
    TestSuite.discover_tests[__functions_in_module()]().run()
    print("\n✓ Delimited tests passed!")
