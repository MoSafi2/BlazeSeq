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
from blazeseq.io.buffered import EOFError, LineIteratorError, LineIterator, BufferedReader
from blazeseq.io.readers import Reader
from blazeseq.errors import ParseError, buffer_capacity_error
from blazeseq.parser import FastqParser





comptime NEW_LINE = 10
comptime SIMD_U8_WIDTH: Int = simd_width_of[DType.uint8]()


@doc_private
@register_passable("trivial")
@fieldwise_init
@align(64)
struct RecordOffsets(Copyable, Movable, Writable):
    """
    Byte offsets into the buffer for one FASTQ record, all **relative to
    view()[0]** (i.e. relative to buf._ptr + buf._head) at the moment
    _scan_record was first called for this record.

    Mirrors Rust BufferPosition fields:
        header_start  ↔  start      first byte of '@'
        seq_start     ↔  seq        first byte of sequence line
        sep_start     ↔  sep        first byte of '+' separator
        qual_start    ↔  qual       first byte of quality line
        record_end    ↔  end        one past last quality byte (excl. newline)

    Zero-initialised; record_end == 0 means "not yet complete".
    """
    var header_start : Int   # always 0 for the first record; non-zero after
                             # make_room shifts don't apply here (we re-anchor
                             # to view()[0] each time)
    var seq_start    : Int   # set after HEADER phase newline is found
    var sep_start    : Int   # set after SEQ phase newline is found
    var qual_start   : Int   # set after SEP phase newline is found
    var record_end   : Int   # set after QUAL phase newline is found (or EOF)

    @always_inline
    fn is_complete(self) -> Bool:
        return self.record_end != 0

    


@doc_private
@register_passable("trivial")
@fieldwise_init
struct SearchPhase(Copyable, Equatable, Movable, Writable):
    """
    Tracks which line boundary we are currently looking for within a 4-line
    FASTQ record.  Values are ordered so that `<=` comparisons work correctly
    in the resume-scan logic (mirrors Rust's PartialOrd on SearchPosition).

    HEADER   (0) – seeking the '\\n' that ends the '@id...' line
    SEQ      (1) – seeking the '\\n' that ends the sequence line
    SEP      (2) – seeking the '\\n' that ends the '+' separator line
    QUAL     (3) – seeking the '\\n' that ends the quality line
    """
    var value: Int8

    comptime HEADER = Self(0)
    comptime SEQ    = Self(1)
    comptime SEP    = Self(2)
    comptime QUAL   = Self(3)

    @always_inline
    fn __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    @always_inline
    fn __le__(self, other: Self) -> Bool:
        return self.value <= other.value
    
    fn write_to(self, mut writer: Some[Writer]):
        writer.write(self.value)
    


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




# From extramojo pacakge, skipping version problems
@always_inline("nodebug")
@doc_private
fn memchr(haystack: Span[UInt8], chr: UInt8, start: Int = 0) -> Int:
    """
    Function to find the next occurrence of character.
    Args:
        haystack: The bytes to search for the `chr`.
        chr: The byte to search for.
        start: The starting point to begin the search in `haystack`.

    Returns:
        The index of the found character, or -1 if not found.
    """

    comptime CASCADE = build_cascade[SIMD_U8_WIDTH]()

    if (len(haystack) - start) < SIMD_U8_WIDTH:
        for i in range(start, len(haystack)):
            if haystack[i] == chr:
                return i
        return -1

    # Do an unaligned initial read, it doesn't matter that this will overlap the next portion
    var ptr = haystack[start:].unsafe_ptr()


    # Find the last aligned end
    var haystack_len = len(haystack) - start
    var aligned_end = math.align_down(
        haystack_len, SIMD_U8_WIDTH
    )  

    # Now do aligned reads all through
    for s in range(0, aligned_end, SIMD_U8_WIDTH):
        var v = ptr.load[width=SIMD_U8_WIDTH](s)
        var mask = v.eq(chr)
        var packed = pack_bits(mask)
        if packed:
            var index = Int(count_trailing_zeros(packed))
            return s + index + start

    
    var tail_start = aligned_end  # relative to ptr base (haystack[start:])
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
    var tail_off = tail_start 

    @parameter
    for i in range(len(CASCADE)):
        comptime w = CASCADE[i]
        @parameter
        if w >= 1:                    # compile-time: elides dead branches
            if tail_len >= w:         # runtime check
                var result = check_tail[w](tail_ptr, tail_off)
                if result != -1:
                    return result
                tail_ptr = tail_ptr + w
                tail_off = tail_off + w
                tail_len -= w

    return -1


@parameter
@doc_private
fn build_cascade[W: Int]() -> List[Int]:
    """Generate [W//2, W//4, ..., 1] stopping before duplicates or zeros."""
    var result = List[Int]()
    var w = W // 2
    while w >= 1:
        result.append(w)
        w = w // 2
    return result^


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



