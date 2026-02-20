from blazeseq.record import FastqRecord, RefRecord, Validator
from blazeseq.CONSTS import *
from blazeseq.buffered import (
    BufferedReader,
    Reader,
    LineIterator,
    EOFError,
    LineIteratorError,
)
from blazeseq.readers import Reader
from blazeseq.device_record import FastqBatch
from blazeseq.errors import ParseError, ValidationError
from std.iter import Iterator
from blazeseq.byte_string import ByteString
from blazeseq.utils import (
    _parse_schema,
    SearchState,
    SearchResults,
    _parse_record_fast_path,
    _handle_incomplete_line_with_buffer_growth,
    _handle_incomplete_line,
)


# ---------------------------------------------------------------------------
# ParserConfig: Configuration struct for parser options
# ---------------------------------------------------------------------------


struct ParserConfig(Copyable):
    """
    Configuration struct for FASTQ parser options.
    
    Centralizes buffer capacity, growth policy, validation flags, and quality
    schema settings. Pass as a comptime parameter to FastqParser, e.g.
    FastqParser[FileReader, ParserConfig(check_ascii=False)].
    
    Attributes:
        buffer_capacity: Size in bytes of the internal read buffer. Larger
            values can improve throughput for large files but use more memory.
        buffer_max_capacity: Maximum buffer size when growth is enabled.
        buffer_growth_enabled: If True, buffer grows when a line exceeds
            buffer_capacity, up to buffer_max_capacity. Disable for fixed memory.
        check_ascii: If True, validate that all record bytes are ASCII.
        check_quality: If True, validate quality bytes against the quality schema.
        quality_schema: Optional schema name; used when not passed to __init__.
            One of: "generic", "sanger", "solexa", "illumina_1.3", "illumina_1.5", "illumina_1.8".
        batch_size: Default max records per batch for next_batch()/batched().
    
    Note:
        Disable check_ascii and check_quality for maximum parsing throughput.
    
    Example:
        ```mojo
        from blazeseq.parser import ParserConfig, FastqParser
        from blazeseq.readers import FileReader
        from pathlib import Path
        comptime config = ParserConfig(check_ascii=True, buffer_capacity=65536)
        var parser = FastqParser[FileReader, config](FileReader(Path("data.fastq")), "sanger")
        for record in parser.records():
            _ = record.get_header_string()
        ```
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
        """Initialize ParserConfig with default or custom values.
        
        Args:
            buffer_capacity: Read buffer size in bytes (default from CONSTS).
            buffer_max_capacity: Max buffer size when growth is enabled.
            buffer_growth_enabled: Allow buffer to grow for long lines.
            check_ascii: Validate all record bytes are ASCII.
            check_quality: Validate quality bytes against schema.
            quality_schema: Optional schema name; None uses "generic" at parser init.
            batch_size: Optional default batch size for batched iteration.
        """
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
    Unified FASTQ parser over a Reader.
    
    Exposes three parsing modes:
    - next_ref() -> RefRecord (zero-copy; consume promptly, do not store in collections).
    - next_record() -> FastqRecord (owned; safe to store and reuse).
    - next_batch(max_records) -> FastqBatch (Structure-of-Arrays for GPU or batch processing).
    
    For iteration use ref_records(), records(), or batched(). Direct methods
    raise EOFError at end of input; iterators raise StopIteration and print
    parse/validation errors with context before stopping.
    
    Type parameters:
        R: Reader type (e.g. FileReader, MemoryReader, GZFile).
        config: ParserConfig (optional); controls buffer size, validation, batch size.
    
    See also:
        ParserConfig, RefRecord, FastqRecord, FastqBatch.
    
    Example:
        ```mojo
        from blazeseq.parser import FastqParser
        from blazeseq.readers import FileReader
        from pathlib import Path
        var parser = FastqParser[FileReader](FileReader(Path("data.fastq")), "generic")
        for record in parser.records():
            print(record.get_header_string())
        ```
    """

    var line_iter: LineIterator[Self.R]
    var quality_schema: QualitySchema
    var validator: Validator
    var _batch_size: Int
    var _record_number: Int  # Track current record number (1-indexed)

    fn __init__(
        out self,
        var reader: Self.R,
    ) raises:
        """Initialize FastqParser from config.
        
        Uses quality_schema and batch_size from config if set; otherwise
        generic schema and batch size 1024.
        
        Args:
            reader: Source implementing the Reader trait (e.g. FileReader(Path(...))).
        
        Raises:
            Error: If reader or schema setup fails.
        """
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
        self._record_number = 0

    fn __init__(
        out self,
        var reader: Self.R,
        quality_schema: String,
    ) raises:
        """Initialize FastqParser with quality schema string.
        
        Args:
            reader: Source implementing the Reader trait.
            quality_schema: One of "generic", "sanger", "solexa", "illumina_1.3",
                "illumina_1.5", "illumina_1.8". Affects validation when check_quality is True.
        
        Raises:
            Error: If reader or schema parsing fails.
        """
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
        self._record_number = 0

    fn __init__(
        out self,
        var reader: Self.R,
        default_batch_size: Int,
        schema: String = "generic",
    ) raises:
        """Initialize FastqParser with schema and batch size.
        
        Args:
            reader: Source implementing the Reader trait.
            default_batch_size: Max records per batch for next_batch()/batched().
            schema: Quality schema name (default "generic").
        
        Raises:
            Error: If reader or schema parsing fails.
        """
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
        self._record_number = 0

    @always_inline
    fn has_more(self) -> Bool:
        """Return True if there may be more records to read.
        
        Returns:
            True when there is data in the buffer or the stream can still be read.
            Use this before calling next_ref() or next_record() to avoid EOFError.
        
        Note:
            A return of True does not guarantee a full record is available.
        """
        return self.line_iter.has_more()

    @always_inline
    fn next_ref(mut self) raises -> RefRecord[origin=MutExternalOrigin]:
        """Return the next record as a zero-copy RefRecord.
        
        Returns:
            RefRecord: A view into the parser's buffer; valid only until the next
                call that mutates the parser or buffer.
        
        Raises:
            Error: On parse or validation failure (message includes record number,
                line number, file position, and snippet when available).
            EOFError: When there are no more records.
        
        Note:
            Zero-copy; do not store in collections or use after the next
            next_ref/next_record/next_batch or buffer mutation. Consume promptly.
        """
        self._record_number += 1
        var ref_record = self._parse_record_ref()
        try:
            self.validator.validate(ref_record, self._record_number, self.line_iter.get_line_number())
        except e:
            # Wrap error with context
            var parse_err = ParseError(
                String(e),
                record_number=self._record_number,
                line_number=self.line_iter.get_line_number(),
                file_position=self.line_iter.get_file_position(),
                record_snippet=self._get_record_snippet(ref_record),
            )
            raise Error(parse_err.__str__())
        return ref_record^

    @always_inline
    fn next_record(mut self) raises -> FastqRecord:
        """Return the next record as an owned FastqRecord.
        
        Returns:
            FastqRecord: An owned record; safe to store in collections and reuse.
        
        Raises:
            Error: On parse or validation failure (with context).
            EOFError: When there are no more records.
        
        See also:
            next_ref: Zero-copy variant when you consume immediately.
        """
        if not self.line_iter.has_more():
            raise EOFError()
        self._record_number += 1
        var record = self._parse_record_line()
        try:
            self.validator.validate(record, self._record_number, self.line_iter.get_line_number())
        except e:
            # Wrap error with context
            var parse_err = ParseError(
                String(e),
                record_number=self._record_number,
                line_number=self.line_iter.get_line_number(),
                file_position=self.line_iter.get_file_position(),
                record_snippet=self._get_record_snippet_from_fastq(record),
            )
            raise Error(parse_err.__str__())
        return record^

    fn next_batch(mut self, max_records: Int = 1024) raises -> FastqBatch:
        """Extract a batch of records in Structure-of-Arrays (SoA) format.
        
        Intended for GPU upload or batch processing. Stops at EOF and returns
        a partial batch instead of raising.
        
        Args:
            max_records: Maximum number of records to include (default 1024).
                Capped by the parser's configured batch size.
        
        Returns:
            FastqBatch: SoA batch with 0 to max_records records. Use num_records()
                or len() to get the actual count.
        
        Raises:
            Error: On parse or validation failure (with context); does not
                raise EOFError, returns partial batch instead.
        """
        var actual_max = min(max_records, self._batch_size)
        var batch = FastqBatch(batch_size=actual_max)
        while len(batch) < actual_max and self.line_iter.has_more():
            self._record_number += 1
            var snippet = String("")
            try:
                var ref_record = self._parse_record_ref()
                # Try to extract snippet before validation (in case validation fails)
                snippet = self._get_record_snippet(ref_record)
                self.validator.validate(ref_record, self._record_number, self.line_iter.get_line_number())
                batch.add(ref_record)
            except e:
                if String(e) == EOF:
                    break
                # Wrap error with context before re-raising
                # snippet may be empty if parsing failed before we could extract it
                var parse_err = ParseError(
                    String(e),
                    record_number=self._record_number,
                    line_number=self.line_iter.get_line_number(),
                    file_position=self.line_iter.get_file_position(),
                    record_snippet=snippet,
                )
                raise Error(parse_err.__str__())
        return batch^

    fn ref_records(
        ref self,
    ) -> _FastqParserRefIter[Self.R, Self.config, origin_of(self)]:
        """Return an iterator over RefRecords (zero-copy).
        
        Returns:
            Iterator yielding RefRecord; each ref is invalidated by the next
            iteration. Consume or copy each ref before advancing.
        
        Note:
            On parse/validation error the error is printed with context and
            iteration stops (StopIteration).
        """
        return _FastqParserRefIter[Self.R, Self.config, origin_of(self)](
            Pointer(to=self)
        )

    fn records(
        ref self,
    ) -> _FastqParserRecordIter[Self.R, Self.config, origin_of(self)]:
        """Return an iterator over owned FastqRecords.
        
        Returns:
            Iterator yielding FastqRecord; each record is owned and safe to store.
        
        Note:
            On parse/validation error the error is printed with context and
            iteration stops (StopIteration).
        """
        return _FastqParserRecordIter[Self.R, Self.config, origin_of(self)](
            Pointer(to=self)
        )

    fn batched(
        ref self,
    ) -> _FastqParserBatchIter[Self.R, Self.config, origin_of(self)]:
        """Return an iterator over FastqBatch (SoA) batches.
        
        Returns:
            Iterator yielding FastqBatch; each batch has up to the configured
            batch size. Use for GPU upload or batch processing.
        
        Note:
            On parse/validation error the error is printed with context and
            iteration stops. Last batch may be partial at EOF.
        """
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
            if e.value == LineIteratorError.EOF.value:
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
    
    fn _get_record_snippet(self, record: RefRecord) -> String:
        """Get first 200 characters of record for error context."""
        var snippet = String(capacity=200)
        var header_str = StringSlice(unsafe_from_utf8=record.SeqHeader)
        if len(header_str) > 0:
            snippet += String(header_str)
            if len(snippet) < 200:
                snippet += "\n"
        if len(snippet) < 200 and len(record.SeqStr) > 0:
            var seq_str = StringSlice(unsafe_from_utf8=record.SeqStr)
            var seq_len = min(len(seq_str), 200 - len(snippet))
            snippet += String(seq_str[:seq_len])
        if len(snippet) > 200:
            snippet = snippet[:197] + "..."
        return snippet
    
    fn _get_record_snippet_from_fastq(self, record: FastqRecord) -> String:
        """Get first 200 characters of FastqRecord for error context."""
        var snippet = String(capacity=200)
        var header_str = record.get_header_string()
        if len(header_str) > 0:
            snippet += String(header_str)
            if len(snippet) < 200:
                snippet += "\n"
        if len(snippet) < 200:
            var seq_str = record.get_seq()
            var seq_len = min(len(seq_str), 200 - len(snippet))
            snippet += String(seq_str[:seq_len])
        if len(snippet) > 200:
            snippet = snippet[:197] + "..."
        return snippet


