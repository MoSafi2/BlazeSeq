"""QC GPU kernel: quality distribution (2D position×quality histogram, 1D per-read average histogram)."""

from gpu.host import DeviceContext
from gpu.host.device_context import DeviceBuffer, HostBuffer
from gpu import block_idx, thread_idx, block_dim
from gpu.sync import barrier
from gpu.memory import AddressSpace
from memory import UnsafePointer
from layout import Layout, LayoutTensor
from blazeseq.device_record import DeviceFastqBatch

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

comptime BLOCK_SIZE = 256
comptime NUM_QUAL_BINS = 128
comptime QU_DIST_SEQ_LEN = 256

# ---------------------------------------------------------------------------
# Phase 1: Record metadata (length + sum per record)
# ---------------------------------------------------------------------------


fn record_metadata_kernel(
    offsets_ptr: UnsafePointer[Int32, MutAnyOrigin],
    qual_ptr: UnsafePointer[UInt8, MutAnyOrigin],
    lengths_out: UnsafePointer[Int32, MutAnyOrigin],
    record_sums_out: UnsafePointer[Int64, MutAnyOrigin],
    num_records: Int,
):
    """
    One block per record. Block r computes length[r] and sum of qual bytes for record r.
    """
    var record_id = Int(block_idx.x)
    if record_id >= num_records:
        return

    var tid = Int(thread_idx.x)
    var qual_start = Int(offsets_ptr[record_id])
    var qual_end = Int(offsets_ptr[record_id + 1])
    var qual_len = qual_end - qual_start

    # Shared memory for block-level sum and length
    var shared_sum = LayoutTensor[
        DType.int64,
        Layout.row_major(BLOCK_SIZE),
        MutAnyOrigin,
        address_space = AddressSpace.SHARED,
    ].stack_allocation()

    var local_sum: Int64 = 0
    var i = tid
    while i < qual_len:
        local_sum += Int64(qual_ptr[qual_start + i])
        i += BLOCK_SIZE

    shared_sum[tid] = local_sum
    barrier()

    # Tree reduction for sum
    var stride = BLOCK_SIZE // 2
    while stride > 0:
        if tid < stride:
            shared_sum[tid] = shared_sum[tid][0] + shared_sum[tid + stride][0]
        barrier()
        stride //= 2

    if tid == 0:
        lengths_out[record_id] = Int32(qual_len)
        record_sums_out[record_id] = shared_sum[0][0]


# ---------------------------------------------------------------------------
# Phase 1: Min/max reduction over all quality bytes
# ---------------------------------------------------------------------------


fn min_max_qual_kernel(
    qual_ptr: UnsafePointer[UInt8, MutAnyOrigin],
    seq_len: Int,
    partial_mins: UnsafePointer[UInt8, MutAnyOrigin],
    partial_maxs: UnsafePointer[UInt8, MutAnyOrigin],
):
    """
    Each block reduces a chunk of qual to (min, max). Block b writes partial_mins[b], partial_maxs[b].
    """
    var tid = Int(thread_idx.x)
    var block_start = Int(block_idx.x) * BLOCK_SIZE
    var global_idx = block_start + tid

    var local_min: UInt8 = 255
    var local_max: UInt8 = 0
    if global_idx < seq_len:
        var q = qual_ptr[global_idx]
        local_min = q
        local_max = q

    var shared_min = LayoutTensor[
        DType.uint8,
        Layout.row_major(BLOCK_SIZE),
        MutAnyOrigin,
        address_space = AddressSpace.SHARED,
    ].stack_allocation()
    var shared_max = LayoutTensor[
        DType.uint8,
        Layout.row_major(BLOCK_SIZE),
        MutAnyOrigin,
        address_space = AddressSpace.SHARED,
    ].stack_allocation()

    shared_min[tid] = local_min
    shared_max[tid] = local_max
    barrier()

    # Tree reduction for min and max
    var stride = BLOCK_SIZE // 2
    while stride > 0:
        if tid < stride:
            var a_min = shared_min[tid][0]
            var b_min = shared_min[tid + stride][0]
            shared_min[tid] = min(a_min, b_min)
            var a_max = shared_max[tid][0]
            var b_max = shared_max[tid + stride][0]
            shared_max[tid] = max(a_max, b_max)
        barrier()
        stride //= 2

    if tid == 0:
        partial_mins[block_idx.x] = shared_min[0][0]
        partial_maxs[block_idx.x] = shared_max[0][0]


