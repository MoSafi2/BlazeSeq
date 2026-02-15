"""Small tests for individual quality-distribution GPU kernels.

Requires a supported GPU (see Mojo docs for GPU architectures).
Tests are skipped via has_accelerator() when no GPU is available;
on systems where GPU code is compiled but no GPU is detected, run on a GPU host.
"""

from blazeseq.kernels.quality_distribution import (
    record_metadata_kernel,
    min_max_qual_kernel,
    reduce_max_int32_kernel,
    reduce_min_uint8_kernel,
    reduce_max_uint8_kernel,
    qu_dist_row_kernel,
    qu_dist_seq_local_kernel,
    qu_dist_seq_merge_kernel,
    add_qu_dist_kernel,
    add_qu_dist_seq_kernel,
    merge_scalars_kernel,
    zero_int64_kernel,
)
from gpu.host import DeviceContext
from sys import has_accelerator
from testing import assert_equal, TestSuite

# Match kernel module constants for grid/block dimensions
comptime BLOCK_SIZE = 256
comptime NUM_QUAL_BINS = 128
comptime QU_DIST_SEQ_LEN = 256


fn test_reduce_max_int32_kernel() raises:
    """Reduce_max_int32_kernel: single block reduces [v0..vn-1] to max."""
    @parameter
    if not has_accelerator():
        return
    var ctx = DeviceContext()
    var values = List[Int32](capacity=8)
    values.append(1)
    values.append(5)
    values.append(3)
    values.append(2)
    values.append(7)
    values.append(0)
    values.append(4)
    values.append(1)
    var n = len(values)
    var host_in = ctx.enqueue_create_host_buffer[DType.int32](n)
    for i in range(n):
        host_in[i] = values[i]
    var dev_in = ctx.enqueue_create_buffer[DType.int32](n)
    ctx.enqueue_copy(src_buf=host_in, dst_buf=dev_in)
    var dev_out = ctx.enqueue_create_buffer[DType.int32](1)
    var kernel = ctx.compile_function[
        reduce_max_int32_kernel,
        reduce_max_int32_kernel,
    ]()
    ctx.enqueue_function(
        kernel,
        dev_in,
        n,
        dev_out,
        grid_dim=1,
        block_dim=BLOCK_SIZE,
    )
    var host_out = ctx.enqueue_create_host_buffer[DType.int32](1)
    ctx.enqueue_copy(src_buf=dev_out, dst_buf=host_out)
    ctx.synchronize()
    assert_equal(host_out[0], 7)


fn test_reduce_min_uint8_kernel() raises:
    """Reduce_min_uint8_kernel: single block reduces to min."""
    @parameter
    if not has_accelerator():
        return
    var ctx = DeviceContext()
    var values = List[UInt8](capacity=4)
    values.append(200)
    values.append(33)
    values.append(100)
    values.append(50)
    var n = len(values)
    var host_in = ctx.enqueue_create_host_buffer[DType.uint8](n)
    for i in range(n):
        host_in[i] = values[i]
    var dev_in = ctx.enqueue_create_buffer[DType.uint8](n)
    ctx.enqueue_copy(src_buf=host_in, dst_buf=dev_in)
    var dev_out = ctx.enqueue_create_buffer[DType.uint8](1)
    var kernel = ctx.compile_function[
        reduce_min_uint8_kernel,
        reduce_min_uint8_kernel,
    ]()
    ctx.enqueue_function(
        kernel,
        dev_in,
        n,
        dev_out,
        grid_dim=1,
        block_dim=BLOCK_SIZE,
    )
    var host_out = ctx.enqueue_create_host_buffer[DType.uint8](1)
    ctx.enqueue_copy(src_buf=dev_out, dst_buf=host_out)
    ctx.synchronize()
    assert_equal(host_out[0], 33)


