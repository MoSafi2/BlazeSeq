from memory import pack_bits
from blazeseq.CONSTS import simd_width
from bit import count_trailing_zeros
import math
from sys.info import simd_width_of
import math
from blazeseq.CONSTS import *


comptime NEW_LINE = 10

comptime SIMD_U8_WIDTH: Int = simd_width_of[DType.uint8]()


# From extramojo pacakge, skipping version problems
@always_inline("nodebug")
fn memchr[
    do_alignment: Bool = False
](haystack: Span[UInt8], chr: UInt8, start: Int = 0) -> Int:
    """
    Function to find the next occurrence of character.
    Args:
        haystack: The bytes to search for the `chr`.
        chr: The byte to search for.
        start: The starting point to begin the search in `haystack`.

    Parameters:
        do_alignment: If True this will do an aligning read at the very start of the haystack.
                      If your haystack is very long, this may provide a marginal benefit. If the haystack is short,
                      or the needle is frequently in the first `SIMD_U8_WIDTH * 2` bytes, then skipping the
                      aligning read can be very beneficial since the aligning read check will overlap some
                      amount with the subsequent aligned read that happens next.

    Returns:
        The index of the found character, or -1 if not found.
    """
    if len(haystack[start:]) < SIMD_U8_WIDTH:
        for i in range(start, len(haystack)):
            if haystack[i] == chr:
                return i
        return -1

    # Do an unaligned initial read, it doesn't matter that this will overlap the next portion
    var ptr = haystack[start:].unsafe_ptr()

    var offset = 0

    @parameter
    if do_alignment:
        var v = ptr.load[width=SIMD_U8_WIDTH]()
        var mask: SIMD[DType.bool, SIMD_U8_WIDTH] = v.eq(chr)
        var packed = pack_bits(mask)
        if packed:
            var index = Int(count_trailing_zeros(packed))
            return index + start

        # Now get the alignment
        offset = SIMD_U8_WIDTH - (ptr.__int__() & (SIMD_U8_WIDTH - 1))
        # var aligned_ptr = ptr.offset(offset)
        ptr = ptr + offset

    # Find the last aligned end
    var haystack_len = len(haystack) - (start + offset)
    var aligned_end = math.align_down(
        haystack_len, SIMD_U8_WIDTH
    )  # relative to start + offset

    # Now do aligned reads all through
    for s in range(0, aligned_end, SIMD_U8_WIDTH):
        var v = ptr.load[width=SIMD_U8_WIDTH](s)
        var mask = v.eq(chr)
        var packed = pack_bits(mask)
        if packed:
            var index = Int(count_trailing_zeros(packed))
            return s + index + offset + start

    # Finish and last bytes
    for i in range(aligned_end + start + offset, len(haystack)):
        if haystack[i] == chr:
            return i

    return -1


@always_inline
fn _strip_spaces[
    mut: Bool, o: Origin[mut=mut]
](in_slice: Span[Byte, o]) raises -> Span[Byte, o]:
    var start = 0
    # Find the first non-space character from the beginning
    while start < len(in_slice) and is_posix_space(in_slice[start]):
        start += 1

    var end = len(in_slice)
    # Find the first non-space character from the end
    while end > start and is_posix_space(in_slice[end - 1]):
        end -= 1

    # This correctly handles all-space lines (where end will equal start)
    # and avoids creating a new span if no stripping was needed.
    return in_slice[start:end]


@always_inline
fn _check_ascii[
    mut: Bool, //, o: Origin[mut=mut]
](buffer: Span[Byte, o]) raises:
    var aligned_end = math.align_down(len(buffer), simd_width)
    comptime bit_mask: UInt8 = 0x80  # Non-negative bit for ASCII

    for i in range(0, aligned_end, simd_width):
        var vec = buffer.unsafe_ptr().load[width=simd_width](i)
        if (vec & bit_mask).reduce_or():
            raise Error("Non ASCII letters found")

    for i in range(aligned_end, len(buffer)):
        if buffer.unsafe_ptr()[i] & bit_mask != 0:
            raise Error("Non ASCII letters found")


# Ported from the is_posix_space() in Mojo Stdlib
@always_inline
fn is_posix_space(c: Byte) -> Bool:
    comptime SPACE = Byte(ord(" "))
    comptime HORIZONTAL_TAB = Byte(ord("\t"))
    comptime NEW_LINE = Byte(ord("\n"))
    comptime CARRIAGE_RETURN = Byte(ord("\r"))
    comptime FORM_FEED = Byte(ord("\f"))
    comptime VERTICAL_TAB = Byte(ord("\v"))
    comptime FILE_SEP = Byte(ord("\x1c"))
    comptime GROUP_SEP = Byte(ord("\x1d"))
    comptime RECORD_SEP = Byte(ord("\x1e"))

    # This compiles to something very clever that's even faster than a LUT.
    return (
        c == SPACE
        or c == HORIZONTAL_TAB
        or c == NEW_LINE
        or c == CARRIAGE_RETURN
        or c == FORM_FEED
        or c == VERTICAL_TAB
        or c == FILE_SEP
        or c == GROUP_SEP
        or c == RECORD_SEP
    )


