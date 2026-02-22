"""Execution layer for device_nw: batch loading, GPU/CPU run loops, timing.

Kernels are in kernels.mojo. This module provides:
- load_batches_from_file, load_batches_synthetic
- setup_reference
- run_gpu_nw, run_cpu_nw
- total_record_count
"""

from blazeseq import FastqParser, FileReader, FastqBatch
from blazeseq.utils import generate_synthetic_fastq_buffer
from blazeseq.io.readers import MemoryReader, Reader
from gpu.host import DeviceContext
from gpu.host.device_context import DeviceBuffer, HostBuffer
from pathlib import Path
from layout import Layout, LayoutTensor
from time import perf_counter_ns

from kernels import (
    nw_kernel,
    needleman_wunsch_cpu,
    MAX_REF_LEN,
    ROW_STRIDE,
    REF_LAYOUT,
)

comptime BATCH_SIZE: Int = 65536
comptime REF_20BP: String = "ACGTACGTACGTACGTACGT"


fn collect_batches[R: Reader](mut parser: FastqParser[R]) raises -> List[FastqBatch]:
    """Consume parser and return a list of batches (each up to BATCH_SIZE records)."""
    var batches = List[FastqBatch]()
    while True:
        var batch = parser.next_batch(max_records=BATCH_SIZE)
        if batch.num_records() == 0:
            break
        batches.append(batch^)
    return batches^


fn load_batches_from_file(path: Path) raises -> List[FastqBatch]:
    """Read whole file into a list of FastqBatches."""
    var parser = FastqParser[FileReader](FileReader(path), "generic")
    return collect_batches(parser)


fn load_batches_synthetic(num_reads: Int, read_len: Int) raises -> List[FastqBatch]:
    """Generate synthetic FASTQ and return list of batches."""
    var data = generate_synthetic_fastq_buffer(
        num_reads, read_len, read_len, 33, 73, "generic"
    )
    var reader = MemoryReader(data^)
    var parser = FastqParser[MemoryReader](reader^)
    return collect_batches(parser)


fn total_record_count(batches: List[FastqBatch]) -> Int:
    """Total number of records across all batches."""
    var total: Int = 0
    for b in batches:
        total += b.num_records()
    return total


fn setup_reference(
    ctx: DeviceContext, ref_str: String
) raises -> Tuple[
    LayoutTensor[DType.uint8, REF_LAYOUT, MutAnyOrigin], Int
]:
    """Upload reference to device; return (ref_tensor, ref_len) for kernel calls."""
    var ref_len = len(ref_str)
    var ref_host = ctx.enqueue_create_host_buffer[DType.uint8](MAX_REF_LEN)
    ctx.synchronize()
    var ref_bytes = ref_str.as_bytes()
    for i in range(ref_len):
        ref_host[i] = ref_bytes[i]
    for i in range(ref_len, MAX_REF_LEN):
        ref_host[i] = 0
    var ref_buffer = ctx.enqueue_create_buffer[DType.uint8](MAX_REF_LEN)
    ctx.enqueue_copy(src_buf=ref_host, dst_buf=ref_buffer)
    ctx.synchronize()
    var ref_tensor = LayoutTensor[DType.uint8, REF_LAYOUT](ref_buffer)
    return (ref_tensor.as_any_origin(), ref_len)


fn run_gpu_nw(
    batches: List[FastqBatch],
    ref_tensor: LayoutTensor[DType.uint8, REF_LAYOUT, MutAnyOrigin],
    ref_len: Int,
    ctx: DeviceContext,
) raises -> Float64:
    """Run NW kernel on all batches; return elapsed time in seconds."""
    var nw_compiled = ctx.compile_function[nw_kernel, nw_kernel]()
    var start_ns = perf_counter_ns()
    for batch in batches:
        var num_records = batch.num_records()
        if num_records == 0:
            continue
        var device_batch = batch.upload_to_device(ctx)
        var scores_buffer = ctx.enqueue_create_buffer[DType.int32](num_records)
        var scratch_size = num_records * ROW_STRIDE
        var row_scratch = ctx.enqueue_create_buffer[DType.int32](scratch_size)
        ctx.synchronize()
        ctx.enqueue_function(
            nw_compiled,
            ref_tensor,
            ref_len,
            device_batch.sequence_buffer,
            device_batch.qual_ends,
            num_records,
            scores_buffer,
            row_scratch,
            grid_dim=num_records,
            block_dim=1,
        )
        var host_scores = ctx.enqueue_create_host_buffer[DType.int32](num_records)
        ctx.enqueue_copy(src_buf=scores_buffer, dst_buf=host_scores)
    ctx.synchronize()
    var end_ns = perf_counter_ns()
    return Float64(end_ns - start_ns) / 1e9


fn run_cpu_nw(batches: List[FastqBatch], ref_str: String) raises -> Float64:
    """Run CPU NW on all records; return elapsed time in seconds."""
    var start_ns = perf_counter_ns()
    for batch in batches:
        var n = batch.num_records()
        for i in range(n):
            var rec = batch.get_record(i)
            var query = String(rec.sequence_slice())
            _ = needleman_wunsch_cpu(reference=ref_str, query=query)
    var end_ns = perf_counter_ns()
    return Float64(end_ns - start_ns) / 1e9
