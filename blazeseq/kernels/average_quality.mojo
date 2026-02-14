"""QC GPU kernel: batch average quality (mean Phred in offset space)."""

from gpu.host import DeviceContext
from gpu.host.device_context import DeviceBuffer
from gpu import block_idx, thread_idx, block_dim
from gpu.sync import barrier
from gpu.memory import AddressSpace
from memory import UnsafePointer
from layout import Layout, LayoutTensor
from blazeseq.device_record import DeviceFastqBatch


# ---------------------------------------------------------------------------
# Reduction kernel: sum (qual[i] - quality_offset) over all i
# ---------------------------------------------------------------------------

comptime BLOCK_SIZE = 256  # Threads per block; power of 2 for tree reduction


fn batch_quality_sum_reduction_kernel(
    qual_ptr: UnsafePointer[UInt8, MutAnyOrigin],
    quality_offset: UInt8,
    seq_len: Int,
    partial_sums_ptr: UnsafePointer[Int64, MutAnyOrigin],
):
    """
    Each block reduces a contiguous chunk of the quality array to one Int64 sum.
    Threads load (qual - offset), tree-reduce in shared memory, thread 0 writes block sum.
    """
    var tid = Int(thread_idx.x)
    var block_start = Int(block_idx.x) * BLOCK_SIZE
    var global_idx = block_start + tid

    var local_sum: Int64 = 0
    if global_idx < seq_len:
        local_sum = Int64(qual_ptr[global_idx]) - Int64(quality_offset)

    var shared = LayoutTensor[
        DType.int64,
        Layout.row_major(BLOCK_SIZE),
        MutAnyOrigin,
        address_space = AddressSpace.SHARED,
    ].stack_allocation()

    shared[tid] = local_sum
    barrier()

    # Tree reduction (in-place, stride halved each step)
    var stride = BLOCK_SIZE // 2
    while stride > 0:
        if tid < stride:
            shared[tid] = shared[tid][0] + shared[tid + stride][0]
        barrier()
        stride //= 2

    if tid == 0:
        partial_sums_ptr[block_idx.x] = shared[0][0]


# ---------------------------------------------------------------------------
# Enqueue and result retrieval
# ---------------------------------------------------------------------------


struct BatchAverageQualityResult(ImplicitlyDestructible, Movable):
    """
    Holds the device buffer of partial sums from the QC kernel. The caller's
    DeviceFastqBatch is unchanged; call retrieve(ctx) to copy results from
    GPU and get the batch average quality.
    """

    var device_batch: DeviceFastqBatch
    var partial_sums_buffer: DeviceBuffer[DType.int64]
    var num_blocks: Int
    var seq_len: Int

    fn __init__(
        out self,
        var batch: DeviceFastqBatch,
        partial_sums_buffer: DeviceBuffer[DType.int64],
        num_blocks: Int,
        seq_len: Int,
    ):
        self.device_batch = batch^
        self.partial_sums_buffer = partial_sums_buffer
        self.num_blocks = num_blocks
        self.seq_len = seq_len

    fn retrieve(self, ctx: DeviceContext) raises -> Float64:
        """
        Copy partial sums from GPU to host, sum them, return average quality.
        Returns 0.0 when seq_len is 0 (no kernel was launched).
        """
        if self.seq_len == 0:
            return 0.0
        if self.num_blocks == 0:
            return 0.0

        var host_buf = ctx.enqueue_create_host_buffer[DType.int64](
            self.num_blocks
        )
        ctx.enqueue_copy(
            src_buf=self.partial_sums_buffer,
            dst_buf=host_buf,
        )
        ctx.synchronize()

        var total_sum: Int64 = 0
        for i in range(self.num_blocks):
            total_sum += host_buf[i]

        return Float64(total_sum) / Float64(self.seq_len)


fn enqueue_batch_average_quality(
    var device_batch: DeviceFastqBatch,
    ctx: DeviceContext,
) raises -> BatchAverageQualityResult:
    """
    Launch reduction kernel over the batch quality buffer; return the same
    DeviceFastqBatch and a result handle. Use .retrieve(ctx) to get the
    batch average quality (Float64).
    """
    if device_batch.qual_buffer is None:
        raise Error("enqueue_batch_average_quality requires qual_buffer")

    var seq_len_val = device_batch.seq_len
    if seq_len_val == 0:
        var empty_buf = ctx.enqueue_create_buffer[DType.int64](0)
        return BatchAverageQualityResult(
            batch=device_batch^,
            partial_sums_buffer=empty_buf,
            num_blocks=0,
            seq_len=0,
        )

    var num_blocks = (seq_len_val + BLOCK_SIZE - 1) // BLOCK_SIZE
    var partial_sums_buf = ctx.enqueue_create_buffer[DType.int64](num_blocks)

    var kernel = ctx.compile_function[
        batch_quality_sum_reduction_kernel,
        batch_quality_sum_reduction_kernel,
    ]()

    ctx.enqueue_function(
        kernel,
        device_batch.qual_buffer.value(),
        device_batch.quality_offset,
        seq_len_val,
        partial_sums_buf,
        grid_dim=num_blocks,
        block_dim=BLOCK_SIZE,
    )

    return BatchAverageQualityResult(
        batch=device_batch^,
        partial_sums_buffer=partial_sums_buf,
        num_blocks=num_blocks,
        seq_len=seq_len_val,
    )
