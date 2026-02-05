"""Example: GPU quality prefix-sum for multiple FastqRecords.

This example demonstrates:
1. Creating multiple FastqRecord instances
2. Building a FastqBatch to stack records
3. Uploading the batch to GPU device memory
4. Running the quality prefix-sum kernel in parallel
5. Copying results back and displaying them
"""

from blazeseq import (
    FastqRecord,
    FastqBatch,
    upload_batch_to_device,
    enqueue_quality_prefix_sum,
)
from gpu.host import DeviceContext
from sys import has_accelerator, exit
import random
from collections.string import chr, String
from time import perf_counter_ns as now
from memory import UnsafePointer


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
    CPU implementation of quality prefix sum.
    Computes prefix sum of (quality_byte - offset) for all records sequentially.
    Returns a list of Int32 prefix sums with length = total_quality_len.
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


def main():
    @parameter
    if not has_accelerator():
        print("No GPU accelerator detected. This example requires a GPU.")
        exit(1)

    print("=" * 60, "\nGPU Quality Prefix-Sum Example\n", "=" * 60, "\n")

    # Step 1: Generate 100 random FastqRecords with 150 bp and high quality
    var num_records = 512_000
    var read_length = 150
    var records = List[FastqRecord[val=True]](capacity=num_records)
    print("Step 1: Generating", num_records, "random FastqRecords...")

    random.seed(42)

    for i in range(num_records):
        var record = generate_random_fastq_record(i + 1, read_length)
        records.append(record^)

    print("  Created " + String(len(records)) + " records")

    # Step 2: Build a FastqBatch
    print("Step 2: Building FastqBatch...")
    var batch = FastqBatch()
    for i in range(len(records)):
        batch.add(records[i])
    print("  Total records:        " + String(batch.num_records()))
    print("  Total quality length: " + String(batch.total_quality_len()))
    print("  Quality offset:       " + String(batch.quality_offset()))
    print()

    # Step 3: Initialize GPU context and upload to device
    print("Step 3: Uploading batch to GPU...")
    var ctx = DeviceContext()
    var gpu_start = now()
    var on_device = upload_batch_to_device(batch, ctx)
    var gpu_upload_time = now()
    var gpu_upload = Float64(gpu_upload_time - gpu_start) / 1e9

    print("  Uploaded " + String(on_device.num_records) + " records")
    print(
        "  Total quality bytes on device: "
        + String(on_device.total_quality_len)
    )

    # Step 4: Run the prefix-sum kernel (GPU)
    print("Step 4: Running quality prefix-sum kernel (GPU)...")
    var prefix_sum_output = enqueue_quality_prefix_sum(on_device, ctx)
    ctx.synchronize()
    var gpu_end = now()
    var gpu_time_seconds = Float64(gpu_end - gpu_upload_time) / Float64(1e9)

    # Step 5: Copy results back to host
    print("Step 5: Copying prefix-sum results back to host...")
    var copy_start = now()
    var host_output = ctx.enqueue_create_host_buffer[DType.int32](
        on_device.total_quality_len
    )
    ctx.enqueue_copy(src_buf=prefix_sum_output, dst_buf=host_output)
    ctx.synchronize()
    var copy_end = now()
    var copy_time_seconds = Float64(copy_end - copy_start) / Float64(1e9)
    var total_gpu_time = Float64(copy_end - gpu_start) / 1e9

    # Step 5b: Run CPU prefix-sum for comparison
    print("Step 5b: Running CPU prefix-sum...")
    var cpu_start = now()
    var cpu_result = cpu_quality_prefix_sum(batch, records)
    var cpu_end = now()
    var cpu_time_seconds = Float64(cpu_end - cpu_start) / 1e9
    print("  CPU computation completed")
    print("  CPU time: " + String(cpu_time_seconds) + " seconds")

    # Step 5c: Benchmark comparison
    print("Step 5c: Benchmark Comparison:")
    print("-" * 60)
    print("  GPU upload time:      " + String(gpu_upload) + " seconds")
    print("  GPU compute time:     " + String(gpu_time_seconds) + " seconds")
    print("  GPU copy time:        " + String(copy_time_seconds) + " seconds")
    print("  GPU total time:       " + String(total_gpu_time) + " seconds")
    print("  CPU time:             " + String(cpu_time_seconds) + " seconds")
    if cpu_time_seconds > 0:
        var speedup = cpu_time_seconds / total_gpu_time
        print("  Speedup (CPU/GPU):    " + String(speedup) + "x")

    # Step 7: Verify GPU results with CPU reference computation
    print("Step 7: Verification (GPU vs CPU):")
    print("-" * 60)
    var all_match = True
    var mismatch_count = 0
    for i in range(min(on_device.num_records, len(cpu_result))):
        var qual_start_int32 = Int32(0) if i == 0 else batch._qual_ends[i - 1]
        var qual_end_int32 = batch._qual_ends[i]
        var qual_start = Int(qual_start_int32)
        var qual_end = Int(qual_end_int32)
        var qual_len = qual_end - qual_start

        for j in range(qual_len):
            var gpu_val = host_output[qual_start + j]
            var cpu_val = cpu_result[qual_start + j]
            if gpu_val != cpu_val:
                all_match = False
                mismatch_count += 1
    print()
    if all_match:
        print("✓ All prefix sums match between GPU and CPU!")
    else:
        print(
            "✗ Found "
            + String(mismatch_count)
            + " mismatches between GPU and CPU"
        )

    print("=" * 60)
    print("Example completed successfully!")
    print("=" * 60)