# ---------------------------------------------------------------------------
# Phase 2: 2D histogram qu_dist (one block per position row; no atomics)
# ---------------------------------------------------------------------------


fn qu_dist_row_kernel(
    qual_ptr: UnsafePointer[UInt8, MutAnyOrigin],
    offsets_ptr: UnsafePointer[Int32, MutAnyOrigin],
    qu_dist_out: UnsafePointer[Int64, MutAnyOrigin],
    num_records: Int,
    max_length: Int,
):
    """
    One block per position. Block index is the position row (grid_dim = max_length).
    Each thread processes a subset of records; we reduce per-bin into qu_dist_out[row, 0..127].
    """
    var p = Int(block_idx.x)
    if p >= max_length:
        return
    var tid = Int(thread_idx.x)

    # Per-thread bins (thread-local stack). We use shared for the final reduction.
    var my_bins = LayoutTensor[
        DType.int64,
        Layout.row_major(NUM_QUAL_BINS),
        MutAnyOrigin,
    ].stack_allocation()

    for i in range(NUM_QUAL_BINS):
        my_bins[i] = 0

    # Each thread handles records tid, tid + BLOCK_SIZE, ...
    var r = tid
    while r < num_records:
        var qual_start = Int(offsets_ptr[r])
        var qual_end = Int(offsets_ptr[r + 1])
        var length = qual_end - qual_start
        if p < length:
            var qu = qual_ptr[qual_start + p]
            if Int(qu) < NUM_QUAL_BINS:
                my_bins[Int(qu)] = my_bins[Int(qu)][0] + 1
        r += BLOCK_SIZE

    # Reduce 256 threads' bins into one row using shared memory (one bin at a time)
    var shared = LayoutTensor[
        DType.int64,
        Layout.row_major(BLOCK_SIZE),
        MutAnyOrigin,
        address_space = AddressSpace.SHARED,
    ].stack_allocation()

    for b in range(NUM_QUAL_BINS):
        shared[tid] = my_bins[b][0]
        barrier()
        var stride = BLOCK_SIZE // 2
        while stride > 0:
            if tid < stride:
                shared[tid] = shared[tid][0] + shared[tid + stride][0]
            barrier()
            stride //= 2
        if tid == 0:
            qu_dist_out[p * NUM_QUAL_BINS + b] = shared[0][0]
        barrier()


# ---------------------------------------------------------------------------
# Phase 2: Per-read average histogram (qu_dist_seq) - block-local then merge
# ---------------------------------------------------------------------------


fn qu_dist_seq_local_kernel(
    lengths_ptr: UnsafePointer[Int32, MutAnyOrigin],
    record_sums_ptr: UnsafePointer[Int64, MutAnyOrigin],
    block_histograms_out: UnsafePointer[Int64, MutAnyOrigin],
    num_records: Int,
    num_bins: Int,
):
    """
    Each block builds a local histogram of per-read average quality.
    block_histograms_out[block_id * num_bins + b] = count in block for bin b.
    """
    var tid = Int(thread_idx.x)
    var block_id = Int(block_idx.x)
    var records_per_block = BLOCK_SIZE
    var record_start = block_id * records_per_block
    var record_id = record_start + tid

    # Local histogram for this thread (bins 0..num_bins-1)
    var my_bins = LayoutTensor[
        DType.int64,
        Layout.row_major(QU_DIST_SEQ_LEN),
        MutAnyOrigin,
    ].stack_allocation()
    for i in range(num_bins):
        my_bins[i] = 0

    var r = record_id
    while r < num_records:
        var length = Int(lengths_ptr[r])
        if length > 0:
            var s = record_sums_ptr[r]
            var avg = Int(s / length)
            if avg >= num_bins:
                avg = num_bins - 1
            if avg < 0:
                avg = 0
            my_bins[avg] = my_bins[avg][0] + 1
        r += BLOCK_SIZE

    # Reduce into shared, then write block's row to global
    var shared = LayoutTensor[
        DType.int64,
        Layout.row_major(BLOCK_SIZE),
        MutAnyOrigin,
        address_space = AddressSpace.SHARED,
    ].stack_allocation()

    for b in range(num_bins):
        shared[tid] = my_bins[b][0]
        barrier()
        var stride = BLOCK_SIZE // 2
        while stride > 0:
            if tid < stride:
                shared[tid] = shared[tid][0] + shared[tid + stride][0]
            barrier()
            stride //= 2
        if tid == 0:
            block_histograms_out[block_id * num_bins + b] = shared[0][0]
        barrier()


