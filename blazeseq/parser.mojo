from blazeseq.record import FastqRecord, RefRecord, Validator
from blazeseq.CONSTS import *
from blazeseq.iostream import (
    BufferedReader,
    Reader,
    LineIterator,
    EOFError,
    LineIteratorError,
)
from blazeseq.readers import Reader
from blazeseq.device_record import FastqBatch
from std.iter import Iterator
from blazeseq.byte_string import ByteString
from blazeseq.utils import _parse_schema, SearchState, SearchResults, _parse_record_fast_path, _handle_incomplete_line_with_buffer_growth, _handle_incomplete_line


# ---------------------------------------------------------------------------
# ParserConfig: Configuration struct for parser options
# ---------------------------------------------------------------------------


struct ParserConfig(Copyable):
    """
    Configuration struct for FASTQ parser options.
    Centralizes buffer capacity, growth policy, validation flags, and quality schema settings.
    """

    var buffer_capacity: Int
    var buffer_max_capacity: Int
    var buffer_growth_enabled: Bool
    var check_ascii: Bool
    var check_quality: Bool
    var quality_schema: Optional[String]
    var batch_size: Optional[Int]

    fn __init__(
        out self,
        buffer_capacity: Int = DEFAULT_CAPACITY,
        buffer_max_capacity: Int = MAX_CAPACITY,
        buffer_growth_enabled: Bool = False,
        check_ascii: Bool = False,
        check_quality: Bool = False,
        quality_schema: Optional[String] = None,
        batch_size: Optional[Int] = None,
    ):
        """Initialize ParserConfig with default or custom values."""
        self.buffer_capacity = buffer_capacity
        self.buffer_max_capacity = buffer_max_capacity
        self.buffer_growth_enabled = buffer_growth_enabled
        self.check_ascii = check_ascii
        self.check_quality = check_quality
        self.quality_schema = quality_schema
        self.batch_size = batch_size


# ---------------------------------------------------------------------------
# FastqParser: Unified FASTQ parser with next_ref / next_record / next_batch
# ---------------------------------------------------------------------------


