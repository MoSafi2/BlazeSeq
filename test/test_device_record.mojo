"""Tests for DeviceFastqRecord, DeviceFastqBatch, and quality prefix-sum kernel."""

from blazeseq import (
    FastqRecord,
    DeviceFastqBatch,
    DeviceFastqRecord,
    from_fastq_record,
    upload_batch_to_device,
    enqueue_quality_prefix_sum,
)
from blazeseq.quality_schema import generic_schema
from gpu.host import DeviceContext
from sys import has_accelerator
from testing import assert_equal, assert_true, TestSuite


fn cpu_quality_prefix_sum(
    quality_bytes: List[UInt8], offsets: List[Int32], quality_offset: UInt8
) -> List[Int32]:
    """
    Reference: for each record i, prefix sum of (byte - offset) over
    [offsets[i], offsets[i+1]); returns concatenated prefix sums.
    """
    var out = List[Int32]()
    var n = len(offsets) - 1
    for i in range(n):
        var start = offsets[i]
        var end = offsets[i + 1]
        var s: Int32 = 0
        for j in range(start, end):
            s += Int32(quality_bytes[j]) - Int32(quality_offset)
            out.append(s)
    return out^


fn test_device_fastq_record_from_fastq() raises:
    """DeviceFastqRecord can be built from FastqRecord with given offsets."""
    var record = FastqRecord("@id", "ACGT", "+", "!!!!")
    var dev_rec = from_fastq_record(record, qual_start=0, seq_start=0)
    assert_equal(dev_rec.qual_start, 0)
    assert_equal(dev_rec.qual_len, 4)
    assert_equal(dev_rec.seq_start, 0)
    assert_equal(dev_rec.seq_len, 4)

    dev_rec = from_fastq_record(record, qual_start=10, seq_start=20)
    assert_equal(dev_rec.qual_start, 10)
    assert_equal(dev_rec.qual_len, 4)
    assert_equal(dev_rec.seq_start, 20)
    assert_equal(dev_rec.seq_len, 4)


fn test_device_fastq_batch_add_and_layout() raises:
    """DeviceFastqBatch stacks records and builds correct qual_ends."""
    var batch = DeviceFastqBatch()
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


fn test_cpu_prefix_sum_reference() raises:
    """CPU reference prefix sum matches hand-computed values."""
    var quality_bytes = List[UInt8]()
    quality_bytes.append(33)
    quality_bytes.append(34)
    quality_bytes.append(35)
    var offsets = List[Int32]()
    offsets.append(0)
    offsets.append(2)
    offsets.append(3)
    var offset_u8: UInt8 = 33
    var result = cpu_quality_prefix_sum(quality_bytes, offsets, offset_u8)
    assert_equal(len(result), 3)
    assert_equal(result[0], 0)
    assert_equal(result[1], 1)
    assert_equal(result[2], 2)


fn test_device_batch_prefix_sum_on_gpu() raises:
    """
    When a GPU is available: upload batch, run kernel, copy back,
    assert prefix-sum output matches CPU reference.
    """
    @parameter
    if not has_accelerator():
        return
    var batch = DeviceFastqBatch()
    var r1 = FastqRecord("@a", "AC", "+", "!!")
    var r2 = FastqRecord("@b", "G", "+", "!")
    batch.add(r1)
    batch.add(r2)
    var ctx = DeviceContext()
    var on_device = upload_batch_to_device(batch, ctx)
    var out_buf = enqueue_quality_prefix_sum(on_device, ctx)
    var host_out = ctx.enqueue_create_host_buffer[DType.int32](
        on_device.total_quality_len
    )
    ctx.enqueue_copy(src_buf=out_buf, dst_buf=host_out)
    ctx.synchronize()
    var offsets_list = List[Int32]()
    offsets_list.append(0)
    for i in range(batch.num_records()):
        offsets_list.append(batch._qual_ends[i])
    var expected = cpu_quality_prefix_sum(
        batch._quality_bytes, offsets_list, batch.quality_offset()
    )
    for i in range(on_device.total_quality_len):
        assert_equal(host_out[i], expected[i])


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
