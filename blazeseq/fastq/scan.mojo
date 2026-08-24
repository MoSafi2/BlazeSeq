"""FASTQ record-boundary scanning machinery.

SIMD newline scanners, record-offset bookkeeping (`RecordOffsets`,
`SearchPhase`), and structure validation used by the FASTQ parser.
Lives in `blazeseq.fastq` because every symbol here is FASTQ-specific.
"""

from std.memory import pack_bits
from std.bit import count_trailing_zeros
from std import math
from blazeseq.utils import memchr
from blazeseq.CONSTS import simd_width
from blazeseq.CONSTS import *
from blazeseq.io.buffered import BufferedReader
from blazeseq.errors import FastxErrorCode


@doc_hidden
@align(64)
struct RecordOffsets(Copyable, Movable, TrivialRegisterPassable, Writable):
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

    var header_start: Int  # always 0 for the first record; non-zero after
    # make_room shifts don't apply here (we re-anchor
    # to view()[0] each time)
    var seq_start: Int  # set after HEADER phase newline is found
    var sep_start: Int  # set after SEQ phase newline is found
    var qual_start: Int  # set after SEP phase newline is found
    var record_end: Int  # set after QUAL phase newline is found (or EOF)

    @always_inline
    def __init__(
        out self,
        header_start: Int = 0,
        seq_start: Int = 0,
        sep_start: Int = 0,
        qual_start: Int = 0,
        record_end: Int = 0,
    ):
        """
        Initializes a RecordOffsets instance with the given byte offsets for each line
        in a FASTQ record.

        Arguments:
            header_start (Int): Offset to the header ("@...") line start. Default is 0.
            seq_start    (Int): Offset to the sequence line start. Default is 0.
            sep_start    (Int): Offset to the '+' separator line start. Default is 0.
            qual_start   (Int): Offset to the quality line start. Default is 0.
            record_end   (Int): Offset to one past the last quality byte (end of record). Default is 0.

        All offsets are relative to buf._ptr + buf._head at the time of scan.
        """
        self.header_start = header_start
        self.seq_start = seq_start
        self.sep_start = sep_start
        self.qual_start = qual_start
        self.record_end = record_end

    @always_inline
    def is_complete(self) -> Bool:
        return self.record_end != 0


@doc_hidden
@fieldwise_init
struct SearchPhase(
    Copyable, Equatable, Movable, TrivialRegisterPassable, Writable
):
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
    comptime SEQ = Self(1)
    comptime SEP = Self(2)
    comptime QUAL = Self(3)

    @always_inline
    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    @always_inline
    def __le__(self, other: Self) -> Bool:
        return self.value <= other.value

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.value)


@always_inline
def _check_end_qual(
    buf: BufferedReader,
    base: Int,
    mut offsets: RecordOffsets,
) raises -> Tuple[Bool, RecordOffsets]:
    """
    Handle EOF with no trailing newline on quality line.
    If there is non-whitespace data from qual_start to buf._end, treat
    buf._end - base as record_end (no newline = last byte of file).
    Mirrors Rust check_end() QUAL branch: end = self.get_buf().len()
    """
    var rest_start = base + offsets.qual_start
    var rest = Span[Byte, MutUntrackedOrigin](
        unsafe_ptr=buf._ptr.unsafe_offset(rest_start),
        length=buf._end - rest_start,
    )

    # Allow file to end with blank lines (mirrors Rust check_end blank-line check)
    var all_blank = True
    for i in range(len(rest)):
        var b = rest[i]
        if (
            b != new_line
            and b != carriage_return
            and b != Byte(ord(" "))
            and b != Byte(ord("\t"))
        ):
            all_blank = False
            break

    if all_blank:
        return (False, offsets)  # EOF with only whitespace → no more records

    # Non-blank quality data with no trailing newline → valid last record
    offsets.record_end = buf._end - base
    return (True, offsets)