fn test_reduce_max_uint8_kernel() raises:
    """Reduce_max_uint8_kernel: single block reduces to max."""
    @parameter
    if not has_accelerator():
        return
    var ctx = DeviceContext()
    var values = List[UInt8](capacity=4)
    values.append(10)
    values.append(200)
    values.append(100)
    values.append(50)
    var n = len(values)
    var host_in = ctx.enqueue_create_host_buffer[DType.uint8](n)
    for i in range(n):
        host_in[i] = values[i]
    var dev_in = ctx.enqueue_create_buffer[DType.uint8](n)
    ctx.enqueue_copy(src_buf=host_in, dst_buf=dev_in)
    var dev_out = ctx.enqueue_create_buffer[DType.uint8](1)
    var kernel = ctx.compile_function[
        reduce_max_uint8_kernel,
        reduce_max_uint8_kernel,
    ]()
    ctx.enqueue_function(
        kernel,
        dev_in,
        n,
        dev_out,
        grid_dim=1,
        block_dim=BLOCK_SIZE,
    )
    var host_out = ctx.enqueue_create_host_buffer[DType.uint8](1)
    ctx.enqueue_copy(src_buf=dev_out, dst_buf=host_out)
    ctx.synchronize()
    assert_equal(host_out[0], 200)


fn test_zero_int64_kernel() raises:
    """Zero_int64_kernel: zeros ptr[0..n)."""
    @parameter
    if not has_accelerator():
        return
    var ctx = DeviceContext()
    var n = 512
    var host_in = ctx.enqueue_create_host_buffer[DType.int64](n)
    for i in range(n):
        host_in[i] = 42
    var dev_buf = ctx.enqueue_create_buffer[DType.int64](n)
    ctx.enqueue_copy(src_buf=host_in, dst_buf=dev_buf)
    var kernel = ctx.compile_function[zero_int64_kernel, zero_int64_kernel]()
    ctx.enqueue_function(
        kernel,
        dev_buf,
        n,
        grid_dim=(n + BLOCK_SIZE - 1) // BLOCK_SIZE,
        block_dim=BLOCK_SIZE,
    )
    var host_out = ctx.enqueue_create_host_buffer[DType.int64](n)
    ctx.enqueue_copy(src_buf=dev_buf, dst_buf=host_out)
    ctx.synchronize()
    for i in range(n):
        assert_equal(host_out[i], 0)


fn test_merge_scalars_kernel() raises:
    """Merge_scalars_kernel: updates acc max_length, min_qu, max_qu from batch."""
    @parameter
    if not has_accelerator():
        return
    var ctx = DeviceContext()
    var host_max_len = ctx.enqueue_create_host_buffer[DType.int32](1)
    host_max_len[0] = 10
    var host_min_max_qu = ctx.enqueue_create_host_buffer[DType.uint8](2)
    host_min_max_qu[0] = 40
    host_min_max_qu[1] = 80
    var dev_max_len = ctx.enqueue_create_buffer[DType.int32](1)
    var dev_min_max_qu = ctx.enqueue_create_buffer[DType.uint8](2)
    ctx.enqueue_copy(src_buf=host_max_len, dst_buf=dev_max_len)
    ctx.enqueue_copy(src_buf=host_min_max_qu, dst_buf=dev_min_max_qu)
    var kernel = ctx.compile_function[
        merge_scalars_kernel,
        merge_scalars_kernel,
    ]()
    var batch_min_qu: UInt8 = 35
    var batch_max_qu: UInt8 = 90
    ctx.enqueue_function(
        kernel,
        20,
        batch_min_qu,
        batch_max_qu,
        dev_max_len,
        dev_min_max_qu,
        grid_dim=1,
        block_dim=1,
    )
    ctx.synchronize()
    var out_max_len = ctx.enqueue_create_host_buffer[DType.int32](1)
    var out_min_max = ctx.enqueue_create_host_buffer[DType.uint8](2)
    ctx.enqueue_copy(src_buf=dev_max_len, dst_buf=out_max_len)
    ctx.enqueue_copy(src_buf=dev_min_max_qu, dst_buf=out_min_max)
    ctx.synchronize()
    assert_equal(out_max_len[0], 20)
    assert_equal(out_min_max[0], 35)
    assert_equal(out_min_max[1], 90)


