from blazeseq.fastq.record import FastqRecord, FastqView, Validator
from blazeseq.CONSTS import *
from blazeseq.fastq.quality_schema import QualitySchema, generic_schema
from blazeseq.io.buffered import EOFError, BufferedReader
from blazeseq.io.readers import Reader
from blazeseq.fastq.record_batch import FastqBatch, DEFAULT_BATCH_SIZE
from blazeseq.errors import (
    ParseError,
    ValidationError,
    FastxErrorCode,
    ParseContext,
    format_parse_error,
    format_parse_error_from_code,
    format_validation_error_from_code,
    buffer_capacity_error,
    raise_parse_error,
    raise_validation_error,
)
from std.iter import Iterator
from blazeseq.byte_string import BString
from blazeseq.utils import _strip_spaces
from blazeseq.fastq.quality_schema import _parse_schema
from blazeseq.fastq.scan import (
    _check_end_qual,
    _scan_by_mode,
    SCAN_MODE_MASKS,
    SCAN_MODE_MEMCHR_SEQ,
    _record_snippet,
    RecordOffsets,
    SearchPhase,
)


struct ParserConfig(Copyable):
    """
    Configuration struct for FASTQ parser options.

    Centralizes buffer capacity, growth policy, validation flags, and quality
    schema settings. Pass as a comptime parameter to `FastqParser`, e.g.
    `FastqParser[FileReader, ParserConfig(check_ascii=False)]`.

    Attributes:
        buffer_capacity: Size in bytes of the internal read buffer. Larger
            values can improve throughput for large files but use more memory.
        buffer_max_capacity: Maximum buffer size when growth is enabled.
        buffer_growth_enabled: If True, buffer grows when a line exceeds
            buffer_capacity, up to buffer_max_capacity. Disable for fixed memory.
        check_ascii: If True, validate that all record bytes are ASCII.
        check_quality: If True, validate quality bytes against the quality schema.
        quality_schema: Optional schema name; used when not passed to `__init__`.
            One of: "generic", "sanger", "solexa", "illumina_1.3", "illumina_1.5", "illumina_1.8".
    """

    var buffer_capacity: Int
    var buffer_max_capacity: Int
    var buffer_growth_enabled: Bool
    var check_ascii: Bool
    var check_quality: Bool
    var quality_schema: Optional[String]

    def __init__(
        out self,
        buffer_capacity: Int = DEFAULT_CAPACITY,
        buffer_max_capacity: Int = MAX_CAPACITY,
        buffer_growth_enabled: Bool = False,
        check_ascii: Bool = False,
        check_quality: Bool = False,
        quality_schema: Optional[String] = None,
    ):
        self.buffer_capacity = buffer_capacity
        self.buffer_max_capacity = buffer_max_capacity
        self.buffer_growth_enabled = buffer_growth_enabled
        self.check_ascii = check_ascii
        self.check_quality = check_quality
        self.quality_schema = quality_schema


