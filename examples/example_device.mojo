"""Example: GPU quality prefix-sum for multiple FastqRecords.

Prefix sum is per record only: each read's quality string has its own prefix
sum (starting at 0 for that read). No running prefix sum across all reads.

This example demonstrates:
1. Creating 10M FastqRecord instances and one FastqBatch
2. Processing in subbatches (128k-256k) with double-buffering
3. Overlapping CPU fill of next subbatch with GPU upload/kernel/download
4. Aggregating per-record prefix-sum results and verifying against CPU reference
5. CPU streaming: 256k mini-batches copied from sink then processed
"""

from blazeseq import (
    FastqRecord,
    FastqBatch,
    fill_subbatch_host_buffers,
    upload_subbatch_from_host_buffers,
)
from blazeseq.kernels.prefix_sum import enqueue_quality_prefix_sum
from gpu.host import DeviceContext, HostBuffer
from sys import has_accelerator, exit
import random
from collections.string import chr, String
from time import perf_counter_ns as now
from memory import UnsafePointer

# 10M reads, subbatch 256k (configurable in 128k-256k range)
comptime NUM_RECORDS = 3_000_000
comptime READ_LENGTH = 85
comptime SUBBATCH_SIZE = 32_000


# ---------------------------------------------------------------------------
# Result types for GPU/CPU pipeline (keeps main free of logic)
# ---------------------------------------------------------------------------


struct GpuPrefixSumResult:
    """Aggregated per-record quality prefix sums from GPU and timing."""

    var prefix_sums: List[Int32]
    var total_qual: Int
    var time_seconds: Float64

    fn __init__(
        out self,
        var prefix_sums: List[Int32],
        total_qual: Int,
        time_seconds: Float64,
    ):
        self.prefix_sums = prefix_sums^
        self.total_qual = total_qual
        self.time_seconds = time_seconds


struct CpuPrefixSumResult:
    """Per-record quality prefix sums from CPU reference and timing."""

    var prefix_sums: List[Int32]
    var time_seconds: Float64

    fn __init__(out self, var prefix_sums: List[Int32], time_seconds: Float64):
        self.prefix_sums = prefix_sums^
        self.time_seconds = time_seconds


fn generate_random_fastq_record(
    record_id: Int, length: Int
) raises -> FastqRecord[val=True]:
    """
    Generate a random FastqRecord with specified length and high quality scores.
    Uses high quality characters (Q40-Q41, ASCII 73-74) for quality string.
    """
    var DNA_BASES = ["A", "T", "G", "C"]
    var seq = String(capacity=length)
    var qual = String(capacity=length)

    # High quality: Q40-Q41 corresponds to ASCII 73-74 (Sanger/Illumina 1.8+ offset 33)
    # Using range 73-74 for very high quality
    var qual_low = 60
    var qual_high = 74

    for _ in range(length + random.random_si64(min=-5, max=5)):
        # Random DNA base
        var base_idx = random.random_si64(min=0, max=3)
        seq += DNA_BASES[base_idx]

        # Random high quality score
        var qual_char = Int(random.random_si64(min=qual_low, max=qual_high))
        qual += chr(qual_char)

    var header = "@read_" + String(record_id)
    return FastqRecord(header, seq, "+", qual)


def cpu_quality_prefix_sum(
    batch: FastqBatch,
    records: List[FastqRecord[val=True]],
) -> List[Int32]:
    """
    CPU implementation of quality prefix sum (per record only).
    For each record, computes prefix sum of (quality_byte - offset) over that
    record's quality string only; s is reset to 0 at the start of each record.
    No running prefix sum across reads. Returns a list of Int32 of length
    total_quality_len (concatenated per-record prefix sums).
    """
    var total_qual = batch.total_quality_len()
    var num_records = batch.num_records()
    var quality_offset = batch.quality_offset()
    var result = List[Int32](capacity=total_qual)

    for i in range(num_records):
        var qual_start = 0 if i == 0 else batch._qual_ends[i - 1]
        var qual_end = batch._qual_ends[i]
        var qual_len = qual_end - qual_start

        var s: Int32 = 0
        for j in range(qual_len):
            var qual_byte = batch._quality_bytes[qual_start + j]
            s += Int32(qual_byte) - Int32(quality_offset)
            result.append(s)

    return result^