fn test_qu_dist_seq_merge_kernel() raises:
    """Qu_dist_seq_merge_kernel: sums block histograms into one row."""
    @parameter
    if not has_accelerator():
        return
    var ctx = DeviceContext()
    var num_blocks = 2
    var num_bins = 8
    # block0: [1,0,2,0,0,0,0,0], block1: [0,1,0,3,0,0,0,0] -> merged [1,1,2,3,0,0,0,0]
    var host_blocks = ctx.enqueue_create_host_buffer[DType.int64](
        num_blocks * num_bins
    )
    for i in range(num_blocks * num_bins):
        host_blocks[i] = 0
    host_blocks[0] = 1
    host_blocks[2] = 2
    host_blocks[num_bins + 1] = 1
    host_blocks[num_bins + 3] = 3
    var dev_blocks = ctx.enqueue_create_buffer[DType.int64](
        num_blocks * num_bins
    )
    var dev_out = ctx.enqueue_create_buffer[DType.int64](num_bins)
    ctx.enqueue_copy(src_buf=host_blocks, dst_buf=dev_blocks)
    var kernel = ctx.compile_function[
        qu_dist_seq_merge_kernel,
        qu_dist_seq_merge_kernel,
    ]()
    ctx.enqueue_function(
        kernel,
        dev_blocks,
        dev_out,
        num_blocks,
        num_bins,
        grid_dim=1,
        block_dim=num_bins,
    )
    var host_out = ctx.enqueue_create_host_buffer[DType.int64](num_bins)
    ctx.enqueue_copy(src_buf=dev_out, dst_buf=host_out)
    ctx.synchronize()
    assert_equal(host_out[0], 1)
    assert_equal(host_out[1], 1)
    assert_equal(host_out[2], 2)
    assert_equal(host_out[3], 3)
    for i in range(4, num_bins):
        assert_equal(host_out[i], 0)


fn test_add_qu_dist_seq_kernel() raises:
    """Add_qu_dist_seq_kernel: element-wise acc += batch for QU_DIST_SEQ_LEN bins."""
    @parameter
    if not has_accelerator():
        return
    var ctx = DeviceContext()
    var host_acc = ctx.enqueue_create_host_buffer[DType.int64](QU_DIST_SEQ_LEN)
    var host_batch = ctx.enqueue_create_host_buffer[DType.int64](QU_DIST_SEQ_LEN)
    for i in range(QU_DIST_SEQ_LEN):
        host_acc[i] = 0
        host_batch[i] = 0
    host_acc[10] = 3
    host_acc[20] = 5
    host_batch[10] = 2
    host_batch[20] = 1
    var dev_acc = ctx.enqueue_create_buffer[DType.int64](QU_DIST_SEQ_LEN)
    var dev_batch = ctx.enqueue_create_buffer[DType.int64](QU_DIST_SEQ_LEN)
    ctx.enqueue_copy(src_buf=host_acc, dst_buf=dev_acc)
    ctx.enqueue_copy(src_buf=host_batch, dst_buf=dev_batch)
    var kernel = ctx.compile_function[
        add_qu_dist_seq_kernel,
        add_qu_dist_seq_kernel,
    ]()
    ctx.enqueue_function(
        kernel,
        dev_batch,
        dev_acc,
        grid_dim=1,
        block_dim=QU_DIST_SEQ_LEN,
    )
    var host_out = ctx.enqueue_create_host_buffer[DType.int64](QU_DIST_SEQ_LEN)
    ctx.enqueue_copy(src_buf=dev_acc, dst_buf=host_out)
    ctx.synchronize()
    assert_equal(host_out[10], 5)
    assert_equal(host_out[20], 6)


fn test_add_qu_dist_kernel() raises:
    """Add_qu_dist_kernel: adds batch 2D histogram into accumulator."""
    @parameter
    if not has_accelerator():
        return
    var ctx = DeviceContext()
    var batch_max_length = 2
    var n = batch_max_length * NUM_QUAL_BINS
    var host_batch = ctx.enqueue_create_host_buffer[DType.int64](n)
    var host_acc = ctx.enqueue_create_host_buffer[DType.int64](n)
    for i in range(n):
        host_batch[i] = 0
        host_acc[i] = 0
    host_batch[0] = 1
    host_batch[NUM_QUAL_BINS] = 2
    host_acc[0] = 10
    host_acc[NUM_QUAL_BINS] = 20
    var dev_batch = ctx.enqueue_create_buffer[DType.int64](n)
    var dev_acc = ctx.enqueue_create_buffer[DType.int64](n)
    ctx.enqueue_copy(src_buf=host_batch, dst_buf=dev_batch)
    ctx.enqueue_copy(src_buf=host_acc, dst_buf=dev_acc)
    var kernel = ctx.compile_function[
        add_qu_dist_kernel,
        add_qu_dist_kernel,
    ]()
    ctx.enqueue_function(
        kernel,
        dev_batch,
        dev_acc,
        batch_max_length,
        grid_dim=(n + BLOCK_SIZE - 1) // BLOCK_SIZE,
        block_dim=BLOCK_SIZE,
    )
    var host_out = ctx.enqueue_create_host_buffer[DType.int64](n)
    ctx.enqueue_copy(src_buf=dev_acc, dst_buf=host_out)
    ctx.synchronize()
    assert_equal(host_out[0], 11)
    assert_equal(host_out[NUM_QUAL_BINS], 22)