struct FastqParser[R: Reader, config: ParserConfig = ParserConfig()](Movable):
    """
    Unified FASTQ parser over a Reader. Exposes three parsing modes:
    - next_ref() -> RefRecord (zero-copy)
    - next_record() -> FastqRecord (owned)
    - next_batch(max_records) -> FastqBatch (SoA)
    Use ref_records(), records(), or batched() for iteration.
    """

    var line_iter: LineIterator[Self.R]
    var quality_schema: QualitySchema
    var validator: Validator
    var _batch_size: Int

    fn __init__(
        out self,
        var reader: Self.R,
    ) raises:
        """Initialize FastqParser from config."""
        self.line_iter = LineIterator(
            reader^,
            self.config.buffer_capacity,
            self.config.buffer_growth_enabled,
            self.config.buffer_max_capacity,
        )
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
        if self.config.batch_size:
            self._batch_size = self.config.batch_size.value()
        else:
            self._batch_size = 1024

    fn __init__(
        out self,
        var reader: Self.R,
        quality_schema: String,
    ) raises:
        """Initialize FastqParser with quality schema string."""
        self.line_iter = LineIterator(
            reader^,
            self.config.buffer_capacity,
            self.config.buffer_growth_enabled,
            self.config.buffer_max_capacity,
        )
        self.quality_schema = _parse_schema(quality_schema)
        self.validator = Validator(
            self.config.check_ascii,
            self.config.check_quality,
            self.quality_schema.copy(),
        )
        if self.config.batch_size:
            self._batch_size = self.config.batch_size.value()
        else:
            self._batch_size = 1024

    fn __init__(
        out self,
        var reader: Self.R,
        default_batch_size: Int,
        schema: String = "generic"
    ) raises:
        """Initialize FastqParser with schema and batch size."""
        self.line_iter = LineIterator(
            reader^,
            self.config.buffer_capacity,
            self.config.buffer_growth_enabled,
            self.config.buffer_max_capacity,
        )
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
        if self.config.batch_size:
            self._batch_size = self.config.batch_size.value()
        else:
            self._batch_size = default_batch_size

    @always_inline
    fn has_more(self) -> Bool:
        """True if there may be more records (more input in the buffer or stream)."""
        return self.line_iter.has_more()

    @always_inline
    fn next_ref(mut self) raises -> RefRecord[origin=MutExternalOrigin]:
        """Return the next record as a zero-copy RefRecord."""
        var ref_record = self._parse_record_ref()
        self.validator.validate(ref_record)
        return ref_record^

    @always_inline
    fn next_record(mut self) raises -> FastqRecord:
        """Return the next record as an owned FastqRecord."""
        if not self.line_iter.has_more():
            raise EOFError()
        var record = self._parse_record_line()
        self.validator.validate(record)
        return record^

    fn next_batch(mut self, max_records: Int = 1024) raises -> FastqBatch:
        """
        Extract a batch of records in Structure-of-Arrays format for GPU operations.
        """
        var actual_max = min(max_records, self._batch_size)
        var batch = FastqBatch(batch_size=actual_max)
        while len(batch) < actual_max and self.line_iter.has_more():
            var record = self._parse_record_line()
            batch.add(record^)
        return batch^

    fn ref_records(
        ref self,
    ) -> _FastqParserRefIter[Self.R, Self.config, origin_of(self)]:
        """Return an iterator over RefRecords: for ref in parser.ref_records()."""
        return _FastqParserRefIter[Self.R, Self.config, origin_of(self)](
            Pointer(to=self)
        )

    fn records(
        ref self,
    ) -> _FastqParserRecordIter[Self.R, Self.config, origin_of(self)]:
        """Return an iterator over FastqRecords: for rec in parser.records()."""
        return _FastqParserRecordIter[Self.R, Self.config, origin_of(self)](
            Pointer(to=self)
        )

    fn batched(
        ref self,
    ) -> _FastqParserBatchIter[Self.R, Self.config, origin_of(self)]:
        """Return an iterator over FastqBatches: for batch in parser.batched()."""
        return _FastqParserBatchIter[Self.R, Self.config, origin_of(self)](
            Pointer(to=self)
        )

    @always_inline
    fn _parse_record_line(mut self) raises -> FastqRecord:
        var line1 = ByteString(self.line_iter.next_line())
        var line2 = ByteString(self.line_iter.next_line())
        var line3 = ByteString(self.line_iter.next_line())
        var line4 = ByteString(self.line_iter.next_line())
        schema = self.quality_schema.copy()
        return FastqRecord(line1^, line2^, line3^, line4^, schema)

    @always_inline
    fn _parse_record_ref(
        mut self,
    ) raises -> RefRecord[origin=MutExternalOrigin]:
        if not self.line_iter.has_more():
            raise EOFError()
        var state = SearchState.START
        var interim = SearchResults.DEFAULT
        try:
            return _parse_record_fast_path(
                self.line_iter, interim, state, self.quality_schema
            )
        except e:
            if e == LineIteratorError.EOF:
                raise EOFError()
            if e != LineIteratorError.INCOMPLETE_LINE:
                raise e
            @parameter
            if self.config.buffer_growth_enabled:
                return _handle_incomplete_line_with_buffer_growth(
                    self.line_iter,
                    interim,
                    state,
                    self.quality_schema,
                    self.config.buffer_max_capacity,
                )
            else:
                return _handle_incomplete_line(
                    self.line_iter,
                    interim,
                    state,
                    self.quality_schema,
                    self.config.buffer_capacity,
                )


# ---------------------------------------------------------------------------
# Iterator adapters for FastqParser: ref_records(), records(), batched()
# ---------------------------------------------------------------------------


struct _FastqParserRefIter[R: Reader, config: ParserConfig, origin: Origin](
    Iterator
):
    """Iterator over RefRecords; use parser.ref_records()."""

    comptime Element = RefRecord[origin=MutExternalOrigin]

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
            return mut_ptr[].next_ref()
        except Error:
            if String(Error) == EOF:
                raise StopIteration()
            else:
                print(String(Error))
            raise StopIteration()


struct _FastqParserRecordIter[R: Reader, config: ParserConfig, origin: Origin](
    Iterator
):
    """Iterator over FastqRecords; use parser.records()."""

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
            if String(Error) == EOF:
                raise StopIteration()
            else:
                print(String(Error))
            raise StopIteration()


struct _FastqParserBatchIter[R: Reader, config: ParserConfig, origin: Origin](
    Iterator
):
    """Iterator over FastqBatches; use parser.batched()."""

    comptime Element = FastqBatch

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
            var batch = mut_ptr[].next_batch()
            if len(batch) == 0:
                raise StopIteration()
            return batch^
        except:
            raise StopIteration()