# ---------------------------------------------------------------------------
# Iterator adapters for FastqParser: ref_records(), records(), batched()
# ---------------------------------------------------------------------------


struct _FastqParserRefIter[R: Reader, config: ParserConfig, origin: Origin](
    Iterator
):
    """Iterator over RefRecords (zero-copy); use parser.ref_records().
    
    Lifetime: Each yielded RefRecord is a view into the parser's buffer and is
    invalidated by the next __next__ call or any parser mutation. Do not store
    refs in collections; consume or copy to owned buffer before advancing. On parse/validation
    error the error is printed with context and iteration stops.
    """

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
            var err_str = String(Error)
            # Check if it's a ParseError or ValidationError by checking the message format
            # ParseError and ValidationError will have "Record number:" in their string representation
            if "Record number:" in err_str:
                # Print error with context
                print(err_str)
            elif err_str == EOF:
                raise StopIteration()
            else:
                # Print generic error (may not have context)
                print(err_str)
            raise StopIteration()


struct _FastqParserRecordIter[R: Reader, config: ParserConfig, origin: Origin](
    Iterator
):
    """Iterator over owned FastqRecords; use parser.records().
    
    Each yielded FastqRecord is owned and safe to store. On parse/validation
    error the error is printed with context and iteration stops (StopIteration).
    """

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
            # Check if it's a ParseError or ValidationError by checking the message format
            # ParseError and ValidationError will have "Record number:" in their string representation
            if "Record number:" in err_str:
                # Print error with context
                print(err_str)
            elif err_str == EOF:
                raise StopIteration()
            else:
                # Print generic error (may not have context)
                print(err_str)
            raise StopIteration()


struct _FastqParserBatchIter[R: Reader, config: ParserConfig, origin: Origin](
    Iterator
):
    """Iterator over FastqBatch (SoA); use parser.batched().
    
    Yields batches of up to the configured batch size. Last batch may be
    partial at EOF. On parse/validation error the error is printed with
    context and iteration stops.
    """

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
        except Error:
            var err_str = String(Error)
            # Check if it's a ParseError or ValidationError by checking the message format
            # ParseError and ValidationError will have "Record number:" in their string representation
            if "Record number:" in err_str:
                # Print error with context
                print(err_str)
            raise StopIteration()