fn qu_dist_seq_merge_kernel(
    block_histograms: UnsafePointer[Int64, MutAnyOrigin],
    qu_dist_seq_out: UnsafePointer[Int64, MutAnyOrigin],
    num_blocks: Int,
    num_bins: Int,
):
    """
    One thread per bin. Each thread sums block_histograms[0..num_blocks-1][tid].
    """
    var tid = Int(thread_idx.x)
    if tid >= num_bins:
        return
    var total: Int64 = 0
    for b in range(num_blocks):
        total += block_histograms[b * num_bins + tid]
    qu_dist_seq_out[tid] = total


# ---------------------------------------------------------------------------
# Host-side result type and retrieve
# ---------------------------------------------------------------------------


struct QualityDistributionHostResult(Movable):
    """
    Host-side result: flat histograms and scalars for the caller.
    qu_dist is row-major, length max_length * 128; row i = position i.
    """

    var qu_dist: List[Int64]
    var qu_dist_seq: List[Int64]
    var max_length: Int
    var min_qu: UInt8
    var max_qu: UInt8

    fn __init__(
        out self,
        var qu_dist: List[Int64],
        var qu_dist_seq: List[Int64],
        max_length: Int,
        min_qu: UInt8,
        max_qu: UInt8,
    ):
        self.qu_dist = qu_dist^
        self.qu_dist_seq = qu_dist_seq^
        self.max_length = max_length
        self.min_qu = min_qu
        self.max_qu = max_qu


struct QualityDistributionResult(ImplicitlyDestructible, Movable):
    """
    Holds device buffers from the quality distribution kernels.
    Call retrieve(ctx) to copy to host and get QualityDistributionHostResult.
    """

    var qu_dist_buffer: DeviceBuffer[DType.int64]
    var qu_dist_seq_buffer: DeviceBuffer[DType.int64]
    var max_length: Int
    var min_qu: UInt8
    var max_qu: UInt8

    fn __init__(
        out self,
        var qu_dist_buffer: DeviceBuffer[DType.int64],
        var qu_dist_seq_buffer: DeviceBuffer[DType.int64],
        max_length: Int,
        min_qu: UInt8,
        max_qu: UInt8,
    ):
        self.qu_dist_buffer = qu_dist_buffer^
        self.qu_dist_seq_buffer = qu_dist_seq_buffer^
        self.max_length = max_length
        self.min_qu = min_qu
        self.max_qu = max_qu

    fn retrieve(self, ctx: DeviceContext) raises -> QualityDistributionHostResult:
        """
        Copy device buffers to host and return flat lists and scalars.
        """
        var qu_dist = List[Int64]()
        var qu_dist_seq = List[Int64]()

        if self.max_length > 0:
            var n_qu_dist = self.max_length * NUM_QUAL_BINS
            var host_qu_dist = ctx.enqueue_create_host_buffer[DType.int64](
                n_qu_dist
            )
            ctx.enqueue_copy(
                src_buf=self.qu_dist_buffer,
                dst_buf=host_qu_dist,
            )
            ctx.synchronize()
            for i in range(n_qu_dist):
                qu_dist.append(host_qu_dist[i])

        var host_qu_dist_seq = ctx.enqueue_create_host_buffer[DType.int64](
            QU_DIST_SEQ_LEN
        )
        ctx.enqueue_copy(
            src_buf=self.qu_dist_seq_buffer,
            dst_buf=host_qu_dist_seq,
        )
        ctx.synchronize()
        for i in range(QU_DIST_SEQ_LEN):
            qu_dist_seq.append(host_qu_dist_seq[i])

        return QualityDistributionHostResult(
            qu_dist=qu_dist^,
            qu_dist_seq=qu_dist_seq^,
            max_length=self.max_length,
            min_qu=self.min_qu,
            max_qu=self.max_qu,
        )


# ---------------------------------------------------------------------------
# CPU reference: same logic as GPU kernels, for comparison
# ---------------------------------------------------------------------------


