"""Optional MAX-backed GPU transfer types for BlazeSeq FASTQ batches."""

from blazeseq.fastq.record import FastqRecord
from blazeseq.fastq.record_batch import FastqBatch
from max.gpu.host import DeviceContext, DeviceBuffer, HostBuffer
from std.memory import unsafe_memcpy


@fieldwise_init
struct DeviceFastqBatch(Deinitable, Movable):
    var num_records: Int
    var seq_len: Int64
    var quality_offset: UInt8
    var total_id_bytes: Int64
    var qual_buffer: DeviceBuffer[DType.uint8]
    var sequence_buffer: DeviceBuffer[DType.uint8]
    var ends: DeviceBuffer[DType.int64]
    var id_buffer: DeviceBuffer[DType.uint8]
    var id_ends: DeviceBuffer[DType.int64]

    def copy_to_host(self, ctx: DeviceContext) raises -> FastqBatch:
        var staged = download_device_batch_to_staged(self, ctx)
        var batch = FastqBatch(quality_offset=self.quality_offset, batch_size=0)
        batch._quality_bytes = List[UInt8](capacity=Int(staged.total_seq_bytes))
        batch._ends = List[Int64](capacity=staged.num_records)
        batch._quality_bytes.extend(staged.quality_data.as_span())
        batch._ends.extend(staged.ends.as_span())
        batch._sequence_bytes = List[UInt8](
            capacity=Int(staged.total_seq_bytes)
        )
        batch._sequence_bytes.extend(staged.sequence_data.as_span())
        batch._id_bytes = List[UInt8](capacity=Int(staged.total_id_bytes))
        batch._id_ends = List[Int64](capacity=staged.num_records)
        batch._id_bytes.extend(staged.id_data.as_span())
        batch._id_ends.extend(staged.id_ends.as_span())
        return batch^

    def to_records(self, ctx: DeviceContext) raises -> List[FastqRecord]:
        return self.copy_to_host(ctx).to_records()


@fieldwise_init
struct StagedFastqBatch:
    var num_records: Int
    var total_seq_bytes: Int64
    var total_id_bytes: Int64
    var quality_offset: UInt8
    var quality_data: HostBuffer[DType.uint8]
    var sequence_data: HostBuffer[DType.uint8]
    var id_data: HostBuffer[DType.uint8]
    var ends: HostBuffer[DType.int64]
    var id_ends: HostBuffer[DType.int64]


def download_device_batch_to_staged(
    device_batch: DeviceFastqBatch, ctx: DeviceContext
) raises -> StagedFastqBatch:
    var n = device_batch.num_records
    var total_seq = device_batch.seq_len
    var total_id = device_batch.total_id_bytes
    var quality_data = ctx.enqueue_create_host_buffer[DType.uint8](
        Int(total_seq)
    )
    var ends = ctx.enqueue_create_host_buffer[DType.int64](n)
    var sequence_data = ctx.enqueue_create_host_buffer[DType.uint8](
        Int(total_seq)
    )
    var id_data = ctx.enqueue_create_host_buffer[DType.uint8](Int(total_id))
    var id_ends = ctx.enqueue_create_host_buffer[DType.int64](n)
    ctx.enqueue_copy(src_buf=device_batch.qual_buffer, dst_buf=quality_data)
    ctx.enqueue_copy(src_buf=device_batch.ends, dst_buf=ends)
    ctx.enqueue_copy(
        src_buf=device_batch.sequence_buffer, dst_buf=sequence_data
    )
    ctx.enqueue_copy(src_buf=device_batch.id_buffer, dst_buf=id_data)
    ctx.enqueue_copy(src_buf=device_batch.id_ends, dst_buf=id_ends)
    ctx.synchronize()
    return StagedFastqBatch(
        num_records=n,
        total_seq_bytes=total_seq,
        total_id_bytes=total_id,
        quality_offset=device_batch.quality_offset,
        quality_data=quality_data,
        sequence_data=sequence_data,
        id_data=id_data,
        ends=ends,
        id_ends=id_ends,
    )


