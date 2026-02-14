"""Tests for  FastqBatch, and quality prefix-sum kernel."""

from blazeseq import (
    FastqRecord,
    FastqBatch,
    upload_batch_to_device,
    enqueue_quality_prefix_sum,
)
from blazeseq.kernels.qc import enqueue_batch_average_quality
from blazeseq.device_record import (
    GPUPayload,
    DeviceFastqBatch,
    StagedFastqBatch,
    stage_batch_to_host,
    move_staged_to_device,
)
from gpu.host import DeviceContext
from sys import has_accelerator
from testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)


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
    var total_len = batch.seq_len()
    var host_out = ctx.enqueue_create_host_buffer[DType.int32](total_len)
    ctx.enqueue_copy(src_buf=out_buf, dst_buf=host_out)
    ctx.synchronize()
    var offsets_list = List[Int32]()
    offsets_list.append(0)
    for i in range(batch.num_records()):
        offsets_list.append(batch._qual_ends[i])
    var expected = cpu_quality_prefix_sum(
        batch._quality_bytes, offsets_list, batch.quality_offset()
    )
    for i in range(total_len):
        assert_equal(host_out[i], expected[i])


fn test_gpu_payload_equality_and_ordering() raises:
    """GPUPayload: equality, inequality, ordering, and all five constants."""
    # Constants exist and have expected values (use assert_true for Equatable type)
    assert_true(GPUPayload.QUALITY_ONLY == GPUPayload(0))
    assert_true(GPUPayload.SEQUENCE_ONLY == GPUPayload(1))
    assert_true(GPUPayload.HEADER_ONLY == GPUPayload(2))
    assert_true(GPUPayload.QUALITY_AND_SEQUENCE == GPUPayload(3))
    assert_true(GPUPayload.FULL == GPUPayload(4))
    # Inequality
    assert_true(GPUPayload.QUALITY_ONLY != GPUPayload.QUALITY_AND_SEQUENCE)
    assert_true(GPUPayload.FULL != GPUPayload.QUALITY_ONLY)
    # Ordering (__ge__)
    assert_true(GPUPayload.QUALITY_ONLY >= GPUPayload.QUALITY_ONLY)
    assert_true(GPUPayload.FULL >= GPUPayload.QUALITY_AND_SEQUENCE)
    assert_true(GPUPayload.QUALITY_AND_SEQUENCE >= GPUPayload.QUALITY_ONLY)
    assert_true(
        GPUPayload.QUALITY_AND_SEQUENCE >= GPUPayload.QUALITY_AND_SEQUENCE
    )
    assert_true(GPUPayload.FULL >= GPUPayload.FULL)


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


# TODO: Re-enable this test when you know what is going on.
fn test_fastq_batch_get_record_matches_to_records() raises:
    """Get_record(i) returns the same record as to_records()[i]; compare to original added records."""
    var records = List[FastqRecord]()
    records.append(FastqRecord("@x", "AA", "+", "!!"))
    records.append(FastqRecord("@y", "TT", "+", "!!"))
    # Sanity: input quality strings are as expected (33 = '!')
    assert_equal(records[0].QuStr.as_string_slice(), String("!!"))
    assert_equal(records[1].QuStr.as_string_slice(), String("!!"))
    var batch = FastqBatch()
    for i in range(len(records)):
        batch.add(records[i])
    # Batch should contain quality bytes 33, 33, 33, 33
    assert_equal(len(batch._quality_bytes), 4)
    assert_equal(batch._quality_bytes[0], 33)
    assert_equal(batch._quality_bytes[1], 33)
    assert_equal(batch._quality_bytes[2], 33)
    assert_equal(batch._quality_bytes[3], 33)
    var as_list = batch.to_records()
    for i in range(batch.num_records()):
        var from_get = batch.get_record(i)
        # Compare to original record we added (stable expected value)
        assert_equal(
            from_get.SeqHeader.as_string_slice(),
            records[i].SeqHeader.as_string_slice(),
        )
        assert_equal(
            from_get.SeqStr.as_string_slice(),
            records[i].SeqStr.as_string_slice(),
        )
        assert_equal(
            from_get.QuStr.as_string_slice(),
            records[i].QuStr.as_string_slice(),
        )
        # Also assert get_record(i) matches to_records()[i]
        assert_equal(
            from_get.SeqHeader.as_string_slice(),
            as_list[i].SeqHeader.as_string_slice(),
        )
        assert_equal(
            from_get.SeqStr.as_string_slice(),
            as_list[i].SeqStr.as_string_slice(),
        )
        assert_equal(
            from_get.QuStr.as_string_slice(),
            as_list[i].QuStr.as_string_slice(),
        )