fn cpu_quality_distribution(
    quality_bytes: List[UInt8],
    offsets: List[Int32],
) raises -> QualityDistributionHostResult:
    """
    CPU reference: computes qu_dist (position x quality), qu_dist_seq (per-read
    mean quality histogram), max_length, min_qu, max_qu. Same semantics as
    enqueue_quality_distribution + retrieve; use to compare GPU vs CPU.
    offsets must be cumulative quality ends with a leading 0: [0, end0, end1, ...].
    """
    var num_records = len(offsets) - 1
    if num_records <= 0:
        var empty_seq = List[Int64](capacity=QU_DIST_SEQ_LEN)
        for _ in range(QU_DIST_SEQ_LEN):
            empty_seq.append(0)
        return QualityDistributionHostResult(
            List[Int64](),
            empty_seq^,
            0,
            255,
            0,
        )

    var max_length: Int = 0
    for i in range(num_records):
        var L = Int(offsets[i + 1]) - Int(offsets[i])
        if L > max_length:
            max_length = L

    var min_qu: UInt8 = 255
    var max_qu: UInt8 = 0
    for i in range(len(quality_bytes)):
        if quality_bytes[i] < min_qu:
            min_qu = quality_bytes[i]
        if quality_bytes[i] > max_qu:
            max_qu = quality_bytes[i]

    var qu_dist = List[Int64](capacity=max_length * NUM_QUAL_BINS)
    for _ in range(max_length * NUM_QUAL_BINS):
        qu_dist.append(0)

    var qu_dist_seq = List[Int64](capacity=QU_DIST_SEQ_LEN)
    for _ in range(QU_DIST_SEQ_LEN):
        qu_dist_seq.append(0)

    for r in range(num_records):
        var start = Int(offsets[r])
        var end = Int(offsets[r + 1])
        var length = end - start
        var qu_sum: Int64 = 0
        for p in range(length):
            var q = quality_bytes[start + p]
            if Int(q) < NUM_QUAL_BINS:
                qu_dist[p * NUM_QUAL_BINS + Int(q)] = (
                    qu_dist[p * NUM_QUAL_BINS + Int(q)] + 1
                )
            qu_sum += Int64(q)
        var average = Int(qu_sum / length)
        if average >= QU_DIST_SEQ_LEN:
            average = QU_DIST_SEQ_LEN - 1
        if average < 0:
            average = 0
        qu_dist_seq[average] = qu_dist_seq[average] + 1

    return QualityDistributionHostResult(
        qu_dist^,
        qu_dist_seq^,
        max_length,
        min_qu,
        max_qu,
    )


# ---------------------------------------------------------------------------
# Enqueue: run Phase 1 and Phase 2, return result handle
# ---------------------------------------------------------------------------