fn copy_batch_from_sink(
    source_records: List[FastqRecord[val=True]],
    start_idx: Int,
    end_idx: Int,
) -> List[FastqRecord[val=True]]:
    """
    Simulate copying a batch of records from a sink (file/network stream).
    This represents the realistic scenario where records are read in batches.
    Returns a copied list of records for the specified range.
    """
    var batch_size = end_idx - start_idx
    var batch_records = List[FastqRecord[val=True]](capacity=batch_size)
    for i in range(start_idx, end_idx):
        # Copy the record (simulating read/copy from sink)
        var copied_record = source_records[i].copy()
        batch_records.append(copied_record^)
    return batch_records^


fn run_gpu_prefix_sum(
    batch: FastqBatch,
    num_records: Int,
    subbatch_size: Int,
) raises -> GpuPrefixSumResult:
    """
    Run quality prefix-sum on GPU in subbatches with double-buffered host
    buffers and overlap of CPU fill with GPU upload/kernel/download.
    Returns aggregated per-record prefix sums (as list) and elapsed time.
    """
    var max_subbatch_qual = subbatch_size * 160
    var max_subbatch_n = subbatch_size
    var ctx = DeviceContext()

    # Create double-buffered host buffers
    var host_qual = InlineArray[HostBuffer[DType.uint8], 2](
        ctx.enqueue_create_host_buffer[DType.uint8](max_subbatch_qual),
        ctx.enqueue_create_host_buffer[DType.uint8](max_subbatch_qual),
    )
    var host_offs = InlineArray[HostBuffer[DType.int32], 2](
        ctx.enqueue_create_host_buffer[DType.int32](max_subbatch_n + 1),
        ctx.enqueue_create_host_buffer[DType.int32](max_subbatch_n + 1),
    )

    var total_qual = batch.total_quality_len()
    var aggregated = ctx.enqueue_create_host_buffer[DType.int32](total_qual)
    var num_subbatches = (num_records + subbatch_size - 1) // subbatch_size

    var gpu_start = now()
    ctx.synchronize()

    # Track previous iteration's output for async copy-back
    var last_host_out: Optional[HostBuffer[DType.int32]] = None
    var last_qual_start: Int = 0
    var last_len: Int = 0

    for i in range(num_subbatches):
        # Calculate slice boundaries
        var start_rec = i * subbatch_size
        var end_rec = min((i + 1) * subbatch_size, num_records)
        var qual_start = 0 if start_rec == 0 else Int(
            batch._qual_ends[start_rec - 1]
        )
        var qual_end = Int(batch._qual_ends[end_rec - 1])
        var total_qual_slice = qual_end - qual_start
        var n_slice = end_rec - start_rec

        # Copy back previous results while processing current
        if last_host_out:
            ctx.synchronize()
            for j in range(last_len):
                aggregated[last_qual_start + j] = last_host_out.value()[j]

        # Use double-buffering
        var slot = i & 1  # Faster than modulo

        # Fill, upload, and process current subbatch
        fill_subbatch_host_buffers(
            batch, start_rec, end_rec, host_qual[slot], host_offs[slot]
        )

        var on_device = upload_subbatch_from_host_buffers(
            host_qual[slot],
            host_offs[slot],
            n_slice,
            total_qual_slice,
            batch.quality_offset(),
            ctx,
        )

        var out_buf = enqueue_quality_prefix_sum(on_device, ctx)
        var host_out = ctx.enqueue_create_host_buffer[DType.int32](
            total_qual_slice
        )
        ctx.enqueue_copy(src_buf=out_buf, dst_buf=host_out)

        # Prefetch next subbatch (overlap with GPU work)
        if i + 1 < num_subbatches:
            var next_start = (i + 1) * subbatch_size
            var next_end = min((i + 2) * subbatch_size, num_records)
            var next_slot = (i + 1) & 1
            fill_subbatch_host_buffers(
                batch,
                next_start,
                next_end,
                host_qual[next_slot],
                host_offs[next_slot],
            )

        # Update tracking variables
        last_host_out = host_out
        last_qual_start = qual_start
        last_len = total_qual_slice

    # Copy back final results
    if last_host_out:
        ctx.synchronize()
        for j in range(last_len):
            aggregated[last_qual_start + j] = last_host_out.value()[j]

    var time_seconds = Float64(now() - gpu_start) / 1e9

    # Directly construct result from aggregated buffer
    var prefix_sums = List[Int32](capacity=total_qual)
    for idx in range(total_qual):
        prefix_sums.append(aggregated[idx])

    return GpuPrefixSumResult(prefix_sums^, total_qual, time_seconds)


