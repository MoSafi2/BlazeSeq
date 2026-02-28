# """Tests for  FastqBatch, and quality prefix-sum kernel."""

from blazeseq import (
    FastqRecord,
    FastqBatch,
    upload_batch_to_device,
)
from blazeseq.record_batch import (
    DeviceFastqBatch,
    StagedFastqBatch,
    stage_batch_to_host,
    move_staged_to_device,
)
from gpu.host import DeviceContext
from sys import has_accelerator, is_defined
from testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)


fn test_device_fastq_batch_add_and_layout() raises:
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


fn test_fastq_batch_write_to() raises:
    """FastqBatch.write_to writes each record in FASTQ format (4 lines per record)."""
    var records = List[FastqRecord]()
    records.append(FastqRecord("r1", "ACGT", "!!!!"))
    records.append(FastqRecord("r2", "TGCA", "####"))
    var batch = FastqBatch(records)
    var out = String()
    batch.write_to(out)
    var expected = String("@r1\nACGT\n+\n!!!!\n@r2\nTGCA\n+\n####\n")
    assert_equal(String(out), expected, "write_to output should match expected FASTQ text")


fn test_fastq_batch_from_records_and_to_records() raises:
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
            back[i].id.as_string_slice(),
            records[i].id.as_string_slice(),
        )
        assert_equal(
            back[i].sequence.as_string_slice(),
            records[i].sequence.as_string_slice(),
        )
        assert_equal(
            back[i].quality.as_string_slice(), records[i].quality.as_string_slice()
        )
        assert_equal(back[i].phred_offset, records[i].phred_offset)


fn test_fastq_batch_get_record_matches_to_records() raises:
    """Get_record(i) returns the same record as to_records()[i]; compare to original added records.
    """
    var records = List[FastqRecord]()
    records.append(FastqRecord("@x", "AA", "!!"))
    records.append(FastqRecord("@y", "TT", "!!"))
    # Sanity: input quality strings are as expected (33 = '!')
    assert_equal(records[0].quality.as_string_slice(), String("!!"))
    assert_equal(records[1].quality.as_string_slice(), String("!!"))
    var batch = FastqBatch()
    for i in range(len(records)):
        batch.add(records[i])
    # Batch should contain quality bytes 33, 33, 33, 33
    assert_equal(len(batch._quality_bytes), 4)
    assert_equal(batch._quality_bytes[0], ord("!"))
    assert_equal(batch._quality_bytes[1], ord("!"))
    assert_equal(batch._quality_bytes[2], ord("!"))
    assert_equal(batch._quality_bytes[3], ord("!"))
    var as_list = batch.to_records()
    for i in range(batch.num_records()):
        var from_get = batch.get_record(i)
        # Compare to original record we added (stable expected value)
        assert_equal(
            from_get.id.as_string_slice(),
            records[i].id.as_string_slice(),
        )
        assert_equal(
            from_get.sequence.as_string_slice(),
            records[i].sequence.as_string_slice(),
        )
        assert_equal(
            from_get.quality.as_string_slice(),
            records[i].quality.as_string_slice(),
        )
        # Also assert get_record(i) matches to_records()[i]
        assert_equal(
            from_get.id.as_string_slice(),
            as_list[i].id.as_string_slice(),
        )
        assert_equal(
            from_get.sequence.as_string_slice(),
            as_list[i].sequence.as_string_slice(),
        )
        assert_equal(
            from_get.quality.as_string_slice(),
            as_list[i].quality.as_string_slice(),
        )
        _ = from_get


fn test_fastq_batch_empty_from_records() raises:
    """FastqBatch from empty list has 0 records."""
    var records = List[FastqRecord]()
    with assert_raises(contains="FastqBatch cannot be empty"):
        var batch = FastqBatch(records)


# fn test_stage_batch_to_host_always_full() raises:
#     """When GPU is available: stage_batch_to_host always has quality, sequence, and header host buffers.
#     """

#     @parameter
#     if not has_accelerator() or is_defined["GITHUB_ACTIONS"]():
#         return

#     var batch = FastqBatch()
#     batch.add(FastqRecord("@a", "AC", "!!"))
#     batch.add(FastqRecord("@b", "GT", "!!"))
#     var ctx = DeviceContext()
#     var staged = stage_batch_to_host(batch, ctx)
#     assert_equal(staged.num_records, 2)
#     assert_equal(staged.total_seq_bytes, batch.seq_len())
#     assert_equal(len(staged.sequence_data), batch.seq_len())
#     var total_id_bytes = len(batch._id_bytes)
#     assert_equal(len(staged.id_data), total_id_bytes)
#     assert_equal(len(staged.id_ends), 2)


# fn test_stage_batch_to_host_full_content() raises:
#     """When GPU is available: stage_batch_to_host with multiple records has correct header/sequence lengths.
#     """