fn test_fastq_batch_empty_from_records() raises:
    """FastqBatch from empty list has 0 records."""
    var records = List[FastqRecord]()
    var batch = FastqBatch(records)
    assert_equal(batch.num_records(), 0)
    var back = batch.to_records()
    assert_equal(len(back), 0)


fn test_stage_batch_to_host_quality_only() raises:
    """When GPU is available: stage_batch_to_host with QUALITY_ONLY has no sequence/header host buffers.
    """

    @parameter
    if not has_accelerator():
        return
    var batch = FastqBatch()
    batch.add(FastqRecord("@a", "AC", "+", "!!"))
    batch.add(FastqRecord("@b", "GT", "+", "!!"))
    var ctx = DeviceContext()
    var staged = stage_batch_to_host(batch, ctx, GPUPayload.QUALITY_ONLY)
    assert_equal(staged.num_records, 2)
    assert_equal(staged.total_seq_bytes, batch.seq_len())
    assert_true(staged.sequence_data_host is None)
    assert_true(staged.header_data_host is None)
    assert_true(staged.header_ends_host is None)


fn test_stage_batch_to_host_full_payload() raises:
    """When GPU is available: stage_batch_to_host with FULL has sequence and header host buffers.
    """

    @parameter
    if not has_accelerator():
        return
    var batch = FastqBatch()
    batch.add(FastqRecord("@h1", "ACGT", "+", "!!!!"))
    batch.add(FastqRecord("@h2", "TGCA", "+", "!!!!"))
    var ctx = DeviceContext()
    var staged = stage_batch_to_host(batch, ctx, GPUPayload.FULL)
    assert_equal(staged.num_records, 2)
    assert_equal(staged.total_seq_bytes, batch.seq_len())
    assert_true(staged.sequence_data_host is not None)
    assert_equal(len(staged.sequence_data_host.value()), batch.seq_len())
    assert_true(staged.header_data_host is not None)
    assert_true(staged.header_ends_host is not None)
    var total_header_bytes = Int(batch._header_ends[1])
    assert_equal(len(staged.header_data_host.value()), total_header_bytes)
    assert_equal(len(staged.header_ends_host.value()), 2)


fn test_move_staged_to_device() raises:
    """When GPU is available: move_staged_to_device produces DeviceFastqBatch with required buffers set.
    """

    @parameter
    if not has_accelerator():
        return
    var batch = FastqBatch()
    batch.add(FastqRecord("@a", "AC", "+", "!!"))
    batch.add(FastqRecord("@b", "GT", "+", "!!"))
    var ctx = DeviceContext()
    var staged = stage_batch_to_host(batch, ctx, GPUPayload.QUALITY_ONLY)
    var d = move_staged_to_device(staged, ctx, batch.quality_offset())
    assert_equal(d.num_records, staged.num_records)
    assert_equal(d.seq_len, staged.total_seq_bytes)
    assert_equal(d.quality_offset, batch.quality_offset())
    assert_true(d.qual_buffer is not None)
    assert_true(d.offsets_buffer is not None)
    assert_true(d.sequence_buffer is None)
    assert_true(d.header_buffer is None)
    assert_true(d.header_ends is None)


fn test_upload_batch_to_device_quality_only() raises:
    """When GPU is available: upload with QUALITY_ONLY has qual/offsets only."""

    @parameter
    if not has_accelerator():
        return
    var batch = FastqBatch()
    batch.add(FastqRecord("@x", "AA", "+", "!!"))
    batch.add(FastqRecord("@y", "TT", "+", "!!"))
    var ctx = DeviceContext()
    var d = upload_batch_to_device(batch, ctx, GPUPayload.QUALITY_ONLY)
    assert_equal(d.num_records, 2)
    assert_equal(d.seq_len, batch.seq_len())
    assert_true(d.qual_buffer is not None)
    assert_true(d.offsets_buffer is not None)
    assert_true(d.sequence_buffer is None)
    assert_true(d.header_buffer is None)
    assert_true(d.header_ends is None)


fn test_upload_batch_to_device_quality_and_sequence() raises:
    """When GPU is available: upload with QUALITY_AND_SEQUENCE has sequence_buffer set.
    """

    @parameter
    if not has_accelerator():
        return
    var batch = FastqBatch()
    batch.add(FastqRecord("@a", "ACGT", "+", "!!!!"))
    var ctx = DeviceContext()
    var d = upload_batch_to_device(batch, ctx, GPUPayload.QUALITY_AND_SEQUENCE)
    assert_equal(d.num_records, 1)
    assert_equal(d.seq_len, 4)
    assert_true(d.qual_buffer is not None)
    assert_true(d.offsets_buffer is not None)
    assert_true(d.sequence_buffer is not None)
    assert_equal(len(d.sequence_buffer.value()), 4)


