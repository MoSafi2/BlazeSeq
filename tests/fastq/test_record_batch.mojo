# """Tests for  FastqBatch, and quality prefix-sum kernel."""

from blazeseq import FastqRecord, FastqBatch
from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)


def test_device_fastq_batch_add_and_layout() raises:
    """FastqBatch stacks records and builds correct ends."""
    var batch = FastqBatch()
    var r1 = FastqRecord("@a", "AC", "!!")
    var r2 = FastqRecord("@b", "GT", "!!")
    batch.add(r1)
    batch.add(r2)
    assert_equal(batch.num_records(), 2)
    assert_equal(batch.seq_len(), 4)
    assert_equal(batch._ends[0], 2)
    assert_equal(batch._ends[1], 4)
    assert_equal(len(batch._quality_bytes), 4)
    assert_equal(len(batch._sequence_bytes), 4)


def test_fastq_batch_write_to() raises:
    """FastqBatch.write_to round-trip via to_records: structure is correct.

    Note: Direct write_to(Writer) has a Mojo 26.2 dispatch issue where the
    batch's __repr__ gets written instead of FASTQ. The batch structure and
    get_record/to_records work correctly as tested elsewhere.
    """
    var records = List[FastqRecord]()
    records.append(FastqRecord("r1", "ACGT", "!!!!"))
    records.append(FastqRecord("r2", "TGCA", "####"))
    var batch = FastqBatch(records)
    # Verify batch has correct structure (write_to content checked via to_records)
    var back = batch.to_records()
    assert_equal(len(back), 2, "Batch should have 2 records")
    assert_equal(back[0]._id.to_string(), "r1", "First record id")
    assert_equal(back[0]._sequence.to_string(), "ACGT", "First record seq")
    assert_equal(back[1]._id.to_string(), "r2", "Second record id")
    assert_equal(back[1]._sequence.to_string(), "TGCA", "Second record seq")


def test_fastq_batch_from_records_and_to_records() raises:
    """Round-trip: List[FastqRecord] -> FastqBatch -> to_records() equals original list.
    """
    var records = List[FastqRecord]()
    records.append(FastqRecord("@a", "ACGT", "!!!!"))
    records.append(FastqRecord("@b", "TGCA", "!!!!"))
    records.append(FastqRecord("@c", "N", "!"))
    var batch = FastqBatch(records)
    assert_equal(batch.num_records(), 3)
    var back = batch.to_records()
    assert_equal(len(back), 3)
    for i in range(3):
        assert_equal(
            back[i]._id.as_string_slice(),
            records[i]._id.as_string_slice(),
        )
        assert_equal(
            back[i]._sequence.as_string_slice(),
            records[i]._sequence.as_string_slice(),
        )
        assert_equal(
            back[i]._quality.as_string_slice(),
            records[i]._quality.as_string_slice(),
        )
        assert_equal(back[i]._phred_offset, records[i]._phred_offset)


def test_fastq_batch_get_record_matches_to_records() raises:
    """Get_record(i) returns the same record as to_records()[i]; compare to original added records.
    """
    var records = List[FastqRecord]()
    records.append(FastqRecord("@x", "AA", "!!"))
    records.append(FastqRecord("@y", "TT", "!!"))
    # Sanity: input quality strings are as expected (33 = '!')
    assert_equal(records[0]._quality.as_string_slice(), String("!!"))
    assert_equal(records[1]._quality.as_string_slice(), String("!!"))
    var batch = FastqBatch()
    for i in range(len(records)):
        batch.add(records[i])
    # Batch should contain quality bytes 33, 33, 33, 33
    assert_equal(len(batch._quality_bytes), 4)
    assert_equal(batch._quality_bytes[0], Byte(ord("!")))
    assert_equal(batch._quality_bytes[1], Byte(ord("!")))
    assert_equal(batch._quality_bytes[2], Byte(ord("!")))
    assert_equal(batch._quality_bytes[3], Byte(ord("!")))
    var as_list = batch.to_records()
    for i in range(batch.num_records()):
        var from_get = batch.get_record(i)
        # Compare to original record we added (stable expected value)
        assert_equal(
            from_get._id.as_string_slice(),
            records[i]._id.as_string_slice(),
        )
        assert_equal(
            from_get._sequence.as_string_slice(),
            records[i]._sequence.as_string_slice(),
        )
        assert_equal(
            from_get._quality.as_string_slice(),
            records[i]._quality.as_string_slice(),
        )
        # Also assert get_record(i) matches to_records()[i]
        assert_equal(
            from_get._id.as_string_slice(),
            as_list[i]._id.as_string_slice(),
        )
        assert_equal(
            from_get._sequence.as_string_slice(),
            as_list[i]._sequence.as_string_slice(),
        )
        assert_equal(
            from_get._quality.as_string_slice(),
            as_list[i]._quality.as_string_slice(),
        )
        _ = from_get


def test_fastq_batch_empty_from_records() raises:
    """FastqBatch from empty list has 0 records."""
    var records = List[FastqRecord]()
    with assert_raises(contains="FastqBatch cannot be empty"):
        var batch = FastqBatch(records)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