#     @parameter
#     if not has_accelerator() or is_defined["GITHUB_ACTIONS"]():
#         return
#     var batch = FastqBatch()
#     batch.add(FastqRecord("@h1", "ACGT", "!!!!"))
#     batch.add(FastqRecord("@h2", "TGCA", "!!!!"))
#     var ctx = DeviceContext()
#     var staged = stage_batch_to_host(batch, ctx)
#     assert_equal(staged.num_records, 2)
#     assert_equal(staged.total_seq_bytes, batch.seq_len())
#     assert_equal(len(staged.sequence_data), batch.seq_len())
#     var total_id_bytes = len(batch._id_bytes)
#     assert_equal(len(staged.id_data), total_id_bytes)
#     assert_equal(len(staged.id_ends), 2)


# fn test_move_staged_to_device() raises:
#     """When GPU is available: move_staged_to_device produces DeviceFastqBatch with all buffers set.
#     """

#     @parameter
#     if not has_accelerator() or is_defined["GITHUB_ACTIONS"]():
#         return
#     var batch = FastqBatch()
#     batch.add(FastqRecord("@a", "AC", "!!"))
#     batch.add(FastqRecord("@b", "GT", "!!"))
#     var ctx = DeviceContext()
#     var staged = stage_batch_to_host(batch, ctx)
#     var d = move_staged_to_device(staged, ctx, batch.quality_offset())
#     assert_equal(d.num_records, staged.num_records)
#     assert_equal(d.seq_len, staged.total_seq_bytes)
#     assert_equal(d.quality_offset, batch.quality_offset())
#     assert_equal(len(d.qual_buffer), Int(d.seq_len))
#     assert_equal(len(d.ends), d.num_records)
#     assert_equal(len(d.sequence_buffer), Int(d.seq_len))
#     assert_equal(d.total_id_bytes, Int(batch._id_ends[1]))
#     assert_equal(len(d.id_buffer), Int(d.total_id_bytes))
#     assert_equal(len(d.id_ends), d.num_records)


# fn test_upload_batch_to_device_always_full() raises:
#     """When GPU is available: upload always has qual, sequence, and header buffers.
#     """

#     @parameter
#     if not has_accelerator() or is_defined["GITHUB_ACTIONS"]():
#         return
#     var batch = FastqBatch()
#     batch.add(FastqRecord("@x", "AA", "!!"))
#     batch.add(FastqRecord("@y", "TT", "!!"))
#     var ctx = DeviceContext()
#     var d = upload_batch_to_device(batch, ctx)
#     assert_equal(d.num_records, 2)
#     assert_equal(d.seq_len, batch.seq_len())
#     assert_equal(len(d.qual_buffer), Int(d.seq_len))
#     assert_equal(len(d.ends), d.num_records)
#     assert_equal(len(d.sequence_buffer), Int(d.seq_len))
#     var total_id_bytes = len(batch._id_bytes)
#     assert_equal(d.total_id_bytes, total_id_bytes)
#     assert_equal(len(d.id_buffer), total_id_bytes)
#     assert_equal(len(d.id_ends), 2)


# fn test_upload_batch_to_device_single_record() raises:
#     """When GPU is available: upload single record has all buffers set."""

#     @parameter
#     if not has_accelerator() or is_defined["GITHUB_ACTIONS"]():
#         return
#     var batch = FastqBatch()
#     batch.add(FastqRecord("@a", "ACGT", "!!!!"))
#     var ctx = DeviceContext()
#     var d = upload_batch_to_device(batch, ctx)
#     assert_equal(d.num_records, 1)
#     assert_equal(d.seq_len, 4)
#     assert_equal(len(d.qual_buffer), 4)
#     assert_equal(len(d.ends), 1)
#     assert_equal(len(d.sequence_buffer), 4)


# fn test_device_fastq_batch_shape_after_upload() raises:
#     """When GPU is available: DeviceFastqBatch after upload matches batch shape; copy-back sanity check.
#     """

#     @parameter
#     if not has_accelerator() or is_defined["GITHUB_ACTIONS"]():
#         return
#     var batch = FastqBatch()
#     batch.add(FastqRecord("@a", "AC", "!!"))
#     batch.add(FastqRecord("@b", "GT", "!!"))
#     var ctx = DeviceContext()
#     var d = upload_batch_to_device(batch, ctx)
#     assert_equal(d.num_records, batch.num_records())
#     assert_equal(d.seq_len, batch.seq_len())
#     var host_qual = ctx.enqueue_create_host_buffer[DType.uint8](Int(d.seq_len))
#     ctx.enqueue_copy(d.qual_buffer, host_qual)
#     ctx.synchronize()
#     for i in range(batch.seq_len()):
#         assert_equal(host_qual[i], batch._quality_bytes[i])


