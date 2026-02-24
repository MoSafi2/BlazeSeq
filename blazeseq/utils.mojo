"""Internal parsing utilities and public helpers for BlazeSeq.

Public helpers:
- `generate_synthetic_fastq_buffer`: Build in-memory FASTQ for tests/benchmarks.
- `compute_num_reads_for_size`: Estimate read count for a target byte size.

Most other symbols (`SearchState`, `SearchResults`, `_parse_schema`, `_parse_record_fast_path`,
`_handle_incomplete_line`, etc.) are used by the parser and are internal.
"""

from memory import pack_bits
from blazeseq.CONSTS import simd_width
from bit import count_trailing_zeros
import math
from sys.info import simd_width_of
import math
from blazeseq.CONSTS import *
from blazeseq.io.buffered import EOFError, LineIteratorError, LineIterator, _trim_trailing_cr
from blazeseq.io.readers import Reader
from blazeseq.errors import ParseError, buffer_capacity_error
from blazeseq.parser import FastqParser




@doc_private
fn format_parse_error(
    message: String,
    parser: FastqParser,
    record_snippet: String,
) -> String:
    """Build ParseError from message and parser context; return formatted string for raising Error."""
    var parse_err = ParseError(
        message,
        record_number=parser.get_record_number(),
        line_number=parser.get_line_number(),
        file_position=parser.get_file_position(),
        record_snippet=record_snippet,
    )
    return parse_err.__str__()


comptime NEW_LINE = 10
comptime SIMD_U8_WIDTH: Int = simd_width_of[DType.uint8]()

@doc_private
@register_passable("trivial")
struct SearchResults(Copyable, ImplicitlyDestructible, Movable, Writable):
    var id_start: Int
    var id_end: Int
    var seq_start: Int
    var seq_end: Int
    var qual_start: Int
    var qual_end: Int
    var total_bytes: Int # The offset of the byte after the 4th newline

    fn __init__(out self):
        self.id_start = -1
        self.id_end = -1
        self.seq_start = -1
        self.seq_end = -1
        self.qual_start = -1
        self.qual_end = -1
        self.total_bytes = 0
    
    fn write_to[w: Writer](self, mut writer: w) -> None:
        writer.write(
            String("SearchResults(id_start=") + String(self.id_start),
            ", id_end=", String(self.id_end),
            ", seq_start=", String(self.seq_start),
            ", seq_end=", String(self.seq_end),
            ", qual_start=", String(self.qual_start),
            ", qual_end=", String(self.qual_end),
        )

@doc_private
@register_passable("trivial")
struct SearchState:
    var state: Int8
    comptime START = 0
    comptime SEQ = 1
    comptime PLUS = 2
    comptime QUAL = 3
    comptime DONE = 4

    fn __init__(out self, state: Int8 = 0):
        self.state = state


@doc_private
@always_inline
fn _scan_record_indices[R: Reader](
    mut stream: LineIterator[R],
    mut results: SearchResults,
    mut state: SearchState,
) -> LineIteratorError:
    var view = stream.buffer.view()
    var pos: Int = results.total_bytes
    while state.state < SearchState.DONE:
        var found = memchr(haystack=view, chr=new_line, start=pos)
        if found == -1:
            if stream.buffer.is_eof() and pos < len(view):
                found = len(view) # Treat EOF as a newline for the last line
            else:
                results.total_bytes = pos # Save progress
                return LineIteratorError.INCOMPLETE_LINE
        
        if state.state == SearchState.START:
            results.id_start = pos  # Include '@' so validator and id_slice() match line-based parser
            results.id_end = _trim_trailing_cr(view, found)
        elif state.state == SearchState.SEQ:
            results.seq_start = pos
            results.seq_end = _trim_trailing_cr(view, found)
        elif state.state == SearchState.QUAL:
            results.qual_start = pos
            results.qual_end = _trim_trailing_cr(view, found)

        pos = found + 1
        state.state += 1

    results.total_bytes = pos
    return LineIteratorError.SUCCESS


@doc_private
@always_inline
fn _handle_incomplete_line[R: Reader](
    mut stream: LineIterator[R],
    mut results: SearchResults,
    mut state: SearchState,
)  raises-> LineIteratorError:
    # Compact to the start of the current record to maximize refill space
    stream.buffer._compact_from(stream.buffer.buffer_position())
    # We must reset progress because _compact_from shifts memory to index 0
    results = SearchResults()
    state = SearchState()
    var bytes_read = stream.buffer._fill_buffer()
    if bytes_read == 0 and stream.buffer.available() == 0:
        raise EOFError()

    # Retry the scan now that the buffer is refilled
    return _scan_record_indices(stream, results, state)


