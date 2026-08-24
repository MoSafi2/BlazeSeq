"""Record-source backends for `FastqParser`.

A source owns the input bytes and knows how to locate the next complete
FASTQ record within them. Two backends exist:

- `BufferedSource[R]`: chunked reads through `BufferedReader`, with
  compaction, optional growth, and mid-record resume scanning.
- `MmapSource`: zero-copy memory-mapped file; the window is always the rest
  of the mapping, so no refill logic exists.

Both expose the same static interface (resolved per-instantiation, no
dynamic dispatch):

- `find_next[mode]() -> FoundRecord` — locate the next record; raises
  `EOFError` when the input is exhausted, `Error` with formatted message on
  malformed input.
- `has_more() -> Bool`
- `context() -> ParseContext` — position info for error messages.

The parser above this layer (`FastqParser`) builds views, runs optional
validation, and drives iteration identically for both.
"""

from blazeseq.io.buffered import EOFError, BufferedReader
from blazeseq.io.mapped import MappedFile
from blazeseq.io.readers import Reader
from std.pathlib import Path
from blazeseq.errors import (
    FastxErrorCode,
    ParseContext,
    format_parse_error_from_code,
    raise_parse_error,
)
from blazeseq.fastq.scan import (
    _check_end_qual,
    _scan_by_mode,
    _record_snippet,
    RecordOffsets,
    SearchPhase,
)
from blazeseq.utils import _strip_spaces
from blazeseq.fastq.record import FastqView


comptime SOURCE_BUFFERED: Int8 = 0
comptime SOURCE_MMAP: Int8 = 1


@fieldwise_init
struct FoundRecord(Copyable, Movable):
    """Location of one complete record inside the source's memory."""

    var base: Pointer[Byte, MutUntrackedOrigin]
    var offsets: RecordOffsets


