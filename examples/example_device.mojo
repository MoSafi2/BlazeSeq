"""Example: GPU Needleman-Wunsch global alignment on FastqBatch.

This example demonstrates:
1. Loading a FastqBatch (from file or synthetic records).
2. Uploading the batch and a reference sequence to the GPU.
3. Running a Needleman-Wunsch alignment kernel (one block per record).
4. Copying alignment scores back and printing a summary.

Usage:
    pixi run mojo run examples/example_device.mojo [path/to/file.fastq]

Without a file path, a small synthetic batch is used so the example runs without input.
Requires a compatible GPU (NVIDIA, AMD, or Apple).
"""

from blazeseq import FastqParser, FastqRecord, FileReader, FastqBatch, upload_batch_to_device
from blazeseq.quality_schema import generic_schema
from blazeseq.device_record import DeviceFastqBatch
from gpu.host import DeviceContext
from gpu.host.device_context import DeviceBuffer, HostBuffer
from gpu import block_idx
from sys import has_accelerator, argv, exit
from pathlib import Path
from memory import UnsafePointer
# Max reference and query length for the NW kernel (avoids dynamic alloc on device).
comptime MAX_REF_LEN: Int = 256
comptime MAX_QUERY_LEN: Int = 256
# Two rows of (MAX_REF_LEN+1) Int32 per record for DP.
comptime ROW_STRIDE: Int = 2 * (MAX_REF_LEN + 1)


fn nw_kernel(
    ref_ptr: UnsafePointer[UInt8, MutAnyOrigin],
    ref_len: Int,
    seq_ptr: UnsafePointer[UInt8, MutAnyOrigin],
    qual_ends: UnsafePointer[Int64, MutAnyOrigin],
    num_records: Int,
    scores: UnsafePointer[Int32, MutAnyOrigin],
    row_scratch: UnsafePointer[Int32, MutAnyOrigin],
) -> None:
    """Needleman-Wunsch global alignment: one block per record. Writes score to scores[block_idx]."""
    var rec_idx = Int(block_idx.x)
    if rec_idx >= num_records:
        return

    # Query segment for this record: [q_start, q_end) in seq_ptr
    var q_start: Int = 0
    if rec_idx > 0:
        q_start = Int(qual_ends[rec_idx - 1])
    var q_end = Int(qual_ends[rec_idx])
    var query_len = q_end - q_start
    if query_len > MAX_QUERY_LEN or ref_len > MAX_REF_LEN:
        scores[rec_idx] = 0
        return

    # Pointers to our two rows in scratch (each length ref_len+1)
    var scratch_base = row_scratch + rec_idx * ROW_STRIDE
    var dp_prev = scratch_base
    var dp_curr = scratch_base + (MAX_REF_LEN + 1)

    # Scoring: match +1, mismatch -1, gap -1
    var match_score: Int32 = 1
    var mismatch_score: Int32 = -1
    var gap_score: Int32 = -1

    # Initialize first row: F(0, j) = j * gap
    for i in range(ref_len + 1):
        dp_prev.store(i, gap_score * Int32(i))

    # Iterate over query positions (rows of the DP matrix)
    for j in range(1, query_len + 1):
        dp_curr.store(0, gap_score * Int32(j))
        for i in range(1, ref_len + 1):
            var im1 = i - 1
            var diag = (dp_prev.load(im1))[0]
            if (ref_ptr + im1)[] == (seq_ptr + q_start + j - 1)[]:
                diag += match_score
            else:
                diag += mismatch_score
            var del_score = dp_prev.load(i)[0] + gap_score
            var ins_score = dp_curr.load(im1)[0] + gap_score
            var best = diag
            if del_score > best:
                best = del_score
            if ins_score > best:
                best = ins_score
            dp_curr.store(i, best)
        # Swap row pointers
        var tmp = dp_prev
        dp_prev = dp_curr
        dp_curr = tmp

    scores[rec_idx] = dp_prev.load(ref_len)[0]


