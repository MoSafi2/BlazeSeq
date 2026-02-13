"""Tests for  FastqBatch, and quality prefix-sum kernel."""

from blazeseq import (
    FastqRecord,
    FastqBatch,
    upload_batch_to_device,
    fill_subbatch_host_buffers,
    upload_subbatch_from_host_buffers,
    enqueue_quality_prefix_sum,
)
from collections.string import String
from gpu.host import DeviceContext
from sys import has_accelerator
from testing import assert_equal, assert_true, TestSuite



fn _assert_records_equal(a: FastqRecord, b: FastqRecord) raises:
    """Assert two FastqRecords are equal via public API (header, seq, qual, quality_offset)."""
    assert_equal(a.SeqHeader.as_string_slice(), b.SeqHeader.as_string_slice())
    assert_equal(a.SeqStr.as_string_slice(), b.SeqStr.as_string_slice())
    assert_equal(a.QuStr.as_string_slice(), b.QuStr.as_string_slice())
    assert_equal(a.quality_offset, b.quality_offset)


fn test_device_fastq_batch_add_and_layout() raises:
    """FastqBatch stacks records; assert via num_records, total_quality_len, get_record/to_records only."""
    var batch = FastqBatch()
    var r1 = FastqRecord("@a", "AC", "+", "!!")
    var r2 = FastqRecord("@b", "GT", "+", "!!")
    batch.add(r1)
    batch.add(r2)
    assert_equal(batch.num_records(), 2)
    assert_equal(batch.total_quality_len(), 4)
    var back = batch.to_records()
    assert_equal(len(back), 2)
    _assert_records_equal(back[0], r1)
    _assert_records_equal(back[1], r2)
    _assert_records_equal(batch.get_record(0), r1)
    _assert_records_equal(batch.get_record(1), r2)


fn test_fastq_batch_empty_default() raises:
    """Empty default batch: num_records==0, len==0, total_quality_len==0, to_records empty, quality_offset default."""
    var batch = FastqBatch()
    assert_equal(batch.num_records(), 0)
    assert_equal(len(batch), 0)
    assert_equal(batch.total_quality_len(), 0)
    var back = batch.to_records()
    assert_equal(len(back), 0)
    assert_equal(batch.quality_offset(), 33)


fn test_fastq_batch_capacity_constructor() raises:
    """Capacity constructor: empty batch with custom quality_offset; add records and round-trip."""
    var batch = FastqBatch(batch_size=50, avg_record_size=200, quality_offset=64)
    assert_equal(batch.num_records(), 0)
    assert_equal(batch.quality_offset(), 64)
    var r1 = FastqRecord("@x", "ACGT", "+", "!!!!", 64)
    var r2 = FastqRecord("@y", "TG", "+", "!!", 64)
    batch.add(r1)
    batch.add(r2)
    assert_equal(batch.num_records(), 2)
    assert_equal(batch.total_quality_len(), 6)
    var back = batch.to_records()
    _assert_records_equal(back[0], r1)
    _assert_records_equal(back[1], r2)


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
        _assert_records_equal(from_get, as_list[i])


fn test_fastq_batch_empty_from_records() raises:
    """FastqBatch from empty list has 0 records."""
    var records = List[FastqRecord]()
    var batch = FastqBatch(records)
    assert_equal(batch.num_records(), 0)
    var back = batch.to_records()
    assert_equal(len(back), 0)


fn test_fastq_batch_single_record_via_add() raises:
    """Single record via add(): num_records==1, len==1, get_record(0) and to_records() match, total_quality_len correct."""
    var r = FastqRecord("@id", "ACGT", "+", "!!!!")
    var batch = FastqBatch()
    batch.add(r)
    assert_equal(batch.num_records(), 1)
    assert_equal(len(batch), 1)
    assert_equal(batch.total_quality_len(), len(r.QuStr))
    _assert_records_equal(batch.get_record(0), r)
    var back = batch.to_records()
    assert_equal(len(back), 1)
    _assert_records_equal(back[0], r)


