from gpu.host import DeviceContext
from gpu.host.device_context import DeviceBuffer
from gpu import block_idx, thread_idx
from memory import UnsafePointer
from blazeseq.device_record import DeviceFastqBatch


# ---------------------------------------------------------------------------
# Per-record prefix-sum kernel: one block per record, no running sum across reads
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
    GPU kernel: per record only. For each record i, compute prefix sum of
    (quality_byte - offset) over that record's range [offsets[i], offsets[i+1]);
    s starts at 0 for each record. No running prefix sum across reads.
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
