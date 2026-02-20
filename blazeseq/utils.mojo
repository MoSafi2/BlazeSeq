"""Internal parsing utilities and public helpers for BlazeSeq.

Public helpers:
- generate_synthetic_fastq_buffer: Build in-memory FASTQ for tests/benchmarks.
- compute_num_reads_for_size: Estimate read count for a target byte size.

Most other symbols (SearchState, SearchResults, _parse_schema, _parse_record_fast_path,
_handle_incomplete_line, etc.) are used by the parser and are internal.
"""

from memory import pack_bits
from blazeseq.CONSTS import simd_width
from bit import count_trailing_zeros
import math
from sys.info import simd_width_of
import math
from blazeseq.CONSTS import *
from blazeseq.iostream import EOFError, LineIteratorError


comptime NEW_LINE = 10
comptime SIMD_U8_WIDTH: Int = simd_width_of[DType.uint8]()


# Parsing Algorithm adopted from Needletaile and Seq-IO with modifications.
@register_passable("trivial")
@fieldwise_init
struct SearchState(Copyable, ImplicitlyDestructible, Movable):
    var state: Int8
    comptime START = Self(0)
    comptime HEADER_FOUND = Self(1)
    comptime SEQ_FOUND = Self(2)
    comptime QUAL_HEADER_FOUND = Self(3)
    comptime QUAL_FOUND = Self(4)

    fn __eq__(self, other: Self) -> Bool:
        return self.state == other.state

    fn __add__(self, other: Int8) -> Self:
        return Self(self.state + other)

    fn __sub__(self, other: Int8) -> Self:
        return Self(self.state - other)


@register_passable("trivial")
@fieldwise_init
struct SearchResults(
    Copyable, ImplicitlyDestructible, Movable, Sized, Writable
):
    var start: Int
    var end: Int
    var header: Span[Byte, MutExternalOrigin]
    var seq: Span[Byte, MutExternalOrigin]
    var qual_header: Span[Byte, MutExternalOrigin]
    var qual: Span[Byte, MutExternalOrigin]

    comptime DEFAULT = Self(
        -1,
        -1,
        Span[Byte, MutExternalOrigin](),
        Span[Byte, MutExternalOrigin](),
        Span[Byte, MutExternalOrigin](),
        Span[Byte, MutExternalOrigin](),
    )

    fn write_to[w: Writer](self, mut writer: w) -> None:
        writer.write(
            String("SearchResults(start=") + String(self.start),
            ", end=",
            String(self.end)
            + ", header="
            + String(StringSlice(unsafe_from_utf8=self.header))
            + ", seq="
            + String(StringSlice(unsafe_from_utf8=self.seq))
            + ", qual_header="
            + String(StringSlice(unsafe_from_utf8=self.qual_header))
            + ", qual="
            + String(StringSlice(unsafe_from_utf8=self.qual))
            + ")",
        )

    fn all_set(self) -> Bool:
        return (
            self.start != -1
            and self.end != -1
            and len(self.header) > 0
            and len(self.seq) > 0
            and len(self.qual_header) > 0
            and len(self.qual) > 0
        )

    fn __add__(self, amt: Int) -> Self:
        new_header = Span[Byte, MutExternalOrigin](
            ptr=self.header.unsafe_ptr() + amt,
            length=len(self.header),
        )
        new_seq = Span[Byte, MutExternalOrigin](
            ptr=self.seq.unsafe_ptr() + amt,
            length=len(self.seq),
        )
        new_qual_header = Span[Byte, MutExternalOrigin](
            ptr=self.qual_header.unsafe_ptr() + amt,
            length=len(self.qual_header),
        )
        new_qual = Span[Byte, MutExternalOrigin](
            ptr=self.qual.unsafe_ptr() + amt,
            length=len(self.qual),
        )
        return Self(
            self.start + amt,
            self.end + amt,
            new_header,
            new_seq,
            new_qual_header,
            new_qual,
        )

    fn __sub__(self, amt: Int) -> Self:
        new_header = Span[Byte, MutExternalOrigin](
            ptr=self.header.unsafe_ptr() - amt,
            length=len(self.header),
        )
        new_seq = Span[Byte, MutExternalOrigin](
            ptr=self.seq.unsafe_ptr() - amt,
            length=len(self.seq),
        )
        new_qual_header = Span[Byte, MutExternalOrigin](
            ptr=self.qual_header.unsafe_ptr() - amt,
            length=len(self.qual_header),
        )
        new_qual = Span[Byte, MutExternalOrigin](
            ptr=self.qual.unsafe_ptr() - amt,
            length=len(self.qual),
        )
        return Self(
            self.start - amt,
            self.end - amt,
            new_header,
            new_seq,
            new_qual_header,
            new_qual,
        )

    fn __getitem__(self, index: Int) -> Span[Byte, MutExternalOrigin]:
        if index == 0:
            return self.header
        elif index == 1:
            return self.seq
        elif index == 2:
            return self.qual_header
        elif index == 3:
            return self.qual
        else:
            return Span[Byte, MutExternalOrigin]()

    fn __setitem__(mut self, index: Int, value: Span[Byte, MutExternalOrigin]):
        if index == 0:
            self.header = value
        elif index == 1:
            self.seq = value
        elif index == 2:
            self.qual_header = value
        elif index == 3:
            self.qual = value
        else:
            print("Index out of bounds: ", index)
            pass

    fn __len__(self) -> Int:
        return self.end - self.start


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


