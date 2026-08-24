"""Internal parsing utilities and public helpers for BlazeSeq.

Generic byte/string helpers shared across formats:
- `memchr`, `memchr_scalar`: SIMD newline search
- `_strip_spaces`, `is_posix_space`, `_check_ascii`: byte validation helpers
- Synthetic FASTA generators (`generate_synthetic_fasta_buffer`,
  `compute_num_fasta_reads_for_size`)

FASTQ-specific scanning, schema parsing, and synthetic-data generation live in
`blazeseq.fastq.scan`, `blazeseq.fastq.quality_schema`, and
`blazeseq.fastq.synthetic`.
"""

from std.memory import pack_bits
from blazeseq.CONSTS import simd_width
from std.bit import count_trailing_zeros
from std import math
from blazeseq.CONSTS import *
from blazeseq.errors import FastxErrorCode


# # From extramojo pacakge, skipping version problems
@always_inline()
@doc_hidden
def memchr(haystack: Span[UInt8, _], chr: UInt8, start: Int = 0) -> Int:
    """
    Function to find the next occurrence of character.
    Args:
        haystack: The bytes to search for the `chr`.
        chr: The byte to search for.
        start: The starting point to begin the search in `haystack`.

    Returns:
        The index of the found character, or -1 if not found.
    """

    comptime CASCADE = build_cascade[simd_width]()

    # if (len(haystack) - start) < simd_width:
    #     for i in range(start, len(haystack)):
    #         if haystack[i] == chr:
    #             return i
    #     return -1

    # Do an unaligned initial read, it doesn't matter that this will overlap the next portion
    var ptr = haystack[start:].unsafe_ptr()

    # Find the last aligned end
    var haystack_len = len(haystack) - start
    var aligned_end = math.align_down(haystack_len, simd_width)

    # Now do aligned reads all through
    var i = 0
    while i < aligned_end:
        var v = ptr.unsafe_load[width=simd_width](i)
        var mask = v.eq(chr)
        var packed = pack_bits(mask)
        if packed:
            var index = Int(count_trailing_zeros(packed))
            return i + index + start
        i += simd_width

    var tail_start = aligned_end  # relative to ptr base (haystack[start:])
    var tail_len = len(haystack) - (start + tail_start)

    var tail_ptr = ptr.unsafe_offset(tail_start)
    var tail_off = tail_start

    comptime for i in range(len(CASCADE)):
        comptime w = CASCADE[i]
        comptime if w >= 1:  # compile-time: elides dead branches
            if tail_len >= w:  # runtime check
                # Load `w` bytes and check for the first match, if any.
                var v = tail_ptr.unsafe_load[width=w]()
                var mask = v.eq(SIMD[DType.uint8, w](chr))
                var packed = pack_bits(mask)
                if packed:
                    return Int(count_trailing_zeros(packed)) + tail_off + start
                tail_ptr = tail_ptr.unsafe_offset(w)
                tail_off = tail_off + w
                tail_len -= w

    return -1


@doc_hidden
@always_inline()
def build_cascade[W: Int]() -> List[Int]:
    """Generate [W//2, W//4, ..., 1] stopping before duplicates or zeros."""
    var result = List[Int]()
    var w = W // 2
    while w >= 1:
        result.append(w)
        w = w // 2
    return result^


@doc_hidden
@always_inline("nodebug")
def memchr_scalar(haystack: Span[UInt8, _], chr: UInt8, start: Int = 0) -> Int:
    """
    Scalar (non-SIMD) variant of memchr. Find first occurrence of byte in haystack.
    Returns index or -1 if not found.
    """
    for i in range(start, len(haystack)):
        if haystack[i] == chr:
            return i
    return -1


@always_inline
def _strip_spaces[
    mut: Bool, //, o: Origin[mut=mut]
](in_slice: Span[Byte, o]) -> Span[Byte, o]:
    """Trim leading and trailing POSIX whitespace from a byte span."""
    if len(in_slice) == 0:
        return in_slice

    if not is_posix_space(in_slice[0]) and not is_posix_space(
        in_slice[len(in_slice) - 1]
    ):
        return in_slice

    var start = 0
    while start < len(in_slice) and is_posix_space(in_slice[start]):
        start += 1

    var end = len(in_slice)
    while end > start and is_posix_space(in_slice[end - 1]):
        end -= 1
    return in_slice[start:end]


@always_inline
def _check_ascii[
    mut: Bool, //, o: Origin[mut=mut]
](buffer: Span[Byte, o]) -> FastxErrorCode:
    """Validate that all bytes in `buffer` are 7-bit ASCII (high bit not set). Returns OK or ASCII_INVALID.
    """
    var aligned_end = math.align_down(len(buffer), simd_width)
    comptime bit_mask: UInt8 = 0x80  # Non-negative bit for ASCII

    for i in range(0, aligned_end, simd_width):
        var vec = buffer.unsafe_ptr().unsafe_load[width=simd_width](i)
        if (vec & bit_mask).reduce_or():
            return FastxErrorCode.ASCII_INVALID

    for i in range(aligned_end, len(buffer)):
        if buffer.unsafe_ptr()[unsafe_offset=i] & bit_mask != 0:
            return FastxErrorCode.ASCII_INVALID
    return FastxErrorCode.OK


