"""Device-compatible Fastq record descriptor and batch for GPU kernels."""

from blazeseq.record import FastqRecord
from blazeseq.quality_schema import QualitySchema
from gpu.host import DeviceContext
from gpu.host.device_context import DeviceBuffer
from gpu import block_idx, thread_idx
from memory import UnsafePointer



# ---------------------------------------------------------------------------
# FastqBatch: host-side builder, stacks records and uploads to device
# ---------------------------------------------------------------------------


struct FastqBatch:
    """
    Host-side container that stacks multiple FastqRecords into packed quality
    (and sequence) byte buffers and an offsets index, then uploads to device.
    """
    var _header_bytes: List[UInt8]
    var _header_ends: List[Int32]
    var _quality_bytes: List[UInt8]
    var _sequence_bytes: List[UInt8]
    var _qual_ends: List[Int32]
    var _quality_offset: UInt8

    fn __init__(out self):
        self._header_bytes = List[UInt8](capacity=1024 * 100)
        self._header_ends = List[Int32](capacity=1025)
        self._quality_bytes = List[UInt8](capacity=1024 * 100)
        self._sequence_bytes = List[UInt8](capacity=1024 * 100)
        self._qual_ends = List[Int32](capacity=1025)
        self._quality_offset = 33

    fn add(mut self, record: FastqRecord):
        """
        Append one FastqRecord: copy its QuStr and SeqStr bytes into the
        packed buffers and record the cumulative quality length for offsets.
        Uses the record's quality_schema.OFFSET for the first record only.
        """
        if len(self._qual_ends) == 0:
            self._quality_offset = record.quality_schema.OFFSET
        for i in range(len(record.QuStr)):
            self._quality_bytes.append(record.QuStr[i])
        for i in range(len(record.SeqStr)):
            self._sequence_bytes.append(record.SeqStr[i])
        self._qual_ends.append(Int32(len(self._quality_bytes)))

        for i in range(len(record.SeqHeader)):
            self._header_bytes.append(record.SeqHeader[i])
        self._header_ends.append(Int32(len(self._header_bytes)))

    fn num_records(self) -> Int:
        return len(self._qual_ends)

    fn total_quality_len(self) -> Int:
        return len(self._quality_bytes)

    fn quality_offset(self) -> UInt8:
        return self._quality_offset


@fieldwise_init
struct DeviceFastqBatch:
    """
    Device-side buffers and metadata after upload. Holds device buffers and
    num_records / quality_offset for launching the prefix-sum kernel.
    """

    var qual_buffer: DeviceBuffer[DType.uint8]
    var offsets_buffer: DeviceBuffer[DType.int32]
    var num_records: Int
    var total_quality_len: Int
    var quality_offset: UInt8


fn upload_batch_to_device(
    batch: FastqBatch, ctx: DeviceContext
) raises -> DeviceFastqBatch:
    """
    Allocate device buffers and copy batch data to the given DeviceContext.
    Returns a handle holding device buffers and metadata for kernel launch.
    """
    var total_qual = batch.total_quality_len()
    var n = batch.num_records()
    var qual_buf = ctx.enqueue_create_buffer[DType.uint8](total_qual)
    var offsets_buf = ctx.enqueue_create_buffer[DType.int32](n + 1)

    var host_qual = ctx.enqueue_create_host_buffer[DType.uint8](total_qual)
    var host_offs = ctx.enqueue_create_host_buffer[DType.int32](n + 1)
    ctx.synchronize()

    for i in range(total_qual):
        host_qual[i] = batch._quality_bytes[i]

    host_offs[0] = 0
    for i in range(n):
        host_offs[i + 1] = batch._qual_ends[i]
    ctx.enqueue_copy(src_buf=host_qual, dst_buf=qual_buf)
    ctx.enqueue_copy(src_buf=host_offs, dst_buf=offsets_buf)

    return DeviceFastqBatch(
        qual_buffer=qual_buf,
        offsets_buffer=offsets_buf,
        num_records=n,
        total_quality_len=total_qual,
        quality_offset=batch.quality_offset(),
    )


# ---------------------------------------------------------------------------
# Prefix-sum kernel: one block per record, writes Int32 prefix sums to output
# ---------------------------------------------------------------------------

comptime BLOCK_SIZE = 1


fn quality_prefix_sum_kernel(
    qual_ptr: UnsafePointer[UInt8, MutAnyOrigin],
    offsets_ptr: UnsafePointer[Int32, MutAnyOrigin],
    prefix_sum_out_ptr: UnsafePointer[Int32, MutAnyOrigin],
    num_records: Int,
    quality_offset: UInt8,
):
    """
    GPU kernel: for each record i, compute prefix sum of (quality_byte - offset)
    over [offsets[i], offsets[i+1]) and write Int32 results to prefix_sum_out.
    One thread block per record; thread 0 in the block does the scan.
    """
    var record_id = block_idx.x
    if record_id >= num_records:
        return
    var qual_start = offsets_ptr[record_id]
    var qual_end = offsets_ptr[record_id + 1]
    var qual_len = qual_end - qual_start
    var base = qual_start
    if thread_idx.x == 0:
        var s: Int32 = 0
        var j: Int32 = 0
        while j < qual_len:
            s += Int32(qual_ptr[base + j]) - Int32(quality_offset)
            prefix_sum_out_ptr[base + j] = s
            j += 1


fn enqueue_quality_prefix_sum(
    on_device: DeviceFastqBatch,
    ctx: DeviceContext,
) raises -> DeviceBuffer[DType.int32]:
    """
    Allocate output buffer, compile and enqueue quality_prefix_sum_kernel, return
    the output DeviceBuffer (length = total_quality_len). Caller should
    synchronize and copy back if needed.
    """
    var out_buf = ctx.enqueue_create_buffer[DType.int32](
        on_device.total_quality_len
    )
    var kernel = ctx.compile_function[
        quality_prefix_sum_kernel, quality_prefix_sum_kernel
    ]()
    ctx.enqueue_function(
        kernel,
        on_device.qual_buffer,
        on_device.offsets_buffer,
        out_buf,
        on_device.num_records,
        on_device.quality_offset,
        grid_dim=on_device.num_records,
        block_dim=BLOCK_SIZE,
    )
    return out_buf