fn enqueue_quality_distribution(
    var device_batch: DeviceFastqBatch,
    ctx: DeviceContext,
) raises -> QualityDistributionResult:
    """
    Launch quality distribution kernels over the batch; return a result handle.
    Use .retrieve(ctx) to get host-side histograms and scalars.
    """
    if device_batch.qual_buffer is None or device_batch.offsets_buffer is None:
        raise Error(
            "enqueue_quality_distribution requires qual_buffer and offsets_buffer"
        )

    var num_records = device_batch.num_records
    var seq_len_val = device_batch.seq_len

    # Empty batch: return empty result with sentinel min/max
    if num_records == 0 or seq_len_val == 0:
        var empty_qu_dist = ctx.enqueue_create_buffer[DType.int64](0)
        var empty_qu_dist_seq = ctx.enqueue_create_buffer[DType.int64](
            QU_DIST_SEQ_LEN
        )
        # Zero the seq histogram on device (optional; retrieve will copy zeros)
        return QualityDistributionResult(
            qu_dist_buffer=empty_qu_dist^,
            qu_dist_seq_buffer=empty_qu_dist_seq^,
            max_length=0,
            min_qu=255,
            max_qu=0,
        )

    # ---------- Phase 1: Record metadata (lengths + record_sums) ----------
    var lengths_buf = ctx.enqueue_create_buffer[DType.int32](num_records)
    var record_sums_buf = ctx.enqueue_create_buffer[DType.int64](num_records)

    var meta_kernel = ctx.compile_function[
        record_metadata_kernel,
        record_metadata_kernel,
    ]()
    ctx.enqueue_function(
        meta_kernel,
        device_batch.offsets_buffer.value(),
        device_batch.qual_buffer.value(),
        lengths_buf,
        record_sums_buf,
        num_records,
        grid_dim=num_records,
        block_dim=BLOCK_SIZE,
    )

    # ---------- Phase 1: Min/max over qual buffer ----------
    var num_blocks_minmax = (seq_len_val + BLOCK_SIZE - 1) // BLOCK_SIZE
    var partial_mins_buf = ctx.enqueue_create_buffer[DType.uint8](
        num_blocks_minmax
    )
    var partial_maxs_buf = ctx.enqueue_create_buffer[DType.uint8](
        num_blocks_minmax
    )

    var minmax_kernel = ctx.compile_function[
        min_max_qual_kernel,
        min_max_qual_kernel,
    ]()
    ctx.enqueue_function(
        minmax_kernel,
        device_batch.qual_buffer.value(),
        seq_len_val,
        partial_mins_buf,
        partial_maxs_buf,
        grid_dim=num_blocks_minmax,
        block_dim=BLOCK_SIZE,
    )

    # ---------- Host: get max_length, min_qu, max_qu ----------
    var host_lengths = ctx.enqueue_create_host_buffer[DType.int32](
        num_records
    )
    ctx.enqueue_copy(src_buf=lengths_buf, dst_buf=host_lengths)
    var host_mins = ctx.enqueue_create_host_buffer[DType.uint8](
        num_blocks_minmax
    )
    var host_maxs = ctx.enqueue_create_host_buffer[DType.uint8](
        num_blocks_minmax
    )
    ctx.enqueue_copy(src_buf=partial_mins_buf, dst_buf=host_mins)
    ctx.enqueue_copy(src_buf=partial_maxs_buf, dst_buf=host_maxs)
    ctx.synchronize()

    var max_length: Int = 0
    for i in range(num_records):
        var L = Int(host_lengths[i])
        if L > max_length:
            max_length = L

    var min_qu: UInt8 = 255
    var max_qu: UInt8 = 0
    for i in range(num_blocks_minmax):
        if host_mins[i] < min_qu:
            min_qu = host_mins[i]
        if host_maxs[i] > max_qu:
            max_qu = host_maxs[i]

    # If no data, keep sentinels
    if seq_len_val == 0:
        min_qu = 255
        max_qu = 0

    # ---------- Phase 2: 2D histogram qu_dist (one block per position) ----------
    var qu_dist_size = max_length * NUM_QUAL_BINS
    var qu_dist_buf = ctx.enqueue_create_buffer[DType.int64](qu_dist_size)

    var qd_kernel = ctx.compile_function[
        qu_dist_row_kernel,
        qu_dist_row_kernel,
    ]()
    ctx.enqueue_function(
        qd_kernel,
        device_batch.qual_buffer.value(),
        device_batch.offsets_buffer.value(),
        qu_dist_buf,
        num_records,
        max_length,
        grid_dim=max_length,
        block_dim=BLOCK_SIZE,
    )

    # ---------- Phase 2: qu_dist_seq (block-local histograms + merge) ----------
    var seq_blocks = (num_records + BLOCK_SIZE - 1) // BLOCK_SIZE
    var block_histograms_buf = ctx.enqueue_create_buffer[DType.int64](
        seq_blocks * QU_DIST_SEQ_LEN
    )
    var qu_dist_seq_buf = ctx.enqueue_create_buffer[DType.int64](
        QU_DIST_SEQ_LEN
    )

    var seq_local_kernel = ctx.compile_function[
        qu_dist_seq_local_kernel,
        qu_dist_seq_local_kernel,
    ]()
    ctx.enqueue_function(
        seq_local_kernel,
        lengths_buf,
        record_sums_buf,
        block_histograms_buf,
        num_records,
        QU_DIST_SEQ_LEN,
        grid_dim=seq_blocks,
        block_dim=BLOCK_SIZE,
    )

    var merge_kernel = ctx.compile_function[
        qu_dist_seq_merge_kernel,
        qu_dist_seq_merge_kernel,
    ]()
    ctx.enqueue_function(
        merge_kernel,
        block_histograms_buf,
        qu_dist_seq_buf,
        seq_blocks,
        QU_DIST_SEQ_LEN,
        grid_dim=1,
        block_dim=QU_DIST_SEQ_LEN,
    )

    return QualityDistributionResult(
        qu_dist_buffer=qu_dist_buf^,
        qu_dist_seq_buffer=qu_dist_seq_buf^,
        max_length=max_length,
        min_qu=min_qu,
        max_qu=max_qu,
    )
