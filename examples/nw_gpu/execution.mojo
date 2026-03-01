"""Execution layer for Needleman-Wunsch GPU alignment: batching, device setup, timing.

This module bridges main.mojo and kernels.mojo. It handles:
  - Synthetic batch generation: build in-memory FASTQ, parse into FastqBatches.
  - Reference setup: copy the reference string to a host buffer, then to device
    and pass as UnsafePointer to the NW kernel.
  - GPU run: compile the NW kernel, then for each batch upload sequences to
    device, allocate score and DP scratch buffers, launch one block per record,
    and copy scores back (timing includes all of this).
  - CPU run: iterate every record in every batch and call the reference NW
    implementation (same scoring as GPU); return total elapsed seconds.

Kernels (nw_kernel, needleman_wunsch_cpu) and shared constants live in kernels.mojo.
"""

from blazeseq import FastqParser, FastqBatch
from blazeseq.utils import generate_synthetic_fastq_buffer
from blazeseq.io.readers import MemoryReader, Reader
from gpu.host import DeviceContext
from gpu.host.device_context import DeviceBuffer, HostBuffer
from pathlib import Path
from time import perf_counter_ns

from examples.nw_gpu.kernels import (
    nw_kernel,
    needleman_wunsch_cpu,
    MAX_REF_LEN,
    ROW_STRIDE,
)

# Max records per FastqBatch when reading or generating.
comptime BATCH_SIZE: Int = 65536
# Fixed 20 bp reference used for all alignments in this example.
comptime REF_40BP: String = "ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT"


fn load_batches_synthetic(
    num_reads: Int, read_len: Int
) raises -> List[FastqBatch]:
    """Generate synthetic FASTQ (num_reads × read_len bp) and return list of batches.

    Uses BlazeSeq's generate_synthetic_fastq_buffer, then a MemoryReader and
    FastqParser to produce FastqBatches of size BATCH_SIZE.
    """
    var data = generate_synthetic_fastq_buffer(
        num_reads, read_len, read_len, 33, 73, "generic"
    )
    var reader = MemoryReader(data^)
    var parser = FastqParser[MemoryReader](reader^)
    var batches = List[FastqBatch]()
    while True:
        var batch = parser.next_batch(max_records=BATCH_SIZE)
        if batch.num_records() == 0:
            break
        batches.append(batch^)
    return batches^


fn total_record_count(batches: List[FastqBatch]) -> Int:
    """Total number of records across all batches."""
    var total: Int = 0
    for b in batches:
        total += b.num_records()
    return total


fn setup_reference(
    ctx: DeviceContext, ref_str: String
) raises -> Tuple[DeviceBuffer[DType.uint8], Int]:
    """Upload reference to device; return (ref_buffer, ref_len) for kernel calls.

    Copies ref_str into a host buffer of length MAX_REF_LEN (zero-padded),
    then copies to device. ref_len is the actual reference length used by the kernel.
    """
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
    return (ref_buffer, ref_len)


fn run_gpu_nw(
    batches: List[FastqBatch],
    ref_buffer: DeviceBuffer[DType.uint8],
    ref_len: Int,
    ctx: DeviceContext,
) raises -> Tuple[Float64, List[Int32]]:
    """Run NW kernel on all batches; return (elapsed seconds, list of scores per record).

    Compiles nw_kernel once, then for each batch: uploads batch to device,
    allocates scores buffer and row_scratch, launches kernel, copies scores
    back to host and appends them to the returned list (for CPU/GPU validation).
    """
    var nw_compiled = ctx.compile_function[nw_kernel, nw_kernel]()
    var start_ns = perf_counter_ns()
    var all_scores = List[Int32]()
    for batch in batches:
        var num_records = batch.num_records()
        if num_records == 0:
            continue
        var device_batch = batch.to_device(ctx)
        var scores_buffer = ctx.enqueue_create_buffer[DType.int32](num_records)
        var scratch_size = num_records * ROW_STRIDE
        var row_scratch = ctx.enqueue_create_buffer[DType.int32](scratch_size)
        ctx.synchronize()
        ctx.enqueue_function(
            nw_compiled,
            ref_buffer,
            ref_len,
            device_batch.sequence_buffer,
            device_batch.ends,
            num_records,
            scores_buffer,
            row_scratch,
            grid_dim=num_records,
            block_dim=1,
        )
        var host_scores = ctx.enqueue_create_host_buffer[DType.int32](
            num_records
        )
        ctx.enqueue_copy(src_buf=scores_buffer, dst_buf=host_scores)
        ctx.synchronize()
        for i in range(num_records):
            all_scores.append(host_scores[i])
    var end_ns = perf_counter_ns()
    return (Float64(end_ns - start_ns) / 1e9, all_scores^)


fn run_cpu_nw(
    batches: List[FastqBatch], ref_str: String
) raises -> Tuple[Float64, List[Int32]]:
    var start_ns = perf_counter_ns()
    var all_scores = List[Int32]()
    for batch in batches:
        var n = batch.num_records()
        for i in range(n):
            var rec = batch.get_ref(i)  # ← zero-copy, no String allocation
            var score = needleman_wunsch_cpu(
                reference=ref_str,
                query_bytes=rec.sequence,  # ← raw Span[Byte], exact length
            )
            all_scores.append(score)
    var end_ns = perf_counter_ns()
    return (Float64(end_ns - start_ns) / 1e9, all_scores^)


fn scores_match(
    gpu_scores: List[Int32], cpu_scores: List[Int32]
) -> Tuple[Bool, Int]:
    """Return (True, -1) if lists are equal; (False, -1) if length mismatch; else (False, first mismatch index).
    """
    if len(gpu_scores) != len(cpu_scores):
        return (False, -1)
    for i in range(len(gpu_scores)):
        if gpu_scores[i] != cpu_scores[i]:
            return (False, i)
    return (True, -1)