fn test_record_metadata_kernel() raises:
    """Record_metadata_kernel: one block per record; outputs length and sum of qual."""
    @parameter
    if not has_accelerator():
        return
    var ctx = DeviceContext()
    # Two records: offsets [0, 3, 6], qual bytes [33, 34, 35, 40, 41, 42]
    var offsets = List[Int32](capacity=3)
    offsets.append(0)
    offsets.append(3)
    offsets.append(6)
    var qual = List[UInt8](capacity=6)
    qual.append(33)
    qual.append(34)
    qual.append(35)
    qual.append(40)
    qual.append(41)
    qual.append(42)
    var num_records = 2
    var host_offsets = ctx.enqueue_create_host_buffer[DType.int32](3)
    var host_qual = ctx.enqueue_create_host_buffer[DType.uint8](6)
    for i in range(3):
        host_offsets[i] = offsets[i]
    for i in range(6):
        host_qual[i] = qual[i]
    var dev_offsets = ctx.enqueue_create_buffer[DType.int32](3)
    var dev_qual = ctx.enqueue_create_buffer[DType.uint8](6)
    var dev_lengths = ctx.enqueue_create_buffer[DType.int32](num_records)
    var dev_sums = ctx.enqueue_create_buffer[DType.int64](num_records)
    ctx.enqueue_copy(src_buf=host_offsets, dst_buf=dev_offsets)
    ctx.enqueue_copy(src_buf=host_qual, dst_buf=dev_qual)
    var kernel = ctx.compile_function[
        record_metadata_kernel,
        record_metadata_kernel,
    ]()
    ctx.enqueue_function(
        kernel,
        dev_offsets,
        dev_qual,
        dev_lengths,
        dev_sums,
        num_records,
        grid_dim=num_records,
        block_dim=BLOCK_SIZE,
    )
    var host_lengths = ctx.enqueue_create_host_buffer[DType.int32](num_records)
    var host_sums = ctx.enqueue_create_host_buffer[DType.int64](num_records)
    ctx.enqueue_copy(src_buf=dev_lengths, dst_buf=host_lengths)
    ctx.enqueue_copy(src_buf=dev_sums, dst_buf=host_sums)
    ctx.synchronize()
    assert_equal(host_lengths[0], 3)
    assert_equal(host_lengths[1], 3)
    assert_equal(host_sums[0], 33 + 34 + 35)
    assert_equal(host_sums[1], 40 + 41 + 42)


fn test_min_max_qual_kernel() raises:
    """Min_max_qual_kernel: each block outputs min/max of its chunk; verify with one block."""
    @parameter
    if not has_accelerator():
        return
    var ctx = DeviceContext()
    var qual_bytes = List[UInt8](capacity=4)
    qual_bytes.append(100)
    qual_bytes.append(33)
    qual_bytes.append(200)
    qual_bytes.append(50)
    var seq_len = 4
    var num_blocks = (seq_len + BLOCK_SIZE - 1) // BLOCK_SIZE
    var host_qual = ctx.enqueue_create_host_buffer[DType.uint8](seq_len)
    for i in range(seq_len):
        host_qual[i] = qual_bytes[i]
    var dev_qual = ctx.enqueue_create_buffer[DType.uint8](seq_len)
    var dev_partial_mins = ctx.enqueue_create_buffer[DType.uint8](num_blocks)
    var dev_partial_maxs = ctx.enqueue_create_buffer[DType.uint8](num_blocks)
    ctx.enqueue_copy(src_buf=host_qual, dst_buf=dev_qual)
    var kernel = ctx.compile_function[
        min_max_qual_kernel,
        min_max_qual_kernel,
    ]()
    ctx.enqueue_function(
        kernel,
        dev_qual,
        seq_len,
        dev_partial_mins,
        dev_partial_maxs,
        grid_dim=num_blocks,
        block_dim=BLOCK_SIZE,
    )
    var host_mins = ctx.enqueue_create_host_buffer[DType.uint8](num_blocks)
    var host_maxs = ctx.enqueue_create_host_buffer[DType.uint8](num_blocks)
    ctx.enqueue_copy(src_buf=dev_partial_mins, dst_buf=host_mins)
    ctx.enqueue_copy(src_buf=dev_partial_maxs, dst_buf=host_maxs)
    ctx.synchronize()
    assert_equal(host_mins[0], 33)
    assert_equal(host_maxs[0], 200)


