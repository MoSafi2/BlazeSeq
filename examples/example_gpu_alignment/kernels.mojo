"""GPU and CPU Needleman-Wunsch kernels for device_nw example.

Defines the NW alignment kernel (device), mismatch-count kernel (device),
and CPU reference implementation. Shared constants for max lengths and layout.
"""

from gpu import block_idx
from memory import UnsafePointer
from layout import Layout, LayoutTensor

# Max reference and query length for the NW kernel (avoids dynamic alloc on device).
comptime MAX_REF_LEN: Int = 256
comptime MAX_QUERY_LEN: Int = 256
# Two rows of (MAX_REF_LEN+1) Int32 per record for DP.
comptime ROW_STRIDE: Int = 2 * (MAX_REF_LEN + 1)

# Static 1D layout for reference on device (used with LayoutTensor).
comptime REF_LAYOUT = Layout.row_major(MAX_REF_LEN)


fn nw_kernel(
    ref_tensor: LayoutTensor[DType.uint8, REF_LAYOUT, MutAnyOrigin],
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

    var q_start: Int = 0
    if rec_idx > 0:
        q_start = Int(qual_ends[rec_idx - 1])
    var q_end = Int(qual_ends[rec_idx])
    var query_len = q_end - q_start
    if query_len > MAX_QUERY_LEN or ref_len > MAX_REF_LEN:
        scores[rec_idx] = 0
        return

    var scratch_base = row_scratch + rec_idx * ROW_STRIDE
    var dp_prev = scratch_base
    var dp_curr = scratch_base + (MAX_REF_LEN + 1)

    var match_score: Int32 = 1
    var mismatch_score: Int32 = -1
    var gap_score: Int32 = -1

    for i in range(ref_len + 1):
        dp_prev.store(i, gap_score * Int32(i))

    for j in range(1, query_len + 1):
        dp_curr.store(0, gap_score * Int32(j))
        for i in range(1, ref_len + 1):
            var im1 = i - 1
            var diag = (dp_prev.load(im1))[0]
            var ref_byte = ref_tensor.load_scalar(im1)
            var q_byte = (seq_ptr + q_start + j - 1)[]
            if ref_byte == q_byte:
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
        var tmp = dp_prev
        dp_prev = dp_curr
        dp_curr = tmp

    scores[rec_idx] = dp_prev.load(ref_len)[0]


fn mismatch_count_kernel(
    ref_tensor: LayoutTensor[DType.uint8, REF_LAYOUT, MutAnyOrigin],
    ref_len: Int,
    seq_ptr: UnsafePointer[UInt8, MutAnyOrigin],
    qual_ends: UnsafePointer[Int64, MutAnyOrigin],
    num_records: Int,
    mismatch_out: UnsafePointer[Int32, MutAnyOrigin],
) -> None:
    """One block per record: count position-wise mismatches with reference over min(query_len, ref_len)."""
    var rec_idx = Int(block_idx.x)
    if rec_idx >= num_records:
        return
    var q_start: Int = 0
    if rec_idx > 0:
        q_start = Int(qual_ends[rec_idx - 1])
    var q_end = Int(qual_ends[rec_idx])
    var query_len = q_end - q_start
    var cmp_len = min(query_len, ref_len)
    var count: Int32 = 0
    for i in range(cmp_len):
        if ref_tensor.load_scalar(i) != (seq_ptr + q_start + i)[]:
            count += 1
    mismatch_out[rec_idx] = count


fn needleman_wunsch_cpu(reference: String, query: String) -> Int32:
    """Host-side NW. Same scoring: match +1, mismatch -1, gap -1."""
    var r_len = len(reference)
    var q_len = len(query)
    if r_len == 0 or q_len == 0:
        return 0
    var match_score: Int32 = 1
    var mismatch_score: Int32 = -1
    var gap_score: Int32 = -1
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