struct BufferedSource[
    R: Reader,
    buffer_capacity: Int,
    buffer_growth_enabled: Bool,
    buffer_max_capacity: Int,
](Movable):
    """Chunked-read source over any `Reader` (file, gzip stream, memory)."""

    var reader: BufferedReader[Self.R]
    var _max_capacity: Int
    var _current_line_number: Int

    def __init__(out self, var reader: Self.R) raises:
        self.reader = BufferedReader(reader^, Self.buffer_capacity)
        self._max_capacity = Self.buffer_max_capacity
        self._current_line_number = 0

    @always_inline
    def context(self) -> ParseContext:
        return ParseContext(
            self._current_line_number // 4,
            self._current_line_number,
            Int64(self.reader.stream_position()),
        )

    @always_inline
    def note_consumed(mut self):
        self._current_line_number += 4

    @always_inline
    def has_more(self) -> Bool:
        return self.reader.available() > 0 or not self.reader.is_eof()

    def find_next[
        mode: Int8,
    ](mut self) raises -> FoundRecord:
        if self.reader.available() == 0:
            _ = self.reader.compact_and_fill()
        if not self.has_more():
            raise EOFError()

        var base = self.reader.buffer_position()
        var offsets = RecordOffsets()
        var phase = SearchPhase.HEADER

        var scan_view = Span[Byte, MutUntrackedOrigin](
            unsafe_ptr=self.reader._ptr.unsafe_offset(base),
            length=self.reader._end - base,
        )
        var complete: Bool
        var parse_code: FastxErrorCode
        complete, offsets, phase, parse_code = _scan_by_mode[mode](
            scan_view, offsets, phase
        )
        if parse_code != FastxErrorCode.OK:
            var ctx = self.context()
            raise_parse_error(
                ParseContext(
                    ctx.record_number + 1,
                    ctx.line_number + 1,
                    ctx.file_position,
                ),
                parse_code.message(),
                _record_snippet(scan_view, offsets),
            )
        var refill_code: FastxErrorCode
        if not complete:
            complete, offsets, phase, refill_code = self._next_ref_complete[
                mode
            ](base, offsets, phase)
            base = 0
            if refill_code == FastxErrorCode.EOF and not complete:
                raise EOFError()
            elif refill_code != FastxErrorCode.OK:
                raise Error(
                    self._refill_error_message(refill_code, phase, offsets)
                )
            if not complete:
                raise Error()

        var record_base = self.reader._ptr.unsafe_offset(base)
        var to_consume = offsets.record_end + 1
        _ = self.reader.consume(min(to_consume, self.reader._end - base))

        return FoundRecord(
            base=record_base,
            offsets=offsets,
        )

    @always_inline
    def _refill_error_message(
        self,
        refill_code: FastxErrorCode,
        phase: SearchPhase,
        offsets: RecordOffsets,
    ) -> String:
        var ctx = self.context()
        if (
            refill_code == FastxErrorCode.ID_NO_AT
            or refill_code == FastxErrorCode.SEP_NO_PLUS
            or refill_code == FastxErrorCode.SEQ_QUAL_LEN_MISMATCH
        ):
            return format_parse_error_from_code(
                refill_code,
                ctx.record_number + 1,
                ctx.line_number + 1,
                ctx.file_position,
                _record_snippet(self.reader.view(), offsets),
            )
        if refill_code == FastxErrorCode.UNEXPECTED_EOF:
            return "Unexpected end of file in FASTQ record at phase " + String(
                phase.value
            )
        if refill_code == FastxErrorCode.BUFFER_EXCEEDED:
            return (
                "FASTQ record exceeds buffer capacity ("
                + String(self.reader.capacity())
                + " bytes). Enable buffer growth or increase buffer_capacity."
            )
        return (
            "FASTQ record exceeds maximum buffer capacity ("
            + String(self._max_capacity)
            + " bytes). Enable buffer growth or increase max_capacity."
        )

    @always_inline
    def _next_ref_complete[
        mode: Int8,
    ](
        mut self,
        base: Int,
        mut offsets: RecordOffsets,
        phase: SearchPhase,
    ) raises -> Tuple[Bool, RecordOffsets, SearchPhase, FastxErrorCode]:
        """Refill/compact loop for records spanning the buffer edge."""
        var current_phase = phase
        var new_base = base
        while True:
            var buf_available = self.reader.available()
            var buf_capacity = self.reader.capacity()

            if buf_available < buf_capacity and self.reader.is_eof():
                if current_phase == SearchPhase.QUAL:
                    var got_record: Bool
                    got_record, offsets = _check_end_qual(
                        self.reader, new_base, offsets
                    )
                    return (
                        got_record,
                        offsets,
                        SearchPhase(Int8(new_base)),
                        FastxErrorCode.OK,
                    )
                else:
                    return (
                        False,
                        offsets,
                        current_phase,
                        FastxErrorCode.UNEXPECTED_EOF,
                    )

            if new_base == 0:
                comptime if not Self.buffer_growth_enabled:
                    return (
                        False,
                        offsets,
                        current_phase,
                        FastxErrorCode.BUFFER_EXCEEDED,
                    )
                var current_cap = self.reader.capacity()
                var max_cap = self._max_capacity
                if current_cap >= max_cap:
                    return (
                        False,
                        offsets,
                        current_phase,
                        FastxErrorCode.BUFFER_AT_MAX,
                    )
                var growth = min(current_cap, max_cap - current_cap)
                self.reader.resize_buffer(growth, max_cap)
            else:
                self.reader._compact_from(new_base)
                new_base = 0

            var filled = self.reader._fill_buffer()
            if filled == 0 and self.reader.available() == 0:
                return (False, offsets, current_phase, FastxErrorCode.EOF)

            var scan_view = Span[Byte, MutUntrackedOrigin](
                unsafe_ptr=self.reader._ptr.unsafe_offset(new_base),
                length=self.reader._end - new_base,
            )
            var complete: Bool
            var parse_code: FastxErrorCode
            complete, offsets, current_phase, parse_code = _scan_by_mode[mode](
                scan_view, offsets, current_phase
            )
            if complete:
                return (True, offsets, current_phase, parse_code)