@always_inline
def _phase_start_offset(offsets: RecordOffsets, phase: SearchPhase) -> Int:
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
def _phase_to_count(phase: SearchPhase) -> Int:
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
def _count_to_phase(found: Int) -> SearchPhase:
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
        return SearchPhase.HEADER  # record complete; caller checks Bool
    return SearchPhase(Int8(found))


# ---------------------------------------------------------------------------
# Helper: _record_offsets_from_phase
# Returns a mutated copy of offsets with abs_pos written to the right field.
# Kept out of the hot loop body to keep the loop tight.
# ---------------------------------------------------------------------------


@always_inline
def _store_newline_offset(
    mut offsets: RecordOffsets,
    found: Int,  # 1-indexed: which newline this is (1..4)
    abs_pos: Int,  # relative-to-base position AFTER the '\n'
):
    """Write the abs_pos (first byte of the *next* line) into the correct
    RecordOffsets field based on which newline was just found.

    found == 1 → seq_start   (byte after end-of-header newline)
    found == 2 → sep_start   (byte after end-of-sequence newline)
    found == 3 → qual_start  (byte after end-of-separator newline)
    found == 4 → record_end  (last byte of quality, i.e. abs_pos - 1)
    """
    if found == 1:
        offsets.seq_start = abs_pos
    elif found == 2:
        offsets.sep_start = abs_pos
    elif found == 3:
        offsets.qual_start = abs_pos
    else:  # found == 4
        offsets.record_end = (
            abs_pos - 1
        )  # record_end is inclusive last qual byte


def _record_snippet[
    o: Origin
](view: Span[Byte, o], offsets: RecordOffsets) -> String:
    """First 200 bytes of the record for ParseError snippet."""
    var end = min(offsets.record_end + 1, len(view))
    end = min(end, 200)
    if end <= 0:
        return ""
    var sp = view[0:end]
    return String(StringSlice(unsafe_from_utf8=sp))


@always_inline
def _validate_fastq_structure_fast[
    o: Origin
](view: Span[Byte, o], offsets: RecordOffsets,) -> FastxErrorCode:
    """Validate scanner-complete records without bounds-check overhead.

    The scanner calls this only after finding all four line terminators, so
    every offset below is within ``view``. Raw pointer access avoids emitting
    the large bounds-check and diagnostic machinery in the hot path.
    """
    var ptr = view.unsafe_ptr()
    if ptr[unsafe_offset=offsets.header_start] != Byte(read_header):
        return FastxErrorCode.ID_NO_AT
    if ptr[unsafe_offset=offsets.sep_start] != Byte(quality_header):
        return FastxErrorCode.SEP_NO_PLUS
    var seq_len = offsets.sep_start - offsets.seq_start - 1
    var qual_len = offsets.record_end - offsets.qual_start
    if seq_len != qual_len:
        return FastxErrorCode.SEQ_QUAL_LEN_MISMATCH
    return FastxErrorCode.OK


# ---------------------------------------------------------------------------
# _scan_record variants: single-pass SIMD scans for all four FASTQ newlines
# ---------------------------------------------------------------------------


@always_inline
def _drain_newline_cmp[
    W: Int,
](
    mut offsets: RecordOffsets,
    found_in: Int,
    start_rel: Int,
    base_i: Int,
    cmp: SIMD[DType.bool, W],
) -> Int:
    var found = found_in
    var mask = pack_bits(cmp)

    while mask != 0 and found < 4:
        var bit = Int(count_trailing_zeros(mask))
        var abs_pos = start_rel + base_i + bit + 1
        found += 1
        _store_newline_offset(offsets, found, abs_pos)
        mask &= mask - 1

    return found


