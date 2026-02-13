"""Tests for  FastqBatch, and quality prefix-sum kernel."""

from blazeseq import (
    FastqRecord,
    FastqBatch,
    upload_batch_to_device,
    fill_subbatch_host_buffers,
    upload_subbatch_from_host_buffers,
    enqueue_quality_prefix_sum,
)
from gpu.host import DeviceContext
from sys import has_accelerator
from testing import assert_equal, assert_true, TestSuite



fn test_device_fastq_batch_add_and_layout() raises:
    """FastqBatch stacks records and builds correct qual_ends."""
    var batch = FastqBatch()
    var r1 = FastqRecord("@a", "AC", "+", "!!")
    var r2 = FastqRecord("@b", "GT", "+", "!!")
    batch.add(r1)
    batch.add(r2)
    assert_equal(batch.num_records(), 2)
    assert_equal(batch.total_quality_len(), 4)
    assert_equal(batch._qual_ends[0], 2)
    assert_equal(batch._qual_ends[1], 4)
    assert_equal(len(batch._quality_bytes), 4)
    assert_equal(len(batch._sequence_bytes), 4)




fn test_fastq_batch_from_records_and_to_records() raises:
    """Round-trip: List[FastqRecord] -> FastqBatch -> to_records() equals original list.
    """
    var records = List[FastqRecord]()
    records.append(FastqRecord("@a", "ACGT", "+", "!!!!"))
    records.append(FastqRecord("@b", "TGCA", "+", "!!!!"))
    records.append(FastqRecord("@c", "N", "+", "!"))
    var batch = FastqBatch(records)
    assert_equal(batch.num_records(), 3)
    var back = batch.to_records()
    assert_equal(len(back), 3)
    for i in range(3):
        assert_equal(
            back[i].SeqHeader.as_string_slice(),
            records[i].SeqHeader.as_string_slice(),
        )
        assert_equal(
            back[i].SeqStr.as_string_slice(),
            records[i].SeqStr.as_string_slice(),
        )
        assert_equal(
            back[i].QuStr.as_string_slice(), records[i].QuStr.as_string_slice()
        )
        assert_equal(back[i].quality_offset, records[i].quality_offset)


fn test_fastq_batch_get_record_matches_to_records() raises:
    """Get_record(i) returns the same record as to_records()[i]."""
    var batch = FastqBatch()
    batch.add(FastqRecord("@x", "AA", "+", "!!"))
    batch.add(FastqRecord("@y", "TT", "+", "!!"))
    var as_list = batch.to_records()
    for i in range(batch.num_records()):
        var from_get = batch.get_record(i)
        assert_equal(
            from_get.SeqHeader.as_string_slice(),
            as_list[i].SeqHeader.as_string_slice(),
        )
        assert_equal(
            from_get.SeqStr.as_string_slice(),
            as_list[i].SeqStr.as_string_slice(),
        )
        assert_equal(
            from_get.QuStr.as_string_slice(), as_list[i].QuStr.as_string_slice()
        )
    _ = batch


fn test_fastq_batch_empty_from_records() raises:
    """FastqBatch from empty list has 0 records."""
    var records = List[FastqRecord]()
    var batch = FastqBatch(records)
    assert_equal(batch.num_records(), 0)
    var back = batch.to_records()
    assert_equal(len(back), 0)



fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