struct MmapSource(Movable):
    """Zero-copy source over a memory-mapped file.

    Owns the mapping so record views remain valid for the parser's lifetime.
    """

    var map: MappedFile
    var _pos: Int
    var _current_line_number: Int

    def __init__(out self, path: Path) raises:
        self.map = MappedFile(path)
        self._pos = 0
        self._current_line_number = 0

    @always_inline
    def context(self) -> ParseContext:
        return ParseContext(
            self._current_line_number // 4,
            self._current_line_number,
            Int64(self._pos),
        )

    @always_inline
    def note_consumed(mut self):
        self._current_line_number += 4

    @always_inline
    def has_more(self) -> Bool:
        return self._pos < self.map.size()

    def find_next[
        mode: Int8,
    ](mut self) raises -> FoundRecord:
        if not self.has_more():
            raise EOFError()

        var n = self.map.size()
        var base_ptr = self.map.view().unsafe_ptr()
        var scan_view = Span[Byte, MutUntrackedOrigin](
            unsafe_ptr=base_ptr.unsafe_offset(self._pos),
            length=n - self._pos,
        )
        var offsets = RecordOffsets()
        var phase: SearchPhase
        var code: FastxErrorCode
        var complete: Bool
        complete, offsets, phase, code = _scan_by_mode[mode](
            scan_view, offsets, SearchPhase.HEADER
        )
        if code != FastxErrorCode.OK:
            var ctx = self.context()
            raise_parse_error(
                ParseContext(
                    ctx.record_number + 1,
                    ctx.line_number + 1,
                    ctx.file_position,
                ),
                code.message(),
                _record_snippet(scan_view, offsets),
            )
        if not complete:
            # End of mapping mid-record. Tolerate a final quality line
            # without its trailing newline when it holds non-whitespace
            # data; blank tail bytes mean clean EOF (mirrors the buffered
            # parser's `_check_end_qual`).
            var has_data = False
            if phase == SearchPhase.QUAL:
                var q = offsets.qual_start
                while q < len(scan_view):
                    var b = scan_view.unsafe_ptr()[unsafe_offset=q]
                    if b != Byte(10) and b != Byte(13) and b != Byte(32) and b != Byte(9):
                        has_data = True
                        break
                    q += 1
                if has_data:
                    offsets.record_end = len(scan_view)
                    complete = True
            if not complete:
                raise EOFError()

        self._pos += offsets.record_end + 1

        return FoundRecord(
            base=base_ptr.unsafe_offset(self._pos - (offsets.record_end + 1)),
            offsets=offsets,
        )


@always_inline
def build_record_view(
    found: FoundRecord, phred_offset: UInt8
) -> FastqView[origin=MutUntrackedOrigin]:
    """Construct a zero-copy record view from a located record."""
    var base_ptr = found.base

    var id_span = Span[Byte, MutUntrackedOrigin](
        unsafe_ptr=base_ptr.unsafe_offset(found.offsets.header_start + 1),
        length=(found.offsets.seq_start - found.offsets.header_start - 2),
    )
    var seq_span = Span[Byte, MutUntrackedOrigin](
        unsafe_ptr=base_ptr.unsafe_offset(found.offsets.seq_start),
        length=(found.offsets.sep_start - found.offsets.seq_start - 1),
    )
    var qual_span = Span[Byte, MutUntrackedOrigin](
        unsafe_ptr=base_ptr.unsafe_offset(found.offsets.qual_start),
        length=(found.offsets.record_end - found.offsets.qual_start),
    )

    return FastqView[origin=MutUntrackedOrigin](
        _strip_spaces(id_span),
        seq_span,
        qual_span,
        phred_offset,
    )