fn test_upload_batch_to_device_full() raises:
    """When GPU is available: upload with FULL has header_buffer and header_ends set.
    """

    @parameter
    if not has_accelerator():
        return
    var batch = FastqBatch()
    batch.add(FastqRecord("@header1", "ACGT", "+", "!!!!"))
    batch.add(FastqRecord("@h2", "TGCA", "+", "!!!!"))
    var ctx = DeviceContext()
    var d = upload_batch_to_device(batch, ctx, GPUPayload.FULL)
    assert_equal(d.num_records, 2)
    assert_true(d.qual_buffer is not None)
    assert_true(d.sequence_buffer is not None)
    assert_true(d.header_buffer is not None)
    assert_true(d.header_ends is not None)
    var total_header_bytes = Int(batch._header_ends[1])
    assert_equal(len(d.header_buffer.value()), total_header_bytes)
    assert_equal(len(d.header_ends.value()), 2)


# TODO: Re-enable this test when you know what is wrong.
fn test_device_fastq_batch_shape_after_upload() raises:
    """When GPU is available: DeviceFastqBatch after upload matches batch shape; copy-back sanity check."""
    @parameter
    if not has_accelerator():
        return
    var batch = FastqBatch()
    batch.add(FastqRecord("@a", "AC", "+", "!!"))
    batch.add(FastqRecord("@b", "G", "+", "!"))
    var ctx = DeviceContext()
    var d = upload_batch_to_device(batch, ctx, GPUPayload.QUALITY_ONLY)
    assert_equal(d.num_records, batch.num_records())
    assert_equal(d.seq_len, batch.seq_len())
    var host_qual = ctx.enqueue_create_host_buffer[DType.uint8](d.seq_len)
    # Copy device -> host (same arg order as upload: src then dst; here src=device, dst=host)
    ctx.enqueue_copy(d.qual_buffer.value(), host_qual)
    ctx.synchronize()
    for i in range(batch.seq_len()):
        assert_equal(host_qual[i], batch._quality_bytes[i])


fn test_device_fastq_batch_copy_to_host_full_roundtrip() raises:
    """When GPU is available: FULL round-trip List[FastqRecord] -> FastqBatch -> upload -> copy_to_host -> to_records equals original.
    """

    @parameter
    if not has_accelerator():
        return
    var records = List[FastqRecord]()
    records.append(FastqRecord("@h1", "ACGT", "+", "!!!!"))
    records.append(FastqRecord("@h2", "TGCA", "+", "!!!!"))
    records.append(FastqRecord("@h3", "N", "+", "!"))
    var batch = FastqBatch(records)
    var ctx = DeviceContext()
    var d = upload_batch_to_device(batch, ctx, GPUPayload.FULL)
    var back_batch = d.copy_to_host(ctx)
    var back_list = back_batch.to_records()
    assert_equal(len(back_list), len(records))
    for i in range(len(records)):
        assert_equal(
            back_list[i].SeqHeader.as_string_slice(),
            records[i].SeqHeader.as_string_slice(),
        )
        assert_equal(
            back_list[i].SeqStr.as_string_slice(),
            records[i].SeqStr.as_string_slice(),
        )
        assert_equal(
            back_list[i].QuStr.as_string_slice(),
            records[i].QuStr.as_string_slice(),
        )
        assert_equal(back_list[i].quality_offset, records[i].quality_offset)


fn test_device_fastq_batch_to_records_quality_and_sequence_synthesized_headers() raises:
    """When GPU is available: QUALITY_AND_SEQUENCE round-trip yields correct sequence/quality and synthesized headers @0, @1, ...
    """

    @parameter
    if not has_accelerator():
        return
    var batch = FastqBatch()
    batch.add(FastqRecord("@ignored", "ACGT", "+", "!!!!"))
    batch.add(FastqRecord("@also_ignored", "TG", "+", "!!"))
    var ctx = DeviceContext()
    var d = upload_batch_to_device(batch, ctx, GPUPayload.QUALITY_AND_SEQUENCE)
    var back_list = d.to_records(ctx)
    print(back_list)
    assert_equal(len(back_list), 2)
    assert_equal(back_list[0].SeqHeader.as_string_slice(), String("@0"))
    assert_equal(back_list[1].SeqHeader.as_string_slice(), String("@1"))
    assert_equal(back_list[0].SeqStr.as_string_slice(), String("ACGT"))
    assert_equal(back_list[1].SeqStr.as_string_slice(), String("TG"))
    assert_equal(back_list[0].QuStr.as_string_slice(), String("!!!!"))
    assert_equal(back_list[1].QuStr.as_string_slice(), String("!!"))


fn test_device_fastq_batch_empty_roundtrip() raises:
    """When GPU is available: empty FastqBatch upload (FULL) -> copy_to_host -> to_records yields empty list.
    """

    @parameter
    if not has_accelerator():
        return
    var records = List[FastqRecord]()
    var batch = FastqBatch(records)
    assert_equal(batch.num_records(), 0)
    var ctx = DeviceContext()
    var d = upload_batch_to_device(batch, ctx, GPUPayload.FULL)
    var back_batch = d.copy_to_host(ctx)
    var back_list = back_batch.to_records()
    assert_equal(len(back_list), 0)