def stage_batch_to_host(
    batch: FastqBatch, ctx: DeviceContext
) raises -> StagedFastqBatch:
    var n = batch.num_records()
    var total_bytes = batch.seq_len()
    var total_id_bytes = len(batch._id_bytes)
    var quality_data = ctx.enqueue_create_host_buffer[DType.uint8](total_bytes)
    var sequence_data = ctx.enqueue_create_host_buffer[DType.uint8](total_bytes)
    var id_data = ctx.enqueue_create_host_buffer[DType.uint8](total_id_bytes)
    var ends = ctx.enqueue_create_host_buffer[DType.int64](n)
    var id_ends = ctx.enqueue_create_host_buffer[DType.int64](n)
    unsafe_memcpy(
        dest=quality_data.as_span().unsafe_ptr(),
        src=batch._quality_bytes.unsafe_ptr(),
        count=total_bytes,
    )
    unsafe_memcpy(
        dest=ends.as_span().unsafe_ptr(), src=batch._ends.unsafe_ptr(), count=n
    )
    unsafe_memcpy(
        dest=sequence_data.as_span().unsafe_ptr(),
        src=batch._sequence_bytes.unsafe_ptr(),
        count=total_bytes,
    )
    unsafe_memcpy(
        dest=id_data.as_span().unsafe_ptr(),
        src=batch._id_bytes.unsafe_ptr(),
        count=total_id_bytes,
    )
    unsafe_memcpy(
        dest=id_ends.as_span().unsafe_ptr(),
        src=batch._id_ends.unsafe_ptr(),
        count=n,
    )
    return StagedFastqBatch(
        num_records=n,
        total_seq_bytes=Int64(total_bytes),
        total_id_bytes=Int64(total_id_bytes),
        quality_offset=batch.quality_offset(),
        quality_data=quality_data,
        sequence_data=sequence_data,
        id_data=id_data,
        ends=ends,
        id_ends=id_ends,
    )


def move_staged_to_device(
    var staged: StagedFastqBatch, ctx: DeviceContext
) raises -> DeviceFastqBatch:
    var quality_buffer = ctx.enqueue_create_buffer[DType.uint8](
        Int(staged.total_seq_bytes)
    )
    var ends_buffer = ctx.enqueue_create_buffer[DType.int64](staged.num_records)
    var sequence_buffer = ctx.enqueue_create_buffer[DType.uint8](
        Int(staged.total_seq_bytes)
    )
    var id_buffer = ctx.enqueue_create_buffer[DType.uint8](
        Int(staged.total_id_bytes)
    )
    var id_ends_buffer = ctx.enqueue_create_buffer[DType.int64](
        staged.num_records
    )
    ctx.enqueue_copy(src_buf=staged.quality_data, dst_buf=quality_buffer)
    ctx.enqueue_copy(src_buf=staged.ends, dst_buf=ends_buffer)
    ctx.enqueue_copy(src_buf=staged.sequence_data, dst_buf=sequence_buffer)
    ctx.enqueue_copy(src_buf=staged.id_data, dst_buf=id_buffer)
    ctx.enqueue_copy(src_buf=staged.id_ends, dst_buf=id_ends_buffer)
    ctx.synchronize()
    return DeviceFastqBatch(
        num_records=staged.num_records,
        seq_len=staged.total_seq_bytes,
        quality_offset=staged.quality_offset,
        total_id_bytes=staged.total_id_bytes,
        qual_buffer=quality_buffer,
        sequence_buffer=sequence_buffer,
        ends=ends_buffer,
        id_buffer=id_buffer,
        id_ends=id_ends_buffer,
    )


def upload_batch_to_device(
    batch: FastqBatch, ctx: DeviceContext
) raises -> DeviceFastqBatch:
    return move_staged_to_device(stage_batch_to_host(batch, ctx), ctx)