# fn test_device_fastq_batch_copy_to_host_full_roundtrip() raises:
#     """When GPU is available: FULL round-trip List[FastqRecord] -> FastqBatch -> upload -> copy_to_host -> to_records equals original.
#     """

#     @parameter
#     if not has_accelerator() or is_defined["GITHUB_ACTIONS"]():
#         return
#     var records = List[FastqRecord]()
#     records.append(FastqRecord("@h1", "ACGT", "!!!!"))
#     records.append(FastqRecord("@h2", "TGCA", "!!!!"))
#     records.append(FastqRecord("@h3", "N", "!"))
#     var batch = FastqBatch(records)
#     var ctx = DeviceContext()
#     var d = upload_batch_to_device(batch, ctx)
#     var back_batch = d.copy_to_host(ctx)
#     var back_list = back_batch.to_records()
#     assert_equal(len(back_list), len(records))
#     for i in range(len(records)):
#         assert_equal(
#                 back_list[i].id.as_string_slice(),
#             records[i].id.as_string_slice(),
#         )
#         assert_equal(
#             back_list[i].sequence.as_string_slice(),
#             records[i].sequence.as_string_slice(),
#         )
#         assert_equal(
#             back_list[i].quality.as_string_slice(),
#             records[i].quality.as_string_slice(),
#         )
#         assert_equal(back_list[i].phred_offset, records[i].phred_offset)


# fn test_device_fastq_batch_empty_roundtrip() raises:
#     """When GPU is available: empty FastqBatch upload (FULL) -> copy_to_host -> to_records yields empty list.
#     """

#     @parameter
#     if not has_accelerator() or is_defined["GITHUB_ACTIONS"]():
#         return
#     var records = List[FastqRecord]()
#     with assert_raises(contains="FastqBatch cannot be empty"):
#         var batch = FastqBatch(records)


# fn test_device_fastq_batch_roundtrip_quality_offset_zero() raises:
#     """When GPU is available: round-trip with quality_offset 0 is accepted (no false rejection).
#     Uses a 2-byte sequence to avoid single-byte buffer edge cases in staging/copy.
#     """

#     @parameter
#     if not has_accelerator() or is_defined["GITHUB_ACTIONS"]():
#         return
#     var records = List[FastqRecord]()
#     records.append(FastqRecord("@r", "AB", "!!"))
#     var batch = FastqBatch(records)
#     var ctx = DeviceContext()
#     var d = upload_batch_to_device(batch, ctx)
#     var back_batch = d.copy_to_host(ctx)
#     var back_list = back_batch.to_records()
#     assert_equal(len(back_list), 1)
#     assert_equal(back_list[0].id.as_string_slice(), String("@r"))
#     assert_equal(back_list[0].sequence.as_string_slice(), String("AB"))
#     assert_equal(back_list[0].quality.as_string_slice(), String("!!"))
#     assert_equal(back_list[0].phred_offset, 33)
#     _ = back_list


# fn test_device_fastq_batch_quality_and_sequence_roundtrip_matches_original() raises:
#     """When GPU is available: QUALITY_AND_SEQUENCE round-trip preserves sequence and quality vs original records.
#     """

#     @parameter
#     if not has_accelerator() or is_defined["GITHUB_ACTIONS"]():
#         return
#     var records = List[FastqRecord]()
#     records.append(FastqRecord("@h1", "ACGT", "!!!!"))
#     records.append(FastqRecord("@h2", "TGCA", "!!!!"))
#     var batch = FastqBatch(records)
#     var ctx = DeviceContext()
#     var d = upload_batch_to_device(batch, ctx)
#     var back_list = d.to_records(ctx)
#     assert_equal(len(back_list), len(records))
#     for i in range(len(records)):
#         assert_equal(
#             back_list[i].sequence.as_string_slice(),
#             records[i].sequence.as_string_slice(),
#         )
#         assert_equal(
#             back_list[i].quality.as_string_slice(),
#             records[i].quality.as_string_slice(),
#         )
#         assert_equal(back_list[i].phred_offset, records[i].phred_offset)


# fn test_device_fastq_batch_copy_to_host_succeeds() raises:
#     """When GPU is available: copy_to_host after upload returns FastqBatch with same shape.
#     """

#     @parameter
#     if not has_accelerator() or is_defined["GITHUB_ACTIONS"]():
#         return
#     var batch = FastqBatch()
#     batch.add(FastqRecord("@a", "AC", "!!"))
#     var ctx = DeviceContext()
#     var d = upload_batch_to_device(batch, ctx)
#     var back = d.copy_to_host(ctx)
#     assert_equal(back.num_records(), batch.num_records())
#     assert_equal(back.seq_len(), batch.seq_len())


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
