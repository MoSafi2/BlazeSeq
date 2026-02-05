from gpu.host import DeviceContext
from gpu.host.device_context import DeviceBuffer
from gpu import block_idx, thread_idx, block_dim
from gpu.sync import barrier
from gpu.memory import AddressSpace
from memory import UnsafePointer
from layout import Layout, LayoutTensor
from blazeseq.device_record import DeviceFastqBatch


# ---------------------------------------------------------------------------
# Optimized per-record prefix-sum kernel using parallel scan
# ---------------------------------------------------------------------------

comptime BLOCK_SIZE = 256  # Threads per block - optimal for RTX 4070


fn quality_prefix_sum_kernel(
    qual_ptr: UnsafePointer[UInt8, MutAnyOrigin],
    offsets_ptr: UnsafePointer[Int32, MutAnyOrigin],
    prefix_sum_out_ptr: UnsafePointer[Int32, MutAnyOrigin],
    num_records: Int,
    quality_offset: UInt8,
):
    """
    Optimized GPU kernel: parallel prefix sum per record.
    Each block processes one record with BLOCK_SIZE threads cooperating.
    Uses Hillis-Steele scan for simplicity (works well for 85-byte records).
    """
    var record_id = Int(block_idx.x)
    if record_id >= num_records:
        return
    
    var tid = Int(thread_idx.x)
    var qual_start = Int(offsets_ptr[record_id])
    var qual_end = Int(offsets_ptr[record_id + 1])
    var qual_len = qual_end - qual_start
    
    # Allocate shared memory for parallel scan
    var shared = LayoutTensor[
        DType.int32,
        Layout.row_major(BLOCK_SIZE),
        MutAnyOrigin,
        address_space=AddressSpace.SHARED,
    ].stack_allocation()
    
    # Load quality values and convert to Int32
    # Each thread loads one element
    if tid < qual_len:
        shared[tid] = Int32(qual_ptr[qual_start + tid]) - Int32(quality_offset)
    else:
        shared[tid] = 0
    
    barrier()
    
    # Hillis-Steele parallel scan (inclusive)
    # For 85-byte records, this needs log2(85) ≈ 7 iterations
    var offset = 1
    while offset < BLOCK_SIZE:
        var temp: Int32 = 0
        if tid >= offset:
            temp = shared[tid - offset][0]
        
        barrier()
        
        if tid >= offset:
            shared[tid] += temp
        
        barrier()
        offset *= 2
    
    # Write results back to global memory
    if tid < qual_len:
        prefix_sum_out_ptr[qual_start + tid] = shared[tid][0]


fn quality_prefix_sum_kernel_small(
    qual_ptr: UnsafePointer[UInt8, MutAnyOrigin],
    offsets_ptr: UnsafePointer[Int32, MutAnyOrigin],
    prefix_sum_out_ptr: UnsafePointer[Int32, MutAnyOrigin],
    num_records: Int,
    quality_offset: UInt8,
):
    """
    Optimized kernel for very short records (<= 32 bytes).
    Multiple records per block, one warp per record.
    """
    comptime WARP_SIZE = 32
    var records_per_block = BLOCK_SIZE // WARP_SIZE
    var global_record_id = Int(block_idx.x) * records_per_block + (Int(thread_idx.x) // WARP_SIZE)
    
    if global_record_id >= num_records:
        return
    
    var lane_id = Int(thread_idx.x) % WARP_SIZE
    var qual_start = Int(offsets_ptr[global_record_id])
    var qual_end = Int(offsets_ptr[global_record_id + 1])
    var qual_len = qual_end - qual_start
    
    # Allocate shared memory (one section per warp)
    var shared = LayoutTensor[
        DType.int32,
        Layout.row_major(BLOCK_SIZE),
        MutAnyOrigin,
        address_space=AddressSpace.SHARED,
    ].stack_allocation()
    
    var warp_offset = (Int(thread_idx.x) // WARP_SIZE) * WARP_SIZE
    
    # Load
    if lane_id < qual_len:
        shared[warp_offset + lane_id] = Int32(qual_ptr[qual_start + lane_id]) - Int32(quality_offset)
    else:
        shared[warp_offset + lane_id] = 0
    
    barrier()
    
    # Warp-level scan
    var offset = 1
    while offset < WARP_SIZE:
        var temp: Int32 = 0
        if lane_id >= offset:
            temp = shared[warp_offset + lane_id - offset][0]
        
        barrier()
        
        if lane_id >= offset:
            shared[warp_offset + lane_id] += temp
        
        barrier()
        offset *= 2
    
    # Write back
    if lane_id < qual_len:
        prefix_sum_out_ptr[qual_start + lane_id] = shared[warp_offset + lane_id][0]


fn enqueue_quality_prefix_sum(
    on_device: DeviceFastqBatch,
    ctx: DeviceContext,
) raises -> DeviceBuffer[DType.int32]:
    """
    Allocate output buffer and launch optimized kernel based on average record length.
    """
    var out_buf = ctx.enqueue_create_buffer[DType.int32](
        on_device.total_quality_len
    )
    
    # Choose kernel based on average quality length
    var avg_qual_len = on_device.total_quality_len // on_device.num_records
    
    if avg_qual_len <= 32:
        # Use small-record kernel: multiple records per block
        var kernel = ctx.compile_function[
            quality_prefix_sum_kernel_small, quality_prefix_sum_kernel_small
        ]()
        var records_per_block = BLOCK_SIZE // 32
        var num_blocks = (on_device.num_records + records_per_block - 1) // records_per_block
        
        ctx.enqueue_function(
            kernel,
            on_device.qual_buffer,
            on_device.offsets_buffer,
            out_buf,
            on_device.num_records,
            on_device.quality_offset,
            grid_dim=num_blocks,
            block_dim=BLOCK_SIZE,
        )
    else:
        # Use standard kernel: one record per block with parallel scan
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