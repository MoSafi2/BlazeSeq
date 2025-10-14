from memory import pack_bits
from blazeseq.CONSTS import simd_width
from bit import count_trailing_zeros
import math


alias NEW_LINE = 10


@always_inline
fn _strip_spaces[
    mut: Bool, o: Origin[mut]
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
fn _check_ascii[mut: Bool, //, o: Origin[mut]](buffer: Span[Byte, o]) raises:
    var aligned_end = math.align_down(len(buffer), simd_width)
    alias bit_mask: UInt8 = 0x80  # Non-negative bit for ASCII

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
    alias SPACE = Byte(ord(" "))
    alias HORIZONTAL_TAB = Byte(ord("\t"))
    alias NEW_LINE = Byte(ord("\n"))
    alias CARRIAGE_RETURN = Byte(ord("\r"))
    alias FORM_FEED = Byte(ord("\f"))
    alias VERTICAL_TAB = Byte(ord("\v"))
    alias FILE_SEP = Byte(ord("\x1c"))
    alias GROUP_SEP = Byte(ord("\x1d"))
    alias RECORD_SEP = Byte(ord("\x1e"))

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