# Optimized posix_space check using bitmask lookup
@doc_private
@always_inline
fn is_posix_space(c: UInt8) -> Bool:
    # Precomputed bitmask for ASCII 0-63.
    # Bits set: 9(\t), 10(\n), 11(\v), 12(\f), 13(\r), 28(FS), 29(GS), 30(RS), 32(Space)
    comptime MASK: UInt64 = (1 << 9) | (1 << 10) | (1 << 11) | (1 << 12) | (1 << 13) | 
                         (1 << 28) | (1 << 29) | (1 << 30) | (1 << 32)

    # If c > 63, it's definitely not one of our space characters.
    if c > 63:
        return False

    # Check if the 'c-th' bit is set in our mask
    return ((MASK >> c.cast[DType.uint64]()) & 1) != 0


@always_inline
fn _check_end_qual(
    buf     : BufferedReader,
    base    : Int,
    mut offsets : RecordOffsets,
) raises -> Tuple[Bool, RecordOffsets]:
    """
    Handle EOF with no trailing newline on quality line.
    If there is non-whitespace data from qual_start to buf._end, treat
    buf._end - base as record_end (no newline = last byte of file).
    Mirrors Rust check_end() QUAL branch: end = self.get_buf().len()
    """
    var rest_start = base + offsets.qual_start
    var rest = Span[Byte, MutExternalOrigin](
        ptr=buf._ptr + rest_start,
        length=buf._end - rest_start,
    )

    # Allow file to end with blank lines (mirrors Rust check_end blank-line check)
    var all_blank = True
    for i in range(len(rest)):
        var b = rest[i]
        if b != new_line and b != carriage_return and b != ord(' ') and b != ord('\t'):
            all_blank = False
            break

    if all_blank:
        return (False, offsets)   # EOF with only whitespace → no more records

    # Non-blank quality data with no trailing newline → valid last record
    offsets.record_end = buf._end - base
    return (True, offsets)


@always_inline
fn _phase_start_offset(offsets: RecordOffsets, phase: SearchPhase) -> Int:
    """Return the relative-to-base offset at which to resume scanning.

    When resuming a partially-scanned record (phase > HEADER), we start from
    the field that the current phase is *seeking the end of*, not from the
    beginning of the record. This avoids re-scanning already-processed bytes.

    HEADER → scan from header_start (always 0 for a fresh record)
    SEQ    → scan from seq_start    (header newline already found)
    SEP    → scan from sep_start    (sequence newline already found)
    QUAL   → scan from qual_start   (separator newline already found)
    """
    if phase == SearchPhase.HEADER:
        return offsets.header_start
    elif phase == SearchPhase.SEQ:
        return offsets.seq_start
    elif phase == SearchPhase.SEP:
        return offsets.sep_start
    else:  # QUAL
        return offsets.qual_start


# ---------------------------------------------------------------------------
# Helper: _phase_to_count
# ---------------------------------------------------------------------------

@always_inline
fn _phase_to_count(phase: SearchPhase) -> Int:
    """Return how many newlines have already been found given the current phase.

    The phase describes which newline we are *currently seeking*:
      HEADER → 0 found so far (seeking 1st newline: end of @id line)
      SEQ    → 1 found so far (seeking 2nd newline: end of sequence line)
      SEP    → 2 found so far (seeking 3rd newline: end of + separator line)
      QUAL   → 3 found so far (seeking 4th newline: end of quality line)
    """
    return Int(phase.value)


# ---------------------------------------------------------------------------
# Helper: _count_to_phase
# ---------------------------------------------------------------------------

@always_inline
fn _count_to_phase(found: Int) -> SearchPhase:
    """Convert a found-newlines count back to the SearchPhase we are now in.

    After finding `found` newlines we are seeking the (found+1)-th newline,
    which corresponds to the phase with value `found` (clamped to QUAL=3
    in case found >= 4, though the caller should not call this when
    found == 4 since the record is complete).

      0 found → HEADER  (still seeking end of @id line)
      1 found → SEQ     (still seeking end of sequence line)
      2 found → SEP     (still seeking end of + line)
      3 found → QUAL    (still seeking end of quality line)
      4 found → HEADER  (record complete; reset for next record)
    """
    if found >= 4:
        return SearchPhase.HEADER   # record complete; caller checks Bool
    return SearchPhase(Int8(found))


# ---------------------------------------------------------------------------
# Helper: _record_offsets_from_phase
# Returns a mutated copy of offsets with abs_pos written to the right field.
# Kept out of the hot loop body to keep the loop tight.
# ---------------------------------------------------------------------------