# Optimized posix_space check using bitmask lookup
@doc_hidden
@always_inline
def is_posix_space(c: UInt8) -> Bool:
    """Return True if `c` is one of the POSIX whitespace characters."""
    # Precomputed bitmask for ASCII 0-63.
    # Bits set: 9(\t), 10(\n), 11(\v), 12(\f), 13(\r), 28(FS), 29(GS), 30(RS), 32(Space)
    comptime MASK: UInt64 = UInt64(
        (1 << ord("\t"))
        | (1 << ord("\n"))
        | (1 << ord("\v"))
        | (1 << ord("\f"))
        | (1 << ord("\r"))
        | (1 << ord("\x1c"))
        | (1 << ord("\x1d"))
        | (1 << ord("\x1e"))
        | (1 << ord(" "))
    )
    # If c > 32, it's definitely not one of our space characters.
    if c > 32:
        return False

    # Check if the 'c-th' bit is set in our mask
    return ((MASK >> c.cast[DType.uint64]()) & 1) != 0


def compute_num_fasta_reads_for_size(
    target_size_bytes: Int,
    min_length: Int,
    max_length: Int,
    line_width: Int = 60,
) -> Int:
    """Compute the number of FASTA records needed to approximate a target size.

    Estimates bytes per record based on:
    - Header: >read_<padded_i>\\n (constant: 6 + num_digits + 1 bytes)
    - Sequence: seq_len bytes + ceil(seq_len / line_width) newlines

    Args:
        target_size_bytes: Target total size in bytes.
        min_length: Minimum sequence length per record (inclusive).
        max_length: Maximum sequence length per record (inclusive).
        line_width: Number of bases per sequence line (default 60).

    Returns:
        Estimated number of records needed to reach target_size_bytes.
    """
    if target_size_bytes <= 0:
        return 0
    var avg_length = (min_length + max_length) // 2
    var header_est: Int = 15
    var seq_newlines = (avg_length + line_width - 1) // line_width
    var bytes_per_record_est = header_est + avg_length + seq_newlines
    var num_reads_est = target_size_bytes // bytes_per_record_est
    if num_reads_est <= 0:
        return 0
    # Refine header size from estimated num_reads
    var num_digits: Int = 1
    if num_reads_est > 1:
        num_digits = String(num_reads_est - 1).byte_length()
    var header_size = 6 + num_digits + 1
    var bytes_per_record = header_size + avg_length + seq_newlines
    return target_size_bytes // bytes_per_record


def generate_synthetic_fasta_buffer(
    num_reads: Int,
    min_length: Int,
    max_length: Int,
    line_width: Int = 60,
    gc_bias: Float32 = 0.5,
) raises -> List[Byte]:
    """Generate a contiguous in-memory FASTA buffer with configurable sequence length and GC content.

    Sequence lengths are chosen deterministically in [min_length, max_length].
    Sequences are wrapped at `line_width` bases per line (multiline FASTA).
    Base composition follows the same LCG + GC-bias model as generate_synthetic_fastq_buffer.

    Args:
        num_reads: Number of FASTA records to generate.
        min_length: Minimum sequence length per record (inclusive).
        max_length: Maximum sequence length per record (inclusive).
        line_width: Number of bases per sequence line. Default 60 (standard FASTA).
        gc_bias: Target GC fraction in [0.0, 1.0]. Default 0.5.

    Returns:
        List[Byte] containing valid multiline FASTA data; pass to MemoryReader for parsing.

    Raises:
        Error: If arguments are invalid.
    """
    if num_reads <= 0:
        return List[Byte]()
    if min_length < 0 or max_length < 0:
        raise Error(
            "generate_synthetic_fasta_buffer: lengths must be non-negative"
        )
    if min_length > max_length:
        raise Error(
            "generate_synthetic_fasta_buffer: min_length must be <= max_length"
        )
    if line_width <= 0:
        raise Error(
            "generate_synthetic_fasta_buffer: line_width must be positive"
        )

    var capacity_estimate = num_reads * (
        max_length + max_length // line_width + 20
    )
    var out = List[Byte](capacity=capacity_estimate)

    # Base LUT: same GC-bias model as generate_synthetic_fastq_buffer
    var gc_slots = Int(gc_bias * 8.0 + 0.5)
    if gc_slots < 0:
        gc_slots = 0
    if gc_slots > 8:
        gc_slots = 8
    var at_slots = 8 - gc_slots

    var base_lut = List[Byte](capacity=8)
    for k in range(gc_slots):
        if k % 2 == 0:
            base_lut.append(Byte(ord("G")))
        else:
            base_lut.append(Byte(ord("C")))
    for k in range(at_slots):
        if k % 2 == 0:
            base_lut.append(Byte(ord("A")))
        else:
            base_lut.append(Byte(ord("T")))

    var newline = Byte(ord("\n"))
    var gt = Byte(ord(">"))

    # Header zero-padding width
    var num_digits: Int = 1
    if num_reads > 1:
        num_digits = String(num_reads - 1).byte_length()

    for i in range(num_reads):
        # --- Record length (same deterministic scheme as FASTQ generator) ---
        var seq_len: Int
        if max_length == min_length:
            seq_len = min_length
        else:
            seq_len = min_length + (
                (i * 31 + 7) % (max_length - min_length + 1)
            )

        # --- Header: >read_XXXXXXX\n ---
        var index_str = String(i)
        while index_str.byte_length() < num_digits:
            index_str = "0" + index_str
        out.append(gt)
        var header_body = "read_" + index_str + "\n"
        out.extend(header_body.as_bytes())

        # --- Sequence lines (wrapped at line_width) ---
        var lcg_state: Int = (
            i * 6364136223846793005 + 1442695040888963407
        ) & 0x7FFFFFFFFFFFFFFF
        var col = 0
        for _ in range(seq_len):
            lcg_state = (
                lcg_state * 6364136223846793005 + 1442695040888963407
            ) & 0x7FFFFFFFFFFFFFFF
            var slot = (lcg_state >> 33) % 8
            out.append(base_lut[slot])
            col += 1
            if col == line_width:
                out.append(newline)
                col = 0
        # Final newline if last line wasn't full
        if col > 0:
            out.append(newline)

    return out^