@always_inline
def _scan_record_optimized[
    o: Origin,
](
    view: Span[Byte, o],
    mut offsets: RecordOffsets,
    phase: SearchPhase,
) -> Tuple[Bool, RecordOffsets, SearchPhase, FastxErrorCode]:
    comptime W = simd_width
    comptime GROUP_W = 4 * W
    comptime nl_splat = SIMD[DType.uint8, W](new_line)

    var start_rel = _phase_start_offset(offsets, phase)
    var scan_span = view[start_rel:]
    var ptr = scan_span.unsafe_ptr()
    var avail = len(scan_span)

    if avail <= 0:
        return (False, offsets, phase, FastxErrorCode.OK)

    var found = _phase_to_count(phase)
    var i = 0

    # ── 4x SIMD grouped scan ────────────────────────────────────────────────
    #
    # This is the memchr-style shape:
    #
    #   load v0/v1/v2/v3
    #   compare all four against the same separator
    #   OR the bool vectors
    #   pack_bits once as a cheap group-level hit test
    #   only then pack individual vectors to locate exact offsets
    #
    # No-hit group: 4 loads + 4 compares + ORs + 1 pack_bits.
    # Old loop:     4 loads + 4 compares + 4 pack_bits.
    var grouped = math.align_down(avail, GROUP_W)

    while i < grouped and found < 4:
        var v0 = ptr.unsafe_load[width=W](i)
        var v1 = ptr.unsafe_load[width=W](i + W)
        var v2 = ptr.unsafe_load[width=W](i + 2 * W)
        var v3 = ptr.unsafe_load[width=W](i + 3 * W)

        var e0 = v0.eq(nl_splat)
        var e1 = v1.eq(nl_splat)
        var e2 = v2.eq(nl_splat)
        var e3 = v3.eq(nl_splat)

        var group_cmp = e0 | e1 | e2 | e3
        var group_mask = pack_bits(group_cmp)

        if group_mask != 0:
            found = _drain_newline_cmp[W](offsets, found, start_rel, i, e0)
            if found == 4:
                break

            found = _drain_newline_cmp[W](offsets, found, start_rel, i + W, e1)
            if found == 4:
                break

            found = _drain_newline_cmp[W](
                offsets, found, start_rel, i + 2 * W, e2
            )
            if found == 4:
                break

            found = _drain_newline_cmp[W](
                offsets, found, start_rel, i + 3 * W, e3
            )

        i += GROUP_W

    if found == 4:
        var code = _validate_fastq_structure_fast(view, offsets)
        return (True, offsets, SearchPhase.HEADER, code)

    # ── Remaining full SIMD chunks ──────────────────────────────────────────
    var aligned = math.align_down(avail, W)

    while i < aligned and found < 4:
        var v = ptr.unsafe_load[width=W](i)
        var cmp = v.eq(nl_splat)
        var mask = pack_bits(cmp)

        while mask != 0 and found < 4:
            var bit = Int(count_trailing_zeros(mask))
            var abs_pos = start_rel + i + bit + 1
            found += 1
            _store_newline_offset(offsets, found, abs_pos)
            mask &= mask - 1

        i += W

    if found == 4:
        var code = _validate_fastq_structure_fast(view, offsets)
        return (True, offsets, SearchPhase.HEADER, code)

    # ── Scalar tail ─────────────────────────────────────────────────────────
    while i < avail and found < 4:
        if ptr[unsafe_offset=i] == new_line:
            var abs_pos = start_rel + i + 1
            found += 1
            _store_newline_offset(offsets, found, abs_pos)

        i += 1

    if found == 4:
        var code = _validate_fastq_structure_fast(view, offsets)
        return (True, offsets, SearchPhase.HEADER, code)

    return (False, offsets, _count_to_phase(found), FastxErrorCode.OK)