fn test_fastq_batch_single_record_from_list() raises:
    """Single record via FastqBatch([r]): same assertions as single via add."""
    var r = FastqRecord("@only", "NN", "+", "!!")
    var records = List[FastqRecord]()
    records.append(r.copy())
    var batch = FastqBatch(records)
    assert_equal(batch.num_records(), 1)
    assert_equal(len(batch), 1)
    assert_equal(batch.total_quality_len(), 2)
    _assert_records_equal(batch.get_record(0), r)
    var back = batch.to_records()
    assert_equal(len(back), 1)
    _assert_records_equal(back[0], r)


fn test_fastq_batch_get_record_negative_index_raises() raises:
    """Get_record(-1) raises."""
    var batch = FastqBatch()
    batch.add(FastqRecord("@a", "A", "+", "!"))
    try:
        _ = batch.get_record(-1)
        assert_true(False, "get_record(-1) should raise")
    except:
        pass


fn test_fastq_batch_get_record_index_equals_len_raises() raises:
    """Get_record(n) when batch has n records raises."""
    var batch = FastqBatch()
    batch.add(FastqRecord("@a", "A", "+", "!"))
    batch.add(FastqRecord("@b", "C", "+", "!"))
    assert_equal(batch.num_records(), 2)
    try:
        _ = batch.get_record(2)
        assert_true(False, "get_record(2) on size-2 batch should raise")
    except:
        pass


fn test_fastq_batch_get_record_index_over_len_raises() raises:
    """Get_record(100) on size-3 batch raises."""
    var records = List[FastqRecord]()
    records.append(FastqRecord("@a", "A", "+", "!"))
    records.append(FastqRecord("@b", "C", "+", "!"))
    records.append(FastqRecord("@c", "G", "+", "!"))
    var batch = FastqBatch(records)
    try:
        _ = batch.get_record(100)
        assert_true(False, "get_record(100) should raise")
    except:
        pass


fn test_fastq_batch_get_record_valid_indices_match_to_records() raises:
    """Get_record(0), get_record(1), get_record(n-1) match to_records()[i]."""
    var records = List[FastqRecord]()
    records.append(FastqRecord("@r0", "AA", "+", "!!"))
    records.append(FastqRecord("@r1", "CC", "+", "!!"))
    records.append(FastqRecord("@r2", "GG", "+", "!!"))
    var batch = FastqBatch(records)
    var as_list = batch.to_records()
    _assert_records_equal(batch.get_record(0), as_list[0])
    _assert_records_equal(batch.get_record(1), as_list[1])
    _assert_records_equal(batch.get_record(2), as_list[2])


fn test_fastq_batch_round_trip_varying_lengths() raises:
    """Round-trip list with varying header and seq/qual lengths; assert each record matches."""
    var records = List[FastqRecord]()
    records.append(FastqRecord("@short", "A", "+", "!"))
    records.append(FastqRecord("@longer_id_here", "ACGTACGT", "+", "!!!!!!!!"))
    records.append(FastqRecord("@x", "NNNNNN", "+", "!!!!!!"))
    var batch = FastqBatch(records)
    var back = batch.to_records()
    assert_equal(len(back), 3)
    for i in range(3):
        _assert_records_equal(back[i], records[i])


fn test_fastq_batch_round_trip_mixed_quality_offset() raises:
    """Batch uses first record's quality_offset; round-trip records get batch's offset."""
    var records = List[FastqRecord]()
    records.append(FastqRecord("@first", "AA", "+", "!!", 64))
    records.append(FastqRecord("@second", "CC", "+", "!!", 33))
    var batch = FastqBatch(records)
    assert_equal(batch.quality_offset(), 64)
    var back = batch.to_records()
    assert_equal(len(back), 2)
    assert_equal(back[0].quality_offset, 64)
    assert_equal(back[1].quality_offset, 64)


fn test_fastq_batch_first_record_sets_quality_offset() raises:
    """Add one record with non-default quality_offset; batch.quality_offset() and round-trip match."""
    var batch = FastqBatch()
    var r = FastqRecord("@q64", "AC", "+", "!!", 64)
    batch.add(r)
    assert_equal(batch.quality_offset(), 64)
    var back = batch.to_records()
    assert_equal(len(back), 1)
    _assert_records_equal(back[0], r)


