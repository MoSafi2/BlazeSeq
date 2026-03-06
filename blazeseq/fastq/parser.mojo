from blazeseq.fastq.record import FastqRecord, RefRecord, Validator
from blazeseq.CONSTS import *
from blazeseq.io.buffered import EOFError, BufferedReader
from blazeseq.io.readers import Reader
from blazeseq.record_batch import FastqBatch
from blazeseq.errors import (
    ParseError,
    ValidationError,
    FastxErrorCode,
    format_parse_error_from_code,
    format_validation_error_from_code,
    buffer_capacity_error,
)
from std.iter import Iterator
from blazeseq.byte_string import BString
from blazeseq.utils import (
    _parse_schema,
    format_parse_error,
    _check_end_qual,
    _scan_record,
    _strip_spaces,
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

    fn __init__(
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

    fn __init__(
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

    fn __init__(
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

    fn __init__(
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
    fn get_record_number(ref self) -> Int:
        return self._current_line_number // 4

    @always_inline
    fn get_line_number(ref self) -> Int:
        return self._current_line_number

    @always_inline
    fn get_file_position(ref self) -> Int64:
        return Int64(self.buffer.stream_position())

    @always_inline
    fn has_more(self) -> Bool:
        return self.buffer.available() > 0 or not self.buffer.is_eof()

    @always_inline
    fn next_ref(mut self) raises -> RefRecord[origin=MutExternalOrigin]:
        var ref_rec = self._find_and_consume_ref_record()
        var code = self.validator._validate(ref_rec)
        if code != FastxErrorCode.OK:
            raise Error(
                format_validation_error_from_code(
                    code,
                    self.get_record_number(),
                    "",
                    self._get_record_snippet(ref_rec),
                )
            )
        return ref_rec

    @always_inline
    fn next_record(mut self) raises -> FastqRecord:
        if not self.has_more():
            raise EOFError()
        var ref_rec = self._find_and_consume_ref_record()
        var record: FastqRecord
        try:
            record = FastqRecord(
                ref_rec._id,
                ref_rec._sequence,
                ref_rec._quality,
                Int8(self.quality_schema.OFFSET),
            )
        except e:
            raise Error(
                format_parse_error(
                    String(e),
                    self.get_record_number(),
                    self.get_line_number(),
                    self.get_file_position(),
                    "",
                )
            )
        var code = self.validator._validate(record)
        if code != FastxErrorCode.OK:
            raise Error(
                format_validation_error_from_code(
                    code,
                    self.get_record_number(),
                    "",
                    self._get_record_snippet_from_fastq(record),
                )
            )
        return record^

    fn next_batch(
        mut self, max_records: Int = DEFAULT_BATCH_SIZE
    ) raises -> FastqBatch:
        var limit = max_records if max_records else self._batch_size
        var batch = FastqBatch(batch_size=limit)
        while len(batch) < limit and self.has_more():
            try:
                batch.add(self.next_ref())
            except e:
                if String(e) == EOF or String(e).startswith(EOF):
                    break
                raise e^
        return batch^

    fn ref_records(
        ref self,
    ) -> _FastqParserRefIter[Self.R, Self.config, origin_of(self)]:
        return _FastqParserRefIter[Self.R, Self.config, origin_of(self)](
            Pointer(to=self)
        )

    fn records(
        ref self,
    ) -> _FastqParserRecordIter[Self.R, Self.config, origin_of(self)]:
        return _FastqParserRecordIter[Self.R, Self.config, origin_of(self)](
            Pointer(to=self)
        )

    fn batches(
        ref self,
        max_records: Optional[Int] = None,
    ) -> _FastqParserBatchIter[Self.R, Self.config, origin_of(self)]:
        var limit = max_records.value() if max_records else self._batch_size
        return _FastqParserBatchIter[Self.R, Self.config, origin_of(self)](
            Pointer(to=self), limit
        )

    fn _refill_error_message(
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
            var rec_num = self._current_line_number // 4 + 1
            var line_num = self._current_line_number + 1
            return format_parse_error_from_code(
                refill_code,
                rec_num,
                line_num,
                self.get_file_position(),
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

    fn _find_and_consume_ref_record(
        mut self,
    ) raises -> RefRecord[origin=MutExternalOrigin]:
        if self.buffer.available() == 0:
            _ = self.buffer.compact_and_fill()
        if not self.has_more():
            raise EOFError()

        var base = self.buffer.buffer_position()
        var offsets = RecordOffsets()
        var phase = SearchPhase.HEADER

        var scan_view = Span[Byte, MutExternalOrigin](
            ptr=self.buffer._ptr + base,
            length=self.buffer._end - base,
        )
        var complete: Bool
        var parse_code: FastxErrorCode
        complete, offsets, phase, parse_code = _scan_record(
            scan_view, offsets, phase
        )
        if parse_code != FastxErrorCode.OK:
            var rec_num = self._current_line_number // 4 + 1
            var line_num = self._current_line_number + 1
            raise Error(
                format_parse_error_from_code(
                    parse_code,
                    rec_num,
                    line_num,
                    self.get_file_position(),
                    _record_snippet(scan_view, offsets),
                )
            )
        if not complete:
            complete, offsets, phase, refill_code = self._next_ref_complete(
                base, offsets, phase
            )
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

        var id_span = Span[Byte, MutExternalOrigin](
            ptr=buffer_view + offsets.header_start + 1,
            length=(offsets.seq_start - offsets.header_start - 2),
        )
        var seq_span = Span[Byte, MutExternalOrigin](
            ptr=buffer_view + offsets.seq_start,
            length=(offsets.sep_start - offsets.seq_start - 1),
        )
        var qual_span = Span[Byte, MutExternalOrigin](
            ptr=buffer_view + offsets.qual_start,
            length=(offsets.record_end - offsets.qual_start),
        )

        var ref_rec = RefRecord[origin=MutExternalOrigin](
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
    fn _next_ref_complete(
        mut self,
        base: Int,
        mut offsets: RecordOffsets,
        phase: SearchPhase,
    ) raises -> Tuple[Bool, RecordOffsets, SearchPhase, FastxErrorCode]:
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
                        SearchPhase(new_base),
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

                @parameter
                if not self.config.buffer_growth_enabled:
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

            var scan_view = Span[Byte, MutExternalOrigin](
                ptr=self.buffer._ptr + new_base,
                length=self.buffer._end - new_base,
            )
            var complete: Bool
            var parse_code: FastxErrorCode
            complete, offsets, current_phase, parse_code = _scan_record(
                scan_view, offsets, current_phase
            )
            if complete:
                return (True, offsets, current_phase, parse_code)

    fn _get_record_snippet(self, record: RefRecord) -> String:
        var snippet = String(capacity=200)
        var id_str = StringSlice(unsafe_from_utf8=record._id)
        if len(id_str) > 0:
            snippet += String(id_str)
            if len(snippet) < 200:
                snippet += "\n"
        if len(snippet) < 200 and len(record._sequence) > 0:
            var seq_str = StringSlice(unsafe_from_utf8=record._sequence)
            var seq_len = min(len(seq_str), 200 - len(snippet))
            snippet += String(seq_str[:seq_len])
        if len(snippet) > 200:
            snippet = snippet[:197] + "..."
        return snippet

    fn _get_record_snippet_from_fastq(self, record: FastqRecord) -> String:
        var snippet = String(capacity=200)
        var id_str = record.id()
        if len(id_str) > 0:
            snippet += String(StringSlice(unsafe_from_utf8=id_str))
            if len(snippet) < 200:
                snippet += "\n"
        if len(snippet) < 200:
            var seq_str = record.sequence()
            var seq_len = min(len(seq_str), 200 - len(snippet))
            snippet += String(StringSlice(unsafe_from_utf8=seq_str[:seq_len]))
        if len(snippet) > 200:
            snippet = snippet[:197] + "..."
        return snippet


struct _FastqParserRefIter[R: Reader, config: ParserConfig, origin: Origin](
    Iterator
):
    comptime Element = RefRecord[origin=MutExternalOrigin]

    var _src: Pointer[FastqParser[Self.R, Self.config], Self.origin]

    fn __init__(
        out self,
        src: Pointer[FastqParser[Self.R, Self.config], Self.origin],
    ):
        self._src = src

    fn __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    fn __has_next__(self) -> Bool:
        return True

    @always_inline
    fn __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[
            Pointer[FastqParser[Self.R, Self.config], MutExternalOrigin]
        ](self._src)
        try:
            return mut_ptr[].next_ref()
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

    fn __init__(
        out self,
        src: Pointer[FastqParser[Self.R, Self.config], Self.origin],
    ):
        self._src = src

    fn __iter__(ref self) -> Self:
        return Self(self._src)

    fn __has_next__(self) -> Bool:
        return self._src[].has_more()

    fn __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[
            Pointer[FastqParser[Self.R, Self.config], MutExternalOrigin]
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

    fn __init__(
        out self,
        src: Pointer[FastqParser[Self.R, Self.config], Self.origin],
        max_records: Int,
    ):
        self._src = src
        self._max_records = max_records

    fn __iter__(ref self) -> Self:
        return Self(self._src, self._max_records)

    fn __has_next__(self) -> Bool:
        return self._src[].has_more()

    fn __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[
            Pointer[FastqParser[Self.R, Self.config], MutExternalOrigin]
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
