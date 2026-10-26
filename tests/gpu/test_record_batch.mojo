"""Hardware tests for the core MAX-backed batch transfer API."""

from blazeseq import (
    FastqBatch,
    FastqRecord,
    DeviceFastqBatch,
    StagedFastqBatch,
    stage_batch_to_host,
    upload_batch_to_device,
    move_staged_to_device,
    download_device_batch_to_staged,
)
from blazeseq.fastq.quality_schema import illumina_1_3_schema
from max.gpu.host import DeviceContext
from std.sys import has_accelerator
from std.testing import assert_equal, assert_raises, TestSuite


def make_batch(single: Bool = False) raises -> FastqBatch:
    var batch = FastqBatch(quality_offset=64)
    batch.add(
        FastqRecord(
            "first header", "ACGTN", "@ABCD", materialize[illumina_1_3_schema]()
        )
    )
    if not single:
        batch.add(
            FastqRecord("second", "T", "E", materialize[illumina_1_3_schema]())
        )
        batch.add(
            FastqRecord(
                "third long header",
                "GCA",
                "FGH",
                materialize[illumina_1_3_schema](),
            )
        )
    return batch^


def assert_batch_equal(actual: FastqBatch, expected: FastqBatch) raises:
    assert_equal(actual.num_records(), expected.num_records())
    assert_equal(actual.seq_len(), expected.seq_len())
    assert_equal(actual.quality_offset(), expected.quality_offset())
    for i in range(expected.num_records()):
        var a = actual.get_record(i)
        var e = expected.get_record(i)
        assert_equal(a.id(), e.id())
        assert_equal(a.sequence(), e.sequence())
        assert_equal(a.quality(), e.quality())
        assert_equal(a._phred_offset, e._phred_offset)
        assert_equal(actual._ends[i], expected._ends[i])
        assert_equal(actual._id_ends[i], expected._id_ends[i])


def test_staging_buffers_and_consuming_upload() raises:
    var ctx = DeviceContext()
    var batch = make_batch()
    var staged: StagedFastqBatch = batch.stage(ctx)
    assert_equal(staged.num_records, batch.num_records())
    assert_equal(staged.total_seq_bytes, Int64(batch.seq_len()))
    assert_equal(staged.total_id_bytes, Int64(len(batch._id_bytes)))
    assert_equal(staged.quality_offset, batch.quality_offset())
    for i in range(batch.seq_len()):
        assert_equal(staged.sequence_data[i], batch._sequence_bytes[i])
        assert_equal(staged.quality_data[i], batch._quality_bytes[i])
    for i in range(len(batch._id_bytes)):
        assert_equal(staged.id_data[i], batch._id_bytes[i])
    for i in range(batch.num_records()):
        assert_equal(staged.ends[i], batch._ends[i])
        assert_equal(staged.id_ends[i], batch._id_ends[i])
    var device: DeviceFastqBatch = staged^.to_device(ctx)
    var restored = device.copy_to_host(ctx)
    assert_batch_equal(restored, batch)


def test_device_round_trip_and_download_helpers() raises:
    var ctx = DeviceContext()
    var batch = make_batch()
    var device = batch.to_device(ctx)
    assert_equal(device.num_records, batch.num_records())
    assert_equal(device.seq_len, Int64(batch.seq_len()))
    assert_equal(device.total_id_bytes, Int64(len(batch._id_bytes)))
    assert_equal(device.quality_offset, batch.quality_offset())
    var downloaded = download_device_batch_to_staged(device, ctx)
    var uploaded = move_staged_to_device(downloaded^, ctx)
    var restored = uploaded.copy_to_host(ctx)
    assert_batch_equal(restored, batch)
    var records = uploaded.to_records(ctx)
    assert_equal(len(records), batch.num_records())
    assert_equal(records[2].sequence(), batch.get_record(2).sequence())


def test_single_record_upload_helper() raises:
    var ctx = DeviceContext()
    var batch = make_batch(single=True)
    var device = upload_batch_to_device(batch, ctx)
    var restored = device.copy_to_host(ctx)
    assert_batch_equal(restored, batch)


def test_empty_batch_transfers_raise() raises:
    var ctx = DeviceContext()
    var batch = FastqBatch()
    with assert_raises(contains="Cannot transfer an empty FastqBatch"):
        _ = batch.stage(ctx)
    with assert_raises(contains="Cannot transfer an empty FastqBatch"):
        _ = batch.to_device(ctx)
    with assert_raises(contains="Cannot transfer an empty FastqBatch"):
        _ = stage_batch_to_host(batch, ctx)
    with assert_raises(contains="Cannot transfer an empty FastqBatch"):
        _ = upload_batch_to_device(batch, ctx)


def main() raises:
    comptime assert has_accelerator(), "GPU tests require an accelerator"
    TestSuite.discover_tests[__functions_in_module()]().run()