fn needleman_wunsch_cpu(reference: String, query: String) -> Int32:
    """Host-side NW for verification. Same scoring: match +1, mismatch -1, gap -1."""
    var r_len = len(reference)
    var q_len = len(query)
    if r_len == 0 or q_len == 0:
        return 0
    var match_score: Int32 = 1
    var mismatch_score: Int32 = -1
    var gap_score: Int32 = -1
    # Two-row DP
    var dp_prev = List[Int32](capacity=r_len + 1)
    var dp_curr = List[Int32](capacity=r_len + 1)
    for i in range(r_len + 1):
        dp_prev.append(gap_score * Int32(i))
    for _ in range(r_len + 1):
        dp_curr.append(Int32(0))

    for j in range(1, q_len + 1):
        dp_curr[0] = gap_score * Int32(j)
        for i in range(1, r_len + 1):
            var im1 = i - 1
            var jm1 = j - 1
            var diag: Int32 = dp_prev[im1]
            var ref_byte = Int(reference.as_bytes()[im1])
            var q_byte = Int(query.as_bytes()[jm1])
            if ref_byte == q_byte:
                diag += match_score
            else:
                diag += mismatch_score
            var del_score: Int32 = dp_prev[i] + gap_score
            var ins_score: Int32 = dp_curr[im1] + gap_score
            var best = diag
            if del_score > best:
                best = del_score
            if ins_score > best:
                best = ins_score
            dp_curr[i] = best
        if j == q_len:
            return dp_curr[r_len]
        var tmp = dp_prev.copy()
        dp_prev = dp_curr.copy()
        dp_curr = tmp.copy()

    return dp_prev[r_len]


fn make_synthetic_batch() raises -> FastqBatch:
    """Build a small synthetic FastqBatch for running without a FASTQ file."""
    var records = List[FastqRecord]()
    records.append(
        FastqRecord("@syn_1", "ACGTACGT", "IIIIIIII", generic_schema)
    )
    records.append(
        FastqRecord("@syn_2", "ACGTACGTACGT", "IIIIIIIIIIII", generic_schema)
    )
    records.append(
        FastqRecord("@syn_3", "ACGT", "IIII", generic_schema)
    )
    return FastqBatch(records=records)


fn main() raises:
    @parameter
    if not has_accelerator():
        print("No GPU detected. This example requires a compatible GPU.")
        exit(1)

    var args = argv()
    var batch: FastqBatch
    var ref_str = "ACGTACGT"
    if len(args) >= 2:
        var file_path = args[1]
        var parser = FastqParser[FileReader](FileReader(Path(file_path)), "generic")
        batch = parser.next_batch(max_records=1024)
        if batch.num_records() == 0:
            print("File produced no records; using synthetic batch.")
            batch = make_synthetic_batch()
    else:
        print("No file path given; using synthetic batch.")
        batch = make_synthetic_batch()

    var num_records = batch.num_records()
    print("Batch records:", num_records)
    print("Reference length:", len(ref_str))

    var ctx = DeviceContext()
    var device_batch = batch.upload_to_device(ctx)

    # Upload reference
    var ref_len = len(ref_str)
    var ref_host = ctx.enqueue_create_host_buffer[DType.uint8](ref_len)
    ctx.synchronize()
    var ref_bytes = ref_str.as_bytes()
    for i in range(ref_len):
        ref_host[i] = ref_bytes[i]
    var ref_buffer = ctx.enqueue_create_buffer[DType.uint8](ref_len)
    ctx.enqueue_copy(src_buf=ref_host, dst_buf=ref_buffer)
    ctx.synchronize()

    # Output scores
    var scores_buffer = ctx.enqueue_create_buffer[DType.int32](num_records)
    var scratch_size = num_records * ROW_STRIDE
    var row_scratch = ctx.enqueue_create_buffer[DType.int32](scratch_size)
    ctx.synchronize()

    if num_records > 0:
        var nw_compiled = ctx.compile_function[nw_kernel, nw_kernel]()
        ctx.enqueue_function(
            nw_compiled,
            ref_buffer,
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

    print("Needleman-Wunsch alignment scores (GPU):")
    var first = min(5, num_records)
    for i in range(first):
        print("  record ", i, " score ", host_scores[i])
    if num_records > 5:
        print("  ...")

    var min_s = host_scores[0]
    var max_s = host_scores[0]
    var sum_s: Int64 = 0
    for i in range(num_records):
        var s = host_scores[i]
        if s < min_s:
            min_s = s
        if s > max_s:
            max_s = s
        sum_s += Int64(s)
    var mean_s = Float64(sum_s) / Float64(num_records)
    print("Min:", min_s, " Max:", max_s, " Mean:", mean_s)

    # Optional CPU verification for first record
    var rec0 = batch.get_record(0)
    var query0 = String(rec0.sequence_slice())
    var cpu_score = needleman_wunsch_cpu(reference=ref_str, query=query0)
    var gpu_score = host_scores[0]
    print("CPU verification (record 0): CPU score ", cpu_score, ", GPU score ", gpu_score)