# From extramojo pacakge, skipping version problems
@always_inline("nodebug")
@doc_private
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
    if (len(haystack) - start) < SIMD_U8_WIDTH:
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

    
    var tail_start = aligned_end + offset  # relative to ptr base (haystack[start:])
    var tail_len = len(haystack) - (start + tail_start)

    # Finish and last bytes
    @parameter
    fn check_tail[width: Int](p: UnsafePointer[UInt8], base_offset: Int) -> Int:
        """Load `width` bytes, return absolute index of first match or -1."""
        var v = p.load[width=width]()
        var mask = v.eq(SIMD[DType.uint8, width](chr))
        var packed = pack_bits(mask)
        if packed:
            return Int(count_trailing_zeros(packed)) + base_offset + start
        return -1

    var tail_ptr = ptr + tail_start
    var tail_off = tail_start + offset  # absolute offset from haystack.unsafe_ptr()

    @parameter
    for w in [SIMD_U8_WIDTH // 2, SIMD_U8_WIDTH // 4, SIMD_U8_WIDTH // 8, 1]:
        @parameter
        if w >= 1:
            if tail_len >= w:
                var result = check_tail[w](tail_ptr, tail_off)
                if result != -1:
                    return result
                tail_ptr  = tail_ptr + w
                tail_off  = tail_off + w
                tail_len -= w


    return -1


@doc_private
@always_inline("nodebug")
fn memchr_scalar(haystack: Span[UInt8], chr: UInt8, start: Int = 0) -> Int:
    """
    Scalar (non-SIMD) variant of memchr. Find first occurrence of byte in haystack.
    Returns index or -1 if not found.
    """
    for i in range(start, len(haystack)):
        if haystack[i] == chr:
            return i
    return -1


@doc_private
@always_inline
fn _strip_spaces[
    mut: Bool, o: Origin[mut=mut]
](in_slice: Span[Byte, o]) raises -> Span[Byte, o]:
    var start = 0
    while start < len(in_slice) and is_posix_space(in_slice[start]):
        start += 1

    var end = len(in_slice)
    while end > start and is_posix_space(in_slice[end - 1]):
        end -= 1
    return in_slice[start:end]


@doc_private
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
@doc_private
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


@doc_private
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

    Uses average read length and constant header size (indices are zero-padded in `generate_synthetic_fastq_buffer`).

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




# Buffer growth disabled until more stable. BUG: when the buffer is grown, the record is not parsed correctly.
# @doc_private
# @always_inline
# fn _handle_incomplete_line_with_buffer_growth[
#     R: Reader
# ](
#     mut stream: LineIterator[R],
#     mut interim: SearchResults,
#     mut state: SearchState,
#     quality_schema: QualitySchema,
#     max_capacity: Int,
# ) raises -> RefRecord[origin=MutExternalOrigin]:
#     while True:
#         if not stream.has_more():
#             raise EOFError()
#         if interim.start == 0:
#             stream.buffer.resize_buffer(stream.buffer.capacity(), max_capacity)
#         stream.buffer._compact_from(interim.start)
#         _ = stream.buffer._fill_buffer()
#         interim = SearchResults.DEFAULT
#         interim.start = 0
#         state = SearchState.START
#         try:
#             var line = stream.next_complete_line()
#             interim[state.state] = line
#             state = state + 1
#         except e:
#             if e == LineIteratorError.INCOMPLETE_LINE or e == LineIteratorError.EOF:
#                 continue
#             if e == LineIteratorError.BUFFER_TOO_SMALL:
#                 raise Error(
#                     buffer_capacity_error(
#                         stream.buffer.capacity(),
#                         max_capacity,
#                         growth_hint=True,
#                         at_max=(stream.buffer.capacity() >= max_capacity),
#                     )
#                 )
#             raise Error(String(e))
#         interim.end = stream.buffer.buffer_position()
#         break
#     return RefRecord[origin=MutExternalOrigin](
#         interim[0],
#         interim[1],
#         interim[3],
#         quality_schema.OFFSET,
#     )


# @doc_private
# @always_inline
# fn _handle_incomplete_line[
#     R: Reader
# ](
#     mut stream: LineIterator[R],
#     mut interim: SearchResults,
#     mut state: SearchState,
#     quality_schema: QualitySchema,
#     buffer_capacity: Int,
# ) raises -> RefRecord[origin=MutExternalOrigin]:
#     if not stream.has_more():
#         raise EOFError()

#     stream.buffer._compact_from(interim.start)
#     _ = stream.buffer._fill_buffer()
#     interim = interim - interim.start
#     for i in range(state.state, 4):
#         try:
#             var line = stream.next_complete_line()
#             interim[i] = line
#             state = state + 1
#         except e:
#             if e == LineIteratorError.EOF:
#                 raise EOFError()
#             elif e == LineIteratorError.INCOMPLETE_LINE and not stream.has_more():
#                 raise EOFError()
#             elif e == LineIteratorError.INCOMPLETE_LINE:
#                 raise Error(
#                     buffer_capacity_error(buffer_capacity, growth_hint=True)
#                 )
#             raise Error(String(e))
#     interim.end = stream.buffer.buffer_position()

#     return RefRecord[origin=MutExternalOrigin](
#         interim[0],
#         interim[1],
#         interim[3],
#         quality_schema.OFFSET,
#     )


# @doc_private
# @always_inline
# fn _parse_record_fast_path[
#     R: Reader
# ](
#     mut stream: LineIterator[R],
#     mut interim: SearchResults,
#     mut state: SearchState,
#     quality_schema: QualitySchema,
# ) raises LineIteratorError -> RefRecord[origin=MutExternalOrigin]:
#     interim.start = stream.buffer.buffer_position()

#     @parameter    
#     for i in range(4):
#         @parameter
#         if i == 2:
#             line3 = stream.consume_line_scalar()
#             if len(line3) == 0 or line3[0] != quality_header:
#                 raise LineIteratorError.OTHER
#             interim[2] = line3
#             state = state + 1
#             continue

#         interim[i] = stream.next_complete_line()
#         state = state + 1
#     interim.end = stream.buffer.buffer_position()


#     return RefRecord[origin=MutExternalOrigin](
#         interim[0],
#         interim[1],
#         interim[3],
#         quality_schema.OFFSET,
#     )