@always_inline
def _scan_record_fused_old[
    o: Origin,
](
    view: Span[Byte, o],
    mut offsets: RecordOffsets,
    phase: SearchPhase,
) -> Tuple[Bool, RecordOffsets, SearchPhase, FastxErrorCode]:
    comptime W = simd_width
    comptime nl_splat = SIMD[DType.uint8, W](new_line)

    var start_rel = _phase_start_offset(offsets, phase)
    var scan_span = view[start_rel:]
    var ptr = scan_span.unsafe_ptr()
    var avail = len(scan_span)

    if avail <= 0:
        return (False, offsets, phase, FastxErrorCode.OK)

    var found = _phase_to_count(phase)
    var i = 0

    var aligned = math.align_down(avail, W)

    while i < aligned and found < 4:
        var v = ptr.unsafe_load[width=W](i)
        var cmp = v.eq(nl_splat)
        var mask = pack_bits(cmp)

        while mask != 0 and found < 4:
            var bit = Int(count_trailing_zeros(mask))
            var abs_pos = start_rel + i + bit + 1
            found += 1
            _store_newline_offset(offsets, found, abs_pos)
            mask &= mask - 1

        i += W

    if found == 4:
        var code = _validate_fastq_structure_fast(view, offsets)
        return (True, offsets, SearchPhase.HEADER, code)

    while i < avail and found < 4:
        if ptr[unsafe_offset=i] == new_line:
            var abs_pos = start_rel + i + 1
            found += 1
            _store_newline_offset(offsets, found, abs_pos)

        i += 1

    if found == 4:
        var code = _validate_fastq_structure_fast(view, offsets)
        return (True, offsets, SearchPhase.HEADER, code)

    return (False, offsets, _count_to_phase(found), FastxErrorCode.OK)


@always_inline
def _drain_newline_mask(
    mut offsets: RecordOffsets,
    found_in: Int,
    start_rel: Int,
    base_i: Int,
    mut mask: UInt64,
) -> Int:
    """Drain a precomputed newline bitmask (1 bit per byte chunk) into offsets."""
    var found = found_in
    while mask != 0 and found < 4:
        var bit = Int(count_trailing_zeros(mask))
        var abs_pos = start_rel + base_i + bit + 1
        found += 1
        _store_newline_offset(offsets, found, abs_pos)
        mask &= mask - 1
    return found


@always_inline
def _scan_record_masks[
    o: Origin,
](
    view: Span[Byte, o],
    mut offsets: RecordOffsets,
    phase: SearchPhase,
) -> Tuple[Bool, RecordOffsets, SearchPhase, FastxErrorCode]:
    """Grouped 4x SIMD scan with hoisted bitmask packing.

    Same shape as `_scan_record_optimized`, but all four `pack_bits`
    (`vpmovmskb`) issue back-to-back before any branch so their latency
    overlaps in the pipeline, and the hit path drains the precomputed masks
    instead of re-packing the compare vectors after the branch.
    """
    comptime W = simd_width
    comptime GROUP_W = 4 * W
    comptime nl_splat = SIMD[DType.uint8, W](new_line)

    var start_rel = _phase_start_offset(offsets, phase)
    var scan_span = view[start_rel:]
    var ptr = scan_span.unsafe_ptr()
    var avail = len(scan_span)

    if avail <= 0:
        return (False, offsets, phase, FastxErrorCode.OK)

    var found = _phase_to_count(phase)
    var i = 0

    # ── 4x SIMD grouped scan, masks packed up front ─────────────────────────
    var grouped = math.align_down(avail, GROUP_W)

    while i < grouped and found < 4:
        var v0 = ptr.unsafe_load[width=W](i)
        var v1 = ptr.unsafe_load[width=W](i + W)
        var v2 = ptr.unsafe_load[width=W](i + 2 * W)
        var v3 = ptr.unsafe_load[width=W](i + 3 * W)

        var m0 = UInt64(pack_bits(v0.eq(nl_splat)))
        var m1 = UInt64(pack_bits(v1.eq(nl_splat)))
        var m2 = UInt64(pack_bits(v2.eq(nl_splat)))
        var m3 = UInt64(pack_bits(v3.eq(nl_splat)))

        if (m0 | m1 | m2 | m3) != 0:
            found = _drain_newline_mask(offsets, found, start_rel, i, m0)
            if found == 4:
                break

            found = _drain_newline_mask(offsets, found, start_rel, i + W, m1)
            if found == 4:
                break

            found = _drain_newline_mask(
                offsets, found, start_rel, i + 2 * W, m2
            )
            if found == 4:
                break

            found = _drain_newline_mask(
                offsets, found, start_rel, i + 3 * W, m3
            )

        i += GROUP_W

    if found == 4:
        var code = _validate_fastq_structure_fast(view, offsets)
        return (True, offsets, SearchPhase.HEADER, code)

    # ── Remaining full SIMD chunks ──────────────────────────────────────────
    var aligned = math.align_down(avail, W)

    while i < aligned and found < 4:
        var v = ptr.unsafe_load[width=W](i)
        var mask = UInt64(pack_bits(v.eq(nl_splat)))

        while mask != 0 and found < 4:
            var bit = Int(count_trailing_zeros(mask))
            var abs_pos = start_rel + i + bit + 1
            found += 1
            _store_newline_offset(offsets, found, abs_pos)
            mask &= mask - 1

        i += W

    if found == 4:
        var code = _validate_fastq_structure_fast(view, offsets)
        return (True, offsets, SearchPhase.HEADER, code)

    # ── Scalar tail ─────────────────────────────────────────────────────────
    while i < avail and found < 4:
        if ptr[unsafe_offset=i] == new_line:
            var abs_pos = start_rel + i + 1
            found += 1
            _store_newline_offset(offsets, found, abs_pos)

        i += 1

    if found == 4:
        var code = _validate_fastq_structure_fast(view, offsets)
        return (True, offsets, SearchPhase.HEADER, code)

    return (False, offsets, _count_to_phase(found), FastxErrorCode.OK)