struct FastqParser[R: Reader, config: ParserConfig = ParserConfig()](Movable):
    """
    Unified FASTQ parser over a `Reader`.
    """

    var buffer: BufferedReader[Self.R]
    var quality_schema: QualitySchema
    var validator: Validator
    var _batch_size: Int
    var _max_capacity: Int
    var _current_line_number: Int

    def __init__(
        out self,
        var reader: Self.R,
    ) raises:
        self.buffer = BufferedReader(reader^, self.config.buffer_capacity)
        self._max_capacity = self.config.buffer_max_capacity
        self._current_line_number = 0
        if self.config.quality_schema:
            self.quality_schema = _parse_schema(
                self.config.quality_schema.value()
            )
        else:
            self.quality_schema = materialize[generic_schema]()
        self.validator = Validator(
            self.config.check_ascii,
            self.config.check_quality,
            self.quality_schema.copy(),
        )
        self._batch_size = DEFAULT_BATCH_SIZE

    def __init__(
        out self,
        var reader: Self.R,
        quality_schema: String,
    ) raises:
        self.buffer = BufferedReader(reader^, self.config.buffer_capacity)
        self._max_capacity = self.config.buffer_max_capacity
        self._current_line_number = 0
        self.quality_schema = _parse_schema(quality_schema)
        self.validator = Validator(
            self.config.check_ascii,
            self.config.check_quality,
            self.quality_schema.copy(),
        )
        self._batch_size = DEFAULT_BATCH_SIZE

    def __init__(
        out self,
        var reader: Self.R,
        batch_size: Int,
        schema: String = "generic",
    ) raises:
        self.buffer = BufferedReader(reader^, self.config.buffer_capacity)
        self._max_capacity = self.config.buffer_max_capacity
        self._current_line_number = 0
        if self.config.quality_schema:
            self.quality_schema = _parse_schema(
                self.config.quality_schema.value()
            )
        else:
            self.quality_schema = _parse_schema(schema)
        self.validator = Validator(
            self.config.check_ascii,
            self.config.check_quality,
            self.quality_schema.copy(),
        )
        self._batch_size = batch_size

    @always_inline
    def _parse_context(ref self) -> ParseContext:
        return ParseContext(
            self._current_line_number // 4,
            self._current_line_number,
            Int64(self.buffer.stream_position()),
        )

    @always_inline
    def has_more(self) -> Bool:
        return self.buffer.available() > 0 or not self.buffer.is_eof()

    @always_inline
    def next_view(mut self) raises -> FastqView[origin=MutUntrackedOrigin]:
        var ref_rec = self._find_and_consume_ref_record()
        self._raise_if_invalid_view(ref_rec)
        return ref_rec

    @always_inline
    def next_view_memchr_seq(
        mut self,
    ) raises -> FastqView[origin=MutUntrackedOrigin]:
        """Benchmark-only variant that scans record boundaries via sequential memchr.
        """
        var ref_rec = self._find_and_consume_ref_record_memchr_seq()
        self._raise_if_invalid_view(ref_rec)
        return ref_rec

    @always_inline
    def next_record(mut self) raises -> FastqRecord:
        if not self.has_more():
            raise EOFError()
        var ref_rec = self._find_and_consume_ref_record()
        return self._record_from_view(ref_rec)

    @always_inline
    def next_record_memchr_seq(mut self) raises -> FastqRecord:
        """Benchmark-only variant that scans record boundaries via sequential memchr.
        """
        if not self.has_more():
            raise EOFError()
        var ref_rec = self._find_and_consume_ref_record_memchr_seq()
        return self._record_from_view(ref_rec)

    @always_inline
    def _raise_if_invalid_view(
        self, ref_rec: FastqView[origin=MutUntrackedOrigin]
    ) raises:
        var code = self.validator._validate(ref_rec)
        if code != FastxErrorCode.OK:
            raise_validation_error(
                self._parse_context(),
                code.message(),
                "",
                self._get_record_snippet(ref_rec),
            )

    @always_inline
    def next_view_masks(
        mut self,
    ) raises -> FastqView[origin=MutUntrackedOrigin]:
        """Benchmark-only variant using the hoisted-mask SIMD scanner."""
        var ref_rec = self._find_and_consume_ref_record_scan[
            SCAN_MODE_MASKS
        ]()
        self._raise_if_invalid_view(ref_rec)
        return ref_rec

    @always_inline
    def next_record_masks(mut self) raises -> FastqRecord:
        if not self.has_more():
            raise EOFError()
        return self._record_from_view(self.next_view_masks())

    @always_inline
    def _record_from_view(
        mut self, ref_rec: FastqView[origin=MutUntrackedOrigin]
    ) raises -> FastqRecord:
        var record: FastqRecord
        try:
            record = FastqRecord(
                ref_rec._id,
                ref_rec._sequence,
                ref_rec._quality,
                Int8(self.quality_schema.OFFSET),
            )
        except e:
            raise Error(format_parse_error(self._parse_context(), String(e)))
        var code = self.validator._validate(record)
        if code != FastxErrorCode.OK:
            raise_validation_error(
                self._parse_context(),
                code.message(),
                "",
                self._get_record_snippet_from_fastq(record),
            )
        return record^

    def next_batch(
        mut self, max_records: Int = DEFAULT_BATCH_SIZE
    ) raises -> FastqBatch:
        var limit = max_records if max_records else self._batch_size
        var batch = FastqBatch(batch_size=limit)
        while len(batch) < limit and self.has_more():
            try:
                batch.add(self.next_view())
            except e:
                if String(e) == EOF or String(e).startswith(EOF):
                    break
                raise e^
        return batch^

    def views(
        ref self,
    ) -> _FastqParserViewIter[Self.R, Self.config, origin_of(self)]:
        return _FastqParserViewIter[Self.R, Self.config, origin_of(self)](
            Pointer(to=self)
        )

    def records(
        ref self,
    ) -> _FastqParserRecordIter[Self.R, Self.config, origin_of(self)]:
        return _FastqParserRecordIter[Self.R, Self.config, origin_of(self)](
            Pointer(to=self)
        )

    def batches(
        ref self,
        max_records: Optional[Int] = None,
    ) -> _FastqParserBatchIter[Self.R, Self.config, origin_of(self)]:
        var limit = max_records.value() if max_records else self._batch_size
        return _FastqParserBatchIter[Self.R, Self.config, origin_of(self)](
            Pointer(to=self), limit
        )

    def _refill_error_message(
        self,
        refill_code: FastxErrorCode,
        phase: SearchPhase,
        offsets: RecordOffsets,
    ) -> String:
        if (
            refill_code == FastxErrorCode.ID_NO_AT
            or refill_code == FastxErrorCode.SEP_NO_PLUS
            or refill_code == FastxErrorCode.SEQ_QUAL_LEN_MISMATCH
        ):
            var ctx = self._parse_context()
            return format_parse_error_from_code(
                refill_code,
                ctx.record_number + 1,
                ctx.line_number + 1,
                ctx.file_position,
                _record_snippet(self.buffer.view(), offsets),
            )
        if refill_code == FastxErrorCode.UNEXPECTED_EOF:
            return "Unexpected end of file in FASTQ record at phase " + String(
                phase.value
            )
        if refill_code == FastxErrorCode.BUFFER_EXCEEDED:
            return (
                "FASTQ record exceeds buffer capacity ("
                + String(self.buffer.capacity())
                + " bytes). Enable buffer growth or increase buffer_capacity."
            )
        return (
            "FASTQ record exceeds maximum buffer capacity ("
            + String(self._max_capacity)
            + " bytes). Enable buffer growth or increase max_capacity."
        )

    @always_inline
    def _find_and_consume_ref_record(
        mut self,
    ) raises -> FastqView[origin=MutUntrackedOrigin]:
        return self._find_and_consume_ref_record_scan[SCAN_MODE_MASKS]()

    @always_inline
    def _find_and_consume_ref_record_memchr_seq(
        mut self,
    ) raises -> FastqView[origin=MutUntrackedOrigin]:
        return self._find_and_consume_ref_record_scan[SCAN_MODE_MEMCHR_SEQ]()

    @always_inline
    def _find_and_consume_ref_record_scan[
        mode: Int8,
    ](mut self) raises -> FastqView[origin=MutUntrackedOrigin]:
        """Scan-mode-generic core record finder.

        Identical to `_find_and_consume_ref_record` but dispatches the SIMD
        scan via comptime `mode` (`SCAN_MODE_*` constants).
        """
        if self.buffer.available() == 0:
            _ = self.buffer.compact_and_fill()
        if not self.has_more():
            raise EOFError()

        var base = self.buffer.buffer_position()
        var offsets = RecordOffsets()
        var phase = SearchPhase.HEADER

        var scan_view = Span[Byte, MutUntrackedOrigin](
            unsafe_ptr=self.buffer._ptr.unsafe_offset(base),
            length=self.buffer._end - base,
        )
        var complete: Bool
        var parse_code: FastxErrorCode
        complete, offsets, phase, parse_code = _scan_by_mode[mode](
            scan_view, offsets, phase
        )
        if parse_code != FastxErrorCode.OK:
            var ctx = self._parse_context()
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
            complete, offsets, phase, refill_code = self._next_ref_complete_scan[
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

        var buffer_view = self.buffer.view().unsafe_ptr()

        var id_span = Span[Byte, MutUntrackedOrigin](
            unsafe_ptr=buffer_view.unsafe_offset(offsets.header_start + 1),
            length=(offsets.seq_start - offsets.header_start - 2),
        )
        var seq_span = Span[Byte, MutUntrackedOrigin](
            unsafe_ptr=buffer_view.unsafe_offset(offsets.seq_start),
            length=(offsets.sep_start - offsets.seq_start - 1),
        )
        var qual_span = Span[Byte, MutUntrackedOrigin](
            unsafe_ptr=buffer_view.unsafe_offset(offsets.qual_start),
            length=(offsets.record_end - offsets.qual_start),
        )

        var ref_rec = FastqView[origin=MutUntrackedOrigin](
            _strip_spaces(id_span),
            seq_span,
            qual_span,
            self.quality_schema.OFFSET,
        )

        var to_consume = offsets.record_end + 1
        _ = self.buffer.consume(min(to_consume, self.buffer._end - base))
        self._current_line_number += 4

        return ref_rec

    @always_inline
    def _next_ref_complete_scan[
        mode: Int8,
    ](
        mut self,
        base: Int,
        mut offsets: RecordOffsets,
        phase: SearchPhase,
    ) raises -> Tuple[Bool, RecordOffsets, SearchPhase, FastxErrorCode]:
        """Scan-mode-generic refill loop; mirrors `_next_ref_complete`."""
        var current_phase = phase
        var new_base = base
        while True:
            var buf_available = self.buffer.available()
            var buf_capacity = self.buffer.capacity()

            if buf_available < buf_capacity and self.buffer.is_eof():
                if current_phase == SearchPhase.QUAL:
                    var got_record: Bool
                    got_record, offsets = _check_end_qual(
                        self.buffer, new_base, offsets
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
                comptime if not self.config.buffer_growth_enabled:
                    return (
                        False,
                        offsets,
                        current_phase,
                        FastxErrorCode.BUFFER_EXCEEDED,
                    )
                var current_cap = self.buffer.capacity()
                var max_cap = self._max_capacity
                if current_cap >= max_cap:
                    return (
                        False,
                        offsets,
                        current_phase,
                        FastxErrorCode.BUFFER_AT_MAX,
                    )
                var growth = min(current_cap, max_cap - current_cap)
                self.buffer.resize_buffer(growth, max_cap)
            else:
                self.buffer._compact_from(new_base)
                new_base = 0

            var filled = self.buffer._fill_buffer()
            if filled == 0 and self.buffer.available() == 0:
                return (False, offsets, current_phase, FastxErrorCode.EOF)

            var scan_view = Span[Byte, MutUntrackedOrigin](
                unsafe_ptr=self.buffer._ptr.unsafe_offset(new_base),
                length=self.buffer._end - new_base,
            )
            var complete: Bool
            var parse_code: FastxErrorCode
            complete, offsets, current_phase, parse_code = _scan_by_mode[mode](
                scan_view, offsets, current_phase
            )
            if complete:
                return (True, offsets, current_phase, parse_code)

    def _get_record_snippet(self, record: FastqView) -> String:
        var snippet = String(capacity=200)
        var id_str = StringSlice(unsafe_from_utf8=record._id)
        if id_str.byte_length() > 0:
            snippet += String(id_str)
            if snippet.byte_length() < 200:
                snippet += "\n"
        if snippet.byte_length() < 200 and len(record._sequence) > 0:
            var seq_str = StringSlice(unsafe_from_utf8=record._sequence)
            var seq_len = min(
                seq_str.byte_length(), 200 - snippet.byte_length()
            )
            snippet += String(seq_str[byte=0:seq_len])
        if snippet.byte_length() > 200:
            var truncated = String(snippet[byte=0:197])
            snippet = truncated + "..."
        return snippet

    def _get_record_snippet_from_fastq(self, record: FastqRecord) -> String:
        var snippet = String(capacity=200)
        var id_str = record.id()
        if id_str.byte_length() > 0:
            snippet += String(id_str)
            if snippet.byte_length() < 200:
                snippet += "\n"
        if snippet.byte_length() < 200:
            var seq_str = record.sequence()
            var seq_len = min(
                seq_str.byte_length(), 200 - snippet.byte_length()
            )
            snippet += String(seq_str[byte=0:seq_len])
        if snippet.byte_length() > 200:
            var truncated = String(snippet[byte=0:197])
            snippet = truncated + "..."
        return snippet


struct _FastqParserViewIter[R: Reader, config: ParserConfig, origin: Origin](
    Iterator
):
    comptime Element = FastqView[origin=MutUntrackedOrigin]

    var _src: Pointer[FastqParser[Self.R, Self.config], Self.origin]

    def __init__(
        out self,
        src: Pointer[FastqParser[Self.R, Self.config], Self.origin],
    ):
        self._src = src

    def __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    def __has_next__(self) -> Bool:
        return True

    @always_inline
    def __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[
            Pointer[FastqParser[Self.R, Self.config], MutUntrackedOrigin]
        ](self._src)
        try:
            return mut_ptr[].next_view()
        except Error:
            var err_str = String(Error)
            if err_str == EOF:
                raise StopIteration()
            else:
                print(err_str)
            raise StopIteration()


struct _FastqParserRecordIter[R: Reader, config: ParserConfig, origin: Origin](
    Iterator
):
    comptime Element = FastqRecord

    var _src: Pointer[FastqParser[Self.R, Self.config], Self.origin]

    def __init__(
        out self,
        src: Pointer[FastqParser[Self.R, Self.config], Self.origin],
    ):
        self._src = src

    def __iter__(ref self) -> Self:
        return Self(self._src)

    def __has_next__(self) -> Bool:
        return self._src[].has_more()

    def __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[
            Pointer[FastqParser[Self.R, Self.config], MutUntrackedOrigin]
        ](self._src)
        try:
            return mut_ptr[].next_record()
        except Error:
            var err_str = String(Error)
            if "Record number:" in err_str:
                print(err_str)
            elif err_str == EOF:
                raise StopIteration()
            else:
                print(err_str)
            raise StopIteration()


struct _FastqParserBatchIter[R: Reader, config: ParserConfig, origin: Origin](
    Iterator
):
    comptime Element = FastqBatch

    var _src: Pointer[FastqParser[Self.R, Self.config], Self.origin]
    var _max_records: Int

    def __init__(
        out self,
        src: Pointer[FastqParser[Self.R, Self.config], Self.origin],
        max_records: Int,
    ):
        self._src = src
        self._max_records = max_records

    def __iter__(ref self) -> Self:
        return Self(self._src, self._max_records)

    def __has_next__(self) -> Bool:
        return self._src[].has_more()

    def __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[
            Pointer[FastqParser[Self.R, Self.config], MutUntrackedOrigin]
        ](self._src)
        try:
            var batch = mut_ptr[].next_batch(self._max_records)
            if len(batch) == 0:
                raise StopIteration()
            return batch^
        except Error:
            var err_str = String(Error)
            if "Record number:" in err_str:
                print(err_str)
            raise StopIteration()
