from memory import pack_bits
from blazeseq.CONSTS import simd_width
from bit import count_trailing_zeros
import math
from sys.info import simd_width_of
import math


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