comptime SCAN_MODE_OPTIMIZED: Int8 = 0
comptime SCAN_MODE_MASKS: Int8 = 1
comptime SCAN_MODE_FUSED_OLD: Int8 = 2
comptime SCAN_MODE_MEMCHR_SEQ: Int8 = 3


@always_inline
def _scan_by_mode[
    mode: Int8,
    o: Origin,
](
    view: Span[Byte, o],
    mut offsets: RecordOffsets,
    phase: SearchPhase,
) -> Tuple[Bool, RecordOffsets, SearchPhase, FastxErrorCode]:
    """Comptime dispatch to a `_scan_record_*` variant by scan mode id."""
    comptime if mode == SCAN_MODE_MASKS:
        return _scan_record_masks(view, offsets, phase)
    elif mode == SCAN_MODE_FUSED_OLD:
        return _scan_record_fused_old(view, offsets, phase)
    elif mode == SCAN_MODE_MEMCHR_SEQ:
        return _scan_record_memchr_seq(view, offsets, phase)
    else:
        return _scan_record_optimized(view, offsets, phase)


@always_inline
def _scan_record[
    o: Origin,
](
    view: Span[Byte, o],
    mut offsets: RecordOffsets,
    phase: SearchPhase,
) -> Tuple[Bool, RecordOffsets, SearchPhase, FastxErrorCode]:
    return _scan_record_optimized(view, offsets, phase)


@always_inline
def _scan_record_memchr_seq[
    o: Origin
](
    view: Span[Byte, o],
    mut offsets: RecordOffsets,
    phase: SearchPhase,
) -> Tuple[Bool, RecordOffsets, SearchPhase, FastxErrorCode]:
    """Locate FASTQ record newlines using sequential memchr calls.

    Mirrors `_scan_record` semantics but searches for each remaining newline
    one-by-one with `memchr`.
    """
    var search_from = _phase_start_offset(offsets, phase)
    var found = _phase_to_count(phase)

    while found < 4:
        var pos = memchr(haystack=view, chr=new_line, start=search_from)
        if pos < 0:
            return (False, offsets, _count_to_phase(found), FastxErrorCode.OK)

        var abs_pos = pos + 1
        found += 1
        _store_newline_offset(offsets, found, abs_pos)
        search_from = abs_pos

    var code = _validate_fastq_structure_fast(view, offsets)
    return (True, offsets, SearchPhase.HEADER, code)