@always_inline
fn _store_newline_offset(
    mut offsets: RecordOffsets,
    found: Int,        # 1-indexed: which newline this is (1..4)
    abs_pos: Int,      # relative-to-base position AFTER the '\n'
):
    """Write the abs_pos (first byte of the *next* line) into the correct
    RecordOffsets field based on which newline was just found.

    found == 1 → seq_start   (byte after end-of-header newline)
    found == 2 → sep_start   (byte after end-of-sequence newline)
    found == 3 → qual_start  (byte after end-of-separator newline)
    found == 4 → record_end  (last byte of quality, i.e. abs_pos - 1)
    """
    if found == 1:
        offsets.seq_start  = abs_pos
    elif found == 2:
        offsets.sep_start  = abs_pos
    elif found == 3:
        offsets.qual_start = abs_pos
    else:  # found == 4
        offsets.record_end = abs_pos - 1   # record_end is inclusive last qual byte


# ---------------------------------------------------------------------------
# _scan_record_fused: single-pass SIMD scan for all four FASTQ newlines
# ---------------------------------------------------------------------------

@always_inline
fn _scan_record[o: Origin](
    view: Span[Byte, o],
    mut offsets: RecordOffsets,
    phase: SearchPhase,
) -> Tuple[Bool, RecordOffsets, SearchPhase]:
    """Locate all four record-bounding newlines in a single forward pass.

    Replaces four sequential `_find_newline_from` / `memchr` calls with one
    SIMD sweep. On a typical 150 bp Illumina record (~200 bytes total) this
    reduces the number of SIMD iterations from 4 × ⌈200/W⌉ to ⌈200/W⌉.

    Resumable: `phase` and `offsets` carry state from a previous incomplete
    scan so bytes before `_phase_start_offset(offsets, phase)` are never
    re-examined (mirrors the resume semantics of the original `_scan_record`).

    Args:
        view:    The byte span to scan (e.g. buffer view from BufferedReader
                 or any other contiguous byte slice). Offsets are relative to
                 view[0].
        offsets: Partially-populated offsets; fields for already-found newlines
                 are preserved and only the remaining fields are written.
        phase:   Which newline we are currently seeking.

    Returns:
        (complete, offsets, phase)
        complete=True  → all four newlines found; offsets fully populated.
        complete=False → ran out of buffer; offsets partially populated;
                         phase indicates where to resume on the next call.
    """
    comptime W = SIMD_U8_WIDTH
    comptime nl_splat = SIMD[DType.uint8, W](new_line)

    # ── Determine where to start scanning ────────────────────────────────────
    var start_rel = _phase_start_offset(offsets, phase)
    var scan_span = view[start_rel:]
    var ptr       = scan_span.unsafe_ptr()
    var avail     = len(scan_span)

    if avail <= 0:
        return (False, offsets, phase)

    # How many newlines already found (= how many offsets fields are set)
    var found = _phase_to_count(phase)

    # ── SIMD aligned section ──────────────────────────────────────────────────
    var i       = 0
    var aligned = math.align_down(avail, W)

    while i < aligned and found < 4:
        var v    = ptr.load[width=W](i)
        var mask = pack_bits(v.eq(nl_splat))

        # Drain all set bits from this SIMD word before moving to the next.
        # Inner loop is ≤ 4 iterations total across the whole outer loop.
        while mask != 0 and found < 4:
            var bit     = Int(count_trailing_zeros(mask))
            var abs_pos = start_rel + i + bit + 1   # first byte of next line
            found      += 1
            _store_newline_offset(offsets, found, abs_pos)
            mask        &= mask - 1                  # clear lowest set bit
        i += W

    if found == 4:
        return (True, offsets, SearchPhase.HEADER)

    # ── Scalar tail: bytes [aligned, avail) ──────────────────────────────────
    # Handles the final < W bytes that the SIMD loop could not process, and
    # also the case where the entire record is smaller than one SIMD word.
    i = aligned
    while i < avail and found < 4:
        if ptr[i] == new_line:
            var abs_pos = start_rel + i + 1
            found      += 1
            _store_newline_offset(offsets, found, abs_pos)
        i += 1

    return (found == 4, offsets, _count_to_phase(found))


@always_inline
fn _find_newline_from(
    buf     : BufferedReader,
    base : Int,      # absolute _ptr offset of view()[0] (buf._head at scan start)
    _from : Int,      # relative offset from base to start searching
) -> Int:
    """
    Search for '\\n' in buffer starting at absolute offset (base + from).
    Returns relative offset of the byte AFTER the '\\n' (i.e. start of next
    line), or -1 if no '\\n' found before buf._end.

    Mirrors Rust's find_line() which returns `search_start + pos + 1`.
    """
    var abs_start = base + _from
    var avail = buf._end - abs_start
    if avail <= 0:
        return -1
    var view = Span[Byte, MutExternalOrigin](
        ptr = buf._ptr + abs_start,
        length = avail,
    )
    var pos = memchr(haystack=view, chr=new_line)
    if pos < 0:
        return -1
    return _from + pos + 1   # relative to base; +1 skips past the '\n'


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
    return schema


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