fn compute_num_reads_for_size(
    target_size_bytes: Int,
    min_length: Int,
    max_length: Int,
) -> Int:
    """Compute the number of FASTQ reads needed to approximate a target size.

    Estimates bytes per record based on:
    - Header: @read_<padded_i>\\n (constant size: 6 + num_digits + 1 bytes)
    - Sequence line: read_len + 1 (newline)
    - Plus line: +\\n (2 bytes)
    - Quality line: read_len + 1 (newline)

    Uses average read length and constant header size (indices are zero-padded in generate_synthetic_fastq_buffer).

    Args:
        target_size_bytes: Target total size in bytes.
        min_length: Minimum read length per record.
        max_length: Maximum read length per record.

    Returns:
        Estimated number of reads needed to reach target_size_bytes.
    """
    if target_size_bytes <= 0:
        return 0
    var avg_read_length = (min_length + max_length) // 2
    # Initial header size estimate (e.g. 15 bytes for up to 100M reads)
    var header_est: Int = 15
    var bytes_per_record_est = header_est + 2 * avg_read_length + 4
    var num_reads_est = target_size_bytes // bytes_per_record_est
    if num_reads_est <= 0:
        return 0
    # Refine header size from estimated num_reads (zero-padded width)
    var num_digits: Int = 1
    if num_reads_est > 1:
        num_digits = len(String(num_reads_est - 1))
    var header_size = 6 + num_digits + 1
    var bytes_per_record = header_size + 2 * avg_read_length + 4
    return target_size_bytes // bytes_per_record


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

    # Constant header size: @read_<zero_padded_i>\n
    var num_digits: Int = 1
    if num_reads > 1:
        num_digits = len(String(num_reads - 1))

    for i in range(num_reads):
        # Deterministic read length in [min_length, max_length]
        var read_len: Int
        if max_length == min_length:
            read_len = min_length
        else:
            read_len = min_length + ((i * 31 + 7) % (max_length - min_length + 1))

        # Header: @read_<zero_padded_i>\n (constant size per record)
        var index_str = String(i)
        while len(index_str) < num_digits:
            index_str = "0" + index_str
        var header_str = "@read_" + index_str + "\n"
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







# BUG: There is a bug here when the buffer is grown, but the record is not parsed correctly.
@always_inline
fn _handle_incomplete_line_with_buffer_growth[
    R: Reader
](
    mut stream: LineIterator[R],
    mut interim: SearchResults,
    mut state: SearchState,
    quality_schema: QualitySchema,
    max_capacity: Int,
) raises -> RefRecord[origin=MutExternalOrigin]:
    while True:
        if not stream.has_more():
            raise EOFError()
        if interim.start == 0:
            stream.buffer.resize_buffer(stream.buffer.capacity(), max_capacity)
        stream.buffer._compact_from(interim.start)
        _ = stream.buffer._fill_buffer()
        interim = SearchResults.DEFAULT
        interim.start = 0
        state = SearchState.START
        try:
            for i in range(4):
                var line = stream.next_complete_line()
                interim[i] = line
                state = state + 1
        except e:
            if e == LineIteratorError.INCOMPLETE_LINE or e == LineIteratorError.EOF:
                continue
            else:
                raise e
        interim.end = stream.buffer.buffer_position()
        if interim.all_set():
            break
    return RefRecord[origin=MutExternalOrigin](
        interim[0],
        interim[1],
        interim[2],
        interim[3],
        Int8(quality_schema.OFFSET),
    )


@always_inline
fn _handle_incomplete_line[
    R: Reader
](
    mut stream: LineIterator[R],
    mut interim: SearchResults,
    mut state: SearchState,
    quality_schema: QualitySchema,
    buffer_capacity: Int,
) raises -> RefRecord[origin=MutExternalOrigin]:
    if not stream.has_more():
        raise EOFError()

    stream.buffer._compact_from(interim.start)
    _ = stream.buffer._fill_buffer()
    interim = interim - interim.start
    for i in range(state.state, 4):
        try:
            var line = stream.next_complete_line()
            interim[i] = line
            state = state + 1
        except e:
            if e == LineIteratorError.EOF:
                raise EOFError()
            if e == LineIteratorError.INCOMPLETE_LINE:
                raise Error(
                    "Line exceeds buffer capacity of "
                    + String(buffer_capacity)
                    + " bytes. Enable buffer_growth or use a larger buffer_capacity."
                )
            raise e
    interim.end = stream.buffer.buffer_position()

    if not interim.all_set():
        raise LineIteratorError.OTHER

    return RefRecord[origin=MutExternalOrigin](
        interim[0],
        interim[1],
        interim[2],
        interim[3],
        Int8(quality_schema.OFFSET),
    )


@always_inline
fn _parse_record_fast_path[
    R: Reader
](
    mut stream: LineIterator[R],
    mut interim: SearchResults,
    mut state: SearchState,
    quality_schema: QualitySchema,
) raises LineIteratorError -> RefRecord[origin=MutExternalOrigin]:
    interim.start = stream.buffer.buffer_position()
    for i in range(4):
        try:
            interim[i] = stream.next_complete_line()
            state = state + 1
        except e:
            raise e
    interim.end = stream.buffer.buffer_position()

    if not interim.all_set():
        raise LineIteratorError.OTHER

    return RefRecord[origin=MutExternalOrigin](
        interim[0],
        interim[1],
        interim[2],
        interim[3],
        Int8(quality_schema.OFFSET),
    )