@always_inline
fn _parse_schema(quality_format: String) -> QualitySchema:
    """Parse quality schema string into QualitySchema."""
    var schema: QualitySchema

    if quality_format == "sanger":
        schema = materialize[sanger_schema]()
    elif quality_format == "solexa":
        schema = materialize[solexa_schema]()
    elif quality_format == "illumina_1.3":
        schema = materialize[illumina_1_3_schema]()
    elif quality_format == "illumina_1.5":
        schema = materialize[illumina_1_5_schema]()
    elif quality_format == "illumina_1.8":
        schema = materialize[illumina_1_8_schema]()
    elif quality_format == "generic":
        schema = materialize[generic_schema]()
    else:
        print(
            """Unknown quality schema please choose one of 'sanger', 'solexa',"
            " 'illumina_1.3', 'illumina_1.5' 'illumina_1.8', or 'generic'.
            Parsing with generic schema."""
        )
        return materialize[generic_schema]()
    return schema^


fn generate_synthetic_fastq_buffer(
    num_reads: Int,
    min_length: Int,
    max_length: Int,
    min_phred: Int,
    max_phred: Int,
    quality_schema: String,
) raises -> List[Byte]:
    """Generate a contiguous in-memory FASTQ buffer with configurable read length and quality distribution.

    Read lengths are chosen deterministically in [min_length, max_length] (inclusive).
    Per-base Phred scores are chosen deterministically in [min_phred, max_phred], then converted
    to ASCII using the given quality schema and clamped to the schema's valid range.

    Args:
        num_reads: Number of FASTQ records to generate.
        min_length: Minimum sequence length per read (inclusive).
        max_length: Maximum sequence length per read (inclusive).
        min_phred: Minimum Phred score per base (inclusive).
        max_phred: Maximum Phred score per base (inclusive).
        quality_schema: Schema name (e.g. "sanger", "solexa", "illumina_1.8", "generic").

    Returns:
        List[Byte] containing valid 4-line FASTQ data; pass to MemoryReader for parsing.

    Raises:
        Error: If num_reads < 0, min_length > max_length, or min_phred > max_phred.
    """
    if num_reads <= 0:
        return List[Byte]()
    if min_length > max_length:
        raise Error("generate_synthetic_fastq_buffer: min_length must be <= max_length")
    if min_phred > max_phred:
        raise Error("generate_synthetic_fastq_buffer: min_phred must be <= max_phred")

    var schema = _parse_schema(quality_schema)
    var offset_int = Int(schema.OFFSET)
    var lower_int = Int(schema.LOWER)
    var upper_int = Int(schema.UPPER)

    var capacity_estimate = num_reads * (max_length + 50)
    if capacity_estimate < 0:
        capacity_estimate = 4096
    var out = List[Byte](capacity=capacity_estimate)

    var bases = [Byte(ord("A")), Byte(ord("C")), Byte(ord("G")), Byte(ord("T"))]
    var newline = Byte(ord("\n"))
    var plus = Byte(ord("+"))

    for i in range(num_reads):
        # Deterministic read length in [min_length, max_length]
        var read_len: Int
        if max_length == min_length:
            read_len = min_length
        else:
            read_len = min_length + ((i * 31 + 7) % (max_length - min_length + 1))

        # Header: @read_<i>\n
        var header_str = "@read_" + String(i) + "\n"
        var header_bytes = header_str.as_bytes()
        out.extend(header_bytes)

        # Sequence line (same base per read: ACGT pattern by read index)
        for p in range(read_len):
            out.append(bases[i % 4])
        out.append(newline)

        # +\n
        out.append(plus)
        out.append(newline)

        # Quality line: Phred in [min_phred, max_phred], then ASCII = OFFSET + phred clamped to [LOWER, UPPER]
        var phred_range = max_phred - min_phred + 1
        for p in range(read_len):
            var phred: Int
            if phred_range == 1:
                phred = min_phred
            else:
                phred = min_phred + ((i + p) * 31 + 7) % phred_range
            var ascii_int = offset_int + phred
            if ascii_int < lower_int:
                ascii_int = lower_int
            elif ascii_int > upper_int:
                ascii_int = upper_int
            out.append(Byte(ascii_int))
        out.append(newline)

    return out^