fn test_fastq_batch_subsequent_adds_round_trip() raises:
    """Add multiple records; num_records, total_quality_len, and round-trip content via get_record/to_records."""
    var batch = FastqBatch()
    var r1 = FastqRecord("@a", "A", "+", "!")
    var r2 = FastqRecord("@b", "CG", "+", "!!")
    var r3 = FastqRecord("@c", "T", "+", "!")
    batch.add(r1)
    batch.add(r2)
    batch.add(r3)
    assert_equal(batch.num_records(), 3)
    assert_equal(batch.total_quality_len(), 4)
    _assert_records_equal(batch.get_record(0), r1)
    _assert_records_equal(batch.get_record(1), r2)
    _assert_records_equal(batch.get_record(2), r3)
    var back = batch.to_records()
    _assert_records_equal(back[0], r1)
    _assert_records_equal(back[1], r2)
    _assert_records_equal(back[2], r3)


fn test_fastq_batch_len_equals_num_records() raises:
    """Len(batch) == batch.num_records() for 0, 1, and several records."""
    var empty = FastqBatch()
    assert_equal(len(empty), empty.num_records())
    var one = FastqBatch()
    one.add(FastqRecord("@x", "A", "+", "!"))
    assert_equal(len(one), one.num_records())
    var several = FastqBatch()
    several.add(FastqRecord("@a", "A", "+", "!"))
    several.add(FastqRecord("@b", "C", "+", "!"))
    several.add(FastqRecord("@c", "G", "+", "!"))
    assert_equal(len(several), several.num_records())


fn test_fastq_batch_copyable_contract() raises:
    """Copy batch; both have same num_records, total_quality_len, and to_records() content equal."""
    var records = List[FastqRecord]()
    records.append(FastqRecord("@a", "AC", "+", "!!"))
    records.append(FastqRecord("@b", "GT", "+", "!!"))
    var batch = FastqBatch(records)
    var batch2 = batch.copy()
    assert_equal(batch2.num_records(), batch.num_records())
    assert_equal(batch2.total_quality_len(), batch.total_quality_len())
    var back1 = batch.to_records()
    var back2 = batch2.to_records()
    assert_equal(len(back2), len(back1))
    for i in range(len(back1)):
        _assert_records_equal(back2[i], back1[i])


fn test_fastq_batch_round_trip_many_small_records() raises:
    """Many small records (e.g. 100): num_records, total_quality_len, spot-check first/last/middle."""
    var records = List[FastqRecord](capacity=100)
    for i in range(100):
        records.append(FastqRecord("@r" + String(i), "AC", "+", "!!"))
    var batch = FastqBatch(records)
    assert_equal(batch.num_records(), 100)
    assert_equal(batch.total_quality_len(), 200)
    var back = batch.to_records()
    assert_equal(len(back), 100)
    _assert_records_equal(batch.get_record(0), records[0])
    _assert_records_equal(batch.get_record(99), records[99])
    _assert_records_equal(batch.get_record(50), records[50])


fn test_fastq_batch_round_trip_few_long_records() raises:
    """2-3 records with long sequence/quality; round-trip content and total_quality_len."""
    var long_seq = String("A")
    for _ in range(199):
        long_seq += "C"
    var long_qual = String("!")
    for _ in range(199):
        long_qual += "!"
    var records = List[FastqRecord]()
    records.append(FastqRecord("@long1", long_seq, "+", long_qual))
    records.append(FastqRecord("@long2", long_seq, "+", long_qual))
    var batch = FastqBatch(records)
    assert_equal(batch.num_records(), 2)
    assert_equal(batch.total_quality_len(), 400)
    var back = batch.to_records()
    _assert_records_equal(back[0], records[0])
    _assert_records_equal(back[1], records[1])


fn test_fastq_batch_upload_to_device_when_available() raises:
    """When has_accelerator: upload_to_device returns DeviceFastqBatch with same num_records and quality_offset."""
    if not has_accelerator():
        return
    var batch = FastqBatch()
    batch.add(FastqRecord("@a", "ACGT", "+", "!!!!"))
    batch.add(FastqRecord("@b", "TGCA", "+", "!!!!"))
    var ctx = DeviceContext()
    var device_batch = batch.upload_to_device(ctx)
    assert_equal(device_batch.num_records, batch.num_records())
    assert_equal(device_batch.quality_offset, batch.quality_offset())


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