fn test_device_fastq_batch_roundtrip_quality_offset_zero() raises:
    """When GPU is available: round-trip with quality_offset 0 is accepted (no false rejection).
    Uses a 2-byte sequence to avoid single-byte buffer edge cases in staging/copy.
    """

    @parameter
    if not has_accelerator():
        return
    var records = List[FastqRecord]()
    records.append(FastqRecord("@r", "AB", "+", "!!", Int8(0)))
    var batch = FastqBatch(records)
    var ctx = DeviceContext()
    var d = upload_batch_to_device(batch, ctx, GPUPayload.FULL)
    var back_batch = d.copy_to_host(ctx)
    var back_list = back_batch.to_records()
    assert_equal(len(back_list), 1)
    assert_equal(back_list[0].quality_offset, 0)
    assert_equal(back_list[0].SeqStr.as_string_slice(), String("AB"))


fn test_device_fastq_batch_quality_and_sequence_roundtrip_matches_original() raises:
    """When GPU is available: QUALITY_AND_SEQUENCE round-trip preserves sequence and quality vs original records.
    """

    @parameter
    if not has_accelerator():
        return
    var records = List[FastqRecord]()
    records.append(FastqRecord("@h1", "ACGT", "+", "!!!!"))
    records.append(FastqRecord("@h2", "TG", "+", "!!"))
    var batch = FastqBatch(records)
    var ctx = DeviceContext()
    var d = upload_batch_to_device(batch, ctx, GPUPayload.QUALITY_AND_SEQUENCE)
    var back_list = d.to_records(ctx)
    assert_equal(len(back_list), len(records))
    for i in range(len(records)):
        assert_equal(
            back_list[i].SeqStr.as_string_slice(),
            records[i].SeqStr.as_string_slice(),
        )
        assert_equal(
            back_list[i].QuStr.as_string_slice(),
            records[i].QuStr.as_string_slice(),
        )
        assert_equal(back_list[i].quality_offset, records[i].quality_offset)


fn test_device_fastq_batch_copy_to_host_quality_only_raises() raises:
    """When GPU is available: copy_to_host on QUALITY_ONLY batch raises (sequence_buffer missing).
    """

    @parameter
    if not has_accelerator():
        return
    var batch = FastqBatch()
    batch.add(FastqRecord("@a", "AC", "+", "!!"))
    var ctx = DeviceContext()
    var d = upload_batch_to_device(batch, ctx, GPUPayload.QUALITY_ONLY)
    with assert_raises(contains="copy_to_host requires"):
        _ = d.copy_to_host(ctx)


fn cpu_batch_average_quality(quality_bytes: List[UInt8], quality_offset: UInt8) -> Float64:
    """Reference: batch average quality = sum(qual[i] - offset) / len(quality_bytes)."""
    if len(quality_bytes) == 0:
        return 0.0
    var total: Int64 = 0
    for i in range(len(quality_bytes)):
        total += Int64(quality_bytes[i]) - Int64(quality_offset)
    return Float64(total) / Float64(len(quality_bytes))


fn test_qc_batch_average_quality_on_gpu() raises:
    """
    When GPU is available: enqueue_batch_average_quality and retrieve()
    return the same average as CPU reference.
    """
    @parameter
    if not has_accelerator():
        return
    var batch = FastqBatch()
    # Quality "!!!!" -> 0,0,0,0 (offset 33); "#$%&" -> 2,3,4,5 -> avg 3.5
    batch.add(FastqRecord("@a", "ACGT", "+", "!!!!"))
    batch.add(FastqRecord("@b", "TGCA", "+", "#$%&"))
    var expected = cpu_batch_average_quality(
        batch._quality_bytes, batch.quality_offset()
    )
    var ctx = DeviceContext()
    var dev = upload_batch_to_device(batch, ctx, GPUPayload.QUALITY_ONLY)
    var result = enqueue_batch_average_quality(dev, ctx)
    var avg = result.retrieve(ctx)
    assert_equal(avg, expected)


fn test_qc_batch_average_quality_empty_batch() raises:
    """When GPU is available: empty batch (seq_len 0) returns 0.0 from retrieve()."""
    @parameter
    if not has_accelerator():
        return
    var batch = FastqBatch()
    var ctx = DeviceContext()
    var dev = upload_batch_to_device(batch, ctx, GPUPayload.QUALITY_ONLY)
    var result = enqueue_batch_average_quality(dev, ctx)
    var avg = result.retrieve(ctx)
    assert_equal(avg, 0.0)


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