def run_cpu_prefix_sum(
    records: List[FastqRecord[val=True]],
    batch: FastqBatch,
    subbatch_size: Int,
) -> CpuPrefixSumResult:
    """
    Run CPU reference quality prefix-sum in streaming mini-batches (copy from
    sink per batch), matching GPU's per-subbatch prefix sums. Returns
    concatenated prefix sums and elapsed time.
    """
    var total_qual = batch.total_quality_len()
    var num_records = len(records)
    var num_cpu_batches = (num_records + subbatch_size - 1) // subbatch_size
    var cpu_start = now()

    var cpu_result = List[Int32](capacity=total_qual)
    for batch_idx in range(num_cpu_batches):
        var start_rec = batch_idx * subbatch_size
        var end_rec = min((batch_idx + 1) * subbatch_size, num_records)
        var batch_records = copy_batch_from_sink(records, start_rec, end_rec)
        var mini_batch = FastqBatch()
        for i in range(len(batch_records)):
            mini_batch.add(batch_records[i])
        var batch_result = cpu_quality_prefix_sum(mini_batch, batch_records)
        for i in range(len(batch_result)):
            cpu_result.append(batch_result[i])

    var cpu_end = now()
    var time_seconds = Float64(cpu_end - cpu_start) / 1e9
    return CpuPrefixSumResult(cpu_result^, time_seconds)


fn main() raises:
    """
    Entry point: GPU check, data setup, run GPU/CPU pipelines, then only
    logging (step messages, verification, benchmark summary).
    """

    @parameter
    if not has_accelerator():
        print("No GPU accelerator detected. This example requires a GPU.")
        exit(1)

    var num_records = NUM_RECORDS
    var read_length = READ_LENGTH
    var subbatch_size = SUBBATCH_SIZE

    print(
        "=" * 60,
        "\nGPU Quality Prefix-Sum Example (10M reads, subbatch overlap)\n",
        "=" * 60,
        "\n",
    )

    print(
        "Step 1: Generating " + String(num_records) + " random FastqRecords..."
    )
    random.seed(42)
    var records = List[FastqRecord[val=True]](capacity=num_records)
    for i in range(num_records):
        var record = generate_random_fastq_record(i + 1, read_length)
        records.append(record^)
    print("  Created " + String(len(records)) + " records")

    print("Step 2: Building FastqBatch...")
    var batch = FastqBatch()
    for i in range(len(records)):
        batch.add(records[i])
    print("  Total records:        " + String(batch.num_records()))
    print("  Total quality length: " + String(batch.total_quality_len()))
    print("  Quality offset:       " + String(batch.quality_offset()))
    print()

    var num_subbatches = (num_records + subbatch_size - 1) // subbatch_size
    print(
        "Step 3: Running GPU pipeline (allocation + prefix-sum in "
        + String(num_subbatches)
        + " subbatches, overlap fill)..."
    )
    var gpu_result = run_gpu_prefix_sum(batch, num_records, subbatch_size)
    print("  Allocated 2x input slots and 1 aggregated result buffer")
    print(
        "  GPU pipeline completed in "
        + String(gpu_result.time_seconds)
        + " seconds"
    )
    print()

    print(
        "Step 4: Running CPU prefix-sum with streaming batches (256k per"
        " batch)..."
    )
    var cpu_result = run_cpu_prefix_sum(records, batch, subbatch_size)
    print(
        "  CPU time (streaming "
        + String(num_subbatches)
        + " batches): "
        + String(cpu_result.time_seconds)
        + " seconds"
    )

    print("Step 5: Verification (GPU vs CPU):")
    print("-" * 60)
    var total_qual = gpu_result.total_qual
    var check_limit = min(total_qual, len(cpu_result.prefix_sums))
    var all_match = True
    var mismatch_count = 0
    for idx in range(check_limit):
        if gpu_result.prefix_sums[idx] != cpu_result.prefix_sums[idx]:
            all_match = False
            mismatch_count += 1
    if all_match:
        print("  All prefix sums match between GPU and CPU!")
    else:
        print(
            "  Found "
            + String(mismatch_count)
            + " mismatches between GPU and CPU"
        )

    print()
    print("Step 6: Benchmark:")
    print("-" * 60)
    print("  GPU total time:   " + String(gpu_result.time_seconds) + " seconds")
    print("  CPU time:         " + String(cpu_result.time_seconds) + " seconds")
    if cpu_result.time_seconds > 0:
        var speedup = cpu_result.time_seconds / gpu_result.time_seconds
        print("  Speedup (CPU/GPU): " + String(speedup) + "x")
    print("=" * 60)
    print("Example completed successfully!")
    print("=" * 60)