fn test_qu_dist_row_kernel() raises:
    """Qu_dist_row_kernel: one block per position; 2D histogram position x quality."""
    @parameter
    if not has_accelerator():
        return
    var ctx = DeviceContext()
    # One record with 2 quality bytes: [40, 50] -> position 0 has qual 40, position 1 has qual 50
    var offsets = List[Int32](capacity=2)
    offsets.append(0)
    offsets.append(2)
    var qual = List[UInt8](capacity=2)
    qual.append(40)
    qual.append(50)
    var num_records = 1
    var max_length = 2
    var host_offsets = ctx.enqueue_create_host_buffer[DType.int32](2)
    var host_qual = ctx.enqueue_create_host_buffer[DType.uint8](2)
    host_offsets[0] = 0
    host_offsets[1] = 2
    host_qual[0] = 40
    host_qual[1] = 50
    var dev_offsets = ctx.enqueue_create_buffer[DType.int32](2)
    var dev_qual = ctx.enqueue_create_buffer[DType.uint8](2)
    var qu_dist_size = max_length * NUM_QUAL_BINS
    var dev_qu_dist = ctx.enqueue_create_buffer[DType.int64](qu_dist_size)
    ctx.enqueue_copy(src_buf=host_offsets, dst_buf=dev_offsets)
    ctx.enqueue_copy(src_buf=host_qual, dst_buf=dev_qual)
    var kernel = ctx.compile_function[
        qu_dist_row_kernel,
        qu_dist_row_kernel,
    ]()
    ctx.enqueue_function(
        kernel,
        dev_qual,
        dev_offsets,
        dev_qu_dist,
        num_records,
        max_length,
        grid_dim=max_length,
        block_dim=BLOCK_SIZE,
    )
    var host_qu_dist = ctx.enqueue_create_host_buffer[DType.int64](qu_dist_size)
    ctx.enqueue_copy(src_buf=dev_qu_dist, dst_buf=host_qu_dist)
    ctx.synchronize()
    assert_equal(host_qu_dist[0 * NUM_QUAL_BINS + 40], 1)
    assert_equal(host_qu_dist[1 * NUM_QUAL_BINS + 50], 1)


fn test_qu_dist_seq_local_kernel() raises:
    """Qu_dist_seq_local_kernel: each block builds histogram of per-read average quality."""
    @parameter
    if not has_accelerator():
        return
    var ctx = DeviceContext()
    # Two records: length 2 sum 90 -> avg 45; length 2 sum 100 -> avg 50
    var num_records = 2
    var num_bins = 128
    var host_lengths = ctx.enqueue_create_host_buffer[DType.int32](num_records)
    var host_sums = ctx.enqueue_create_host_buffer[DType.int64](num_records)
    host_lengths[0] = 2
    host_lengths[1] = 2
    host_sums[0] = 90
    host_sums[1] = 100
    var dev_lengths = ctx.enqueue_create_buffer[DType.int32](num_records)
    var dev_sums = ctx.enqueue_create_buffer[DType.int64](num_records)
    var seq_blocks = (num_records + BLOCK_SIZE - 1) // BLOCK_SIZE
    var dev_block_hist = ctx.enqueue_create_buffer[DType.int64](
        seq_blocks * num_bins
    )
    ctx.enqueue_copy(src_buf=host_lengths, dst_buf=dev_lengths)
    ctx.enqueue_copy(src_buf=host_sums, dst_buf=dev_sums)
    var kernel = ctx.compile_function[
        qu_dist_seq_local_kernel,
        qu_dist_seq_local_kernel,
    ]()
    ctx.enqueue_function(
        kernel,
        dev_lengths,
        dev_sums,
        dev_block_hist,
        num_records,
        num_bins,
        grid_dim=seq_blocks,
        block_dim=BLOCK_SIZE,
    )
    var host_hist = ctx.enqueue_create_host_buffer[DType.int64](
        seq_blocks * num_bins
    )
    ctx.enqueue_copy(src_buf=dev_block_hist, dst_buf=host_hist)
    ctx.synchronize()
    assert_equal(host_hist[0 * num_bins + 45], 1)
    assert_equal(host_hist[0 * num_bins + 50], 1)


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
