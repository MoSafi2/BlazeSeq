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


fn test_device_fastq_batch_add_and_layout() raises:
    """FastqBatch stacks records and builds correct qual_ends."""
    var batch = FastqBatch()
    var r1 = FastqRecord("@a", "AC", "+", "!!")
    var r2 = FastqRecord("@b", "GT", "+", "!!")
    batch.add(r1)
    batch.add(r2)
    assert_equal(batch.num_records(), 2)
    assert_equal(batch.seq_len(), 4)
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
    var batch = FastqBatch()
    var r1 = FastqRecord("@a", "AC", "+", "!!")
    var r2 = FastqRecord("@b", "G", "+", "!")
    batch.add(r1)
    batch.add(r2)
    var ctx = DeviceContext()
    var on_device = upload_batch_to_device(batch, ctx)
    var out_buf = enqueue_quality_prefix_sum(on_device, ctx)
    var host_out = ctx.enqueue_create_host_buffer[DType.int32](
        on_device.seq_len
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
    for i in range(on_device.seq_len):
        assert_equal(host_out[i], expected[i])


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


fn test_fastq_batch_empty_from_records() raises:
    """FastqBatch from empty list has 0 records."""
    var records = List[FastqRecord]()
    var batch = FastqBatch(records)
    assert_equal(batch.num_records(), 0)
    var back = batch.to_records()
    assert_equal(len(back), 0)


fn test_subbatch_prefix_sum_multi_chunk() raises:
    """
    When a GPU is available: run prefix-sum in multiple subbatches using
    fill_subbatch_host_buffers and upload_subbatch_from_host_buffers,
    aggregate results, and assert they match the CPU reference.
    """

    @parameter
    if not has_accelerator():
        return

    var num_records: Int = 3000
    var subbatch_size: Int = 1280
    var seq_len: Int = 80
    var batch = FastqBatch()
    for i in range(num_records):
        var seq = String(capacity=seq_len)
        var qual = String(capacity=seq_len)
        for k in range(seq_len):
            seq += "A"
            qual += "!"
        var r = FastqRecord("@" + String(i), seq, "+", qual)
        batch.add(r)

    var total_qual = batch.seq_len()
    var num_subbatches = (num_records + subbatch_size - 1) // subbatch_size
    var max_subbatch_qual = subbatch_size * seq_len
    var max_subbatch_n = subbatch_size

    var ctx = DeviceContext()
    var host_qual_0 = ctx.enqueue_create_host_buffer[DType.uint8](
        max_subbatch_qual
    )
    var host_offs_0 = ctx.enqueue_create_host_buffer[DType.int32](
        max_subbatch_n + 1
    )
    var host_qual_1 = ctx.enqueue_create_host_buffer[DType.uint8](
        max_subbatch_qual
    )
    var host_offs_1 = ctx.enqueue_create_host_buffer[DType.int32](
        max_subbatch_n + 1
    )
    ctx.synchronize()

    var aggregated = ctx.enqueue_create_host_buffer[DType.int32](total_qual)
    ctx.synchronize()

    var dummy_out = ctx.enqueue_create_host_buffer[DType.int32](1)
    ctx.synchronize()
    var last_host_out = dummy_out
    var last_qual_start: Int = 0
    var last_len: Int = 0

    for i in range(num_subbatches):
        var start_rec = i * subbatch_size
        var end_rec = min((i + 1) * subbatch_size, num_records)
        var qual_start = 0 if start_rec == 0 else Int(
            batch._qual_ends[start_rec - 1]
        )
        var qual_end = Int(batch._qual_ends[end_rec - 1])
        var total_qual_slice = qual_end - qual_start
        var n_slice = end_rec - start_rec

        if i > 0:
            ctx.synchronize()
            for j in range(last_len):
                aggregated[last_qual_start + j] = last_host_out[j]

        var slot = i % 2
        var host_qual_slot = host_qual_0 if slot == 0 else host_qual_1
        var host_offs_slot = host_offs_0 if slot == 0 else host_offs_1

        fill_subbatch_host_buffers(
            batch, start_rec, end_rec, host_qual_slot, host_offs_slot
        )
        var on_device = upload_subbatch_from_host_buffers(
            host_qual_slot,
            host_offs_slot,
            n_slice,
            total_qual_slice,
            batch.quality_offset(),
            ctx,
        )
        var out_buf = enqueue_quality_prefix_sum(on_device, ctx)
        var host_out = ctx.enqueue_create_host_buffer[DType.int32](
            total_qual_slice
        )
        ctx.enqueue_copy(src_buf=out_buf, dst_buf=host_out)

        if i + 1 < num_subbatches:
            var next_start = (i + 1) * subbatch_size
            var next_end = min((i + 2) * subbatch_size, num_records)
            var next_slot = (i + 1) % 2
            var next_host_qual = host_qual_0 if next_slot == 0 else host_qual_1
            var next_host_offs = host_offs_0 if next_slot == 0 else host_offs_1
            fill_subbatch_host_buffers(
                batch, next_start, next_end, next_host_qual, next_host_offs
            )

        last_host_out = host_out
        last_qual_start = qual_start
        last_len = total_qual_slice

    ctx.synchronize()
    for j in range(last_len):
        aggregated[last_qual_start + j] = last_host_out[j]

    var offsets_list = List[Int32]()
    offsets_list.append(0)
    for i in range(batch.num_records()):
        offsets_list.append(batch._qual_ends[i])
    var expected = cpu_quality_prefix_sum(
        batch._quality_bytes, offsets_list, batch.quality_offset()
    )
    for i in range(total_qual):
        assert_equal(aggregated[i], expected[i])


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
