from blazeseq.record import FastqRecord, RefRecord, Validator
from blazeseq.CONSTS import *
from blazeseq.io.buffered import (
    LineIterator,
    EOFError,
    LineIteratorError,
)
from blazeseq.io.readers import Reader
from blazeseq import FastqBatch
from blazeseq.errors import ParseError, ValidationError, buffer_capacity_error
from std.iter import Iterator
from blazeseq.ascii_string import ASCIIString
from blazeseq.utils import (
    _parse_schema,
    format_parse_error,
    _check_end_qual,
    _scan_record,
    RecordOffsets,
    SearchPhase,
    BufferedReader,
)


# ---------------------------------------------------------------------------
# ParserConfig: Configuration struct for parser options
# ---------------------------------------------------------------------------


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

    Example:
        ```mojo
        from blazeseq import ParserConfig, FastqParser, FileReader
        from pathlib import Path
        comptime config = ParserConfig(check_ascii=True, buffer_capacity=65536)
        var parser = FastqParser[FileReader, config](FileReader(Path("data.fastq")), "sanger")
        for record in parser.records():
            _ = record.id_slice()
        ```
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
        """Initialize ParserConfig with default or custom values.
        
        Args:
            buffer_capacity: Read buffer size in bytes (default from CONSTS).
            buffer_max_capacity: Max buffer size when growth is enabled.
            buffer_growth_enabled: Allow buffer to grow for long lines.
            check_ascii: Validate all record bytes are ASCII.
            check_quality: Validate quality bytes against schema.
            quality_schema: Optional schema name; None uses "generic" at parser init.
        """
        self.buffer_capacity = buffer_capacity
        self.buffer_max_capacity = buffer_max_capacity
        self.buffer_growth_enabled = buffer_growth_enabled
        self.check_ascii = check_ascii
        self.check_quality = check_quality
        self.quality_schema = quality_schema


# ---------------------------------------------------------------------------
# FastqParser: Unified FASTQ parser with next_ref / next_record / next_batch
# ---------------------------------------------------------------------------


struct FastqParser[R: Reader, config: ParserConfig = ParserConfig()](Movable):
    """
    Unified FASTQ parser over a `Reader`.
    
    Exposes three parsing modes:
    - `next_ref()` -> `RefRecord` (zero-copy; consume promptly, do not store in collections).
    - `next_record()` -> `FastqRecord` (owned; safe to store and reuse).
    - `next_batch(max_records)` -> `FastqBatch` (Structure-of-Arrays for GPU or batch processing).
    
    For iteration use `ref_records()`, `records()`, or `batched()`. Direct methods
    raise `EOFError` at end of input; iterators raise `StopIteration` and print
    parse/validation errors with context before stopping.
    
    Type parameters:
        R: Reader type (e.g. `FileReader`, `MemoryReader`, `GZFile`).
        config: `ParserConfig` (optional); controls buffer size and validation.
    
    See also:
        `ParserConfig`, `RefRecord`, `FastqRecord`, `FastqBatch`.
    
    Example:
        ```mojo
        from blazeseq import FastqParser, FileReader
        from pathlib import Path
        var parser = FastqParser[FileReader](FileReader(Path("data.fastq")), "generic")
        for record in parser.records():
            print(record.id_slice())
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
        
        Uses quality_schema from config if set; otherwise generic schema.
        Default batch size for batched() is DEFAULT_BATCH_SIZE from CONSTS.
        
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
        self._batch_size = DEFAULT_BATCH_SIZE
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
        self._batch_size = DEFAULT_BATCH_SIZE
        self._record_number = 0

    fn __init__(
        out self,
        var reader: Self.R,
        batch_size: Int,
        schema: String = "generic",
    ) raises:
        """Initialize FastqParser with schema and batch size.
        
        Args:
            reader: Source implementing the Reader trait.
            batch_size: Max records per batch for next_batch()/batched().
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
        self._batch_size = batch_size
        self._record_number = 0

    @always_inline
    fn get_record_number(ref self) -> Int:
        return self._record_number

    @always_inline
    fn get_line_number(ref self) -> Int:
        return self.line_iter.get_line_number()

    @always_inline
    fn get_file_position(ref self) -> Int64:
        return self.line_iter.get_file_position()

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
        var record: FastqRecord
        try:
            record = self._parse_record_line()
        except e:
            raise(e^)
            #raise Error(format_parse_error(String(e), self, ""))
        try:
            self.validator.validate(record, self._record_number, self.line_iter.get_line_number())
        except e:
            raise(e^)
            #raise Error(format_parse_error(String(e), self, self._get_record_snippet_from_fastq(record)))
        return record^

    fn next_batch(mut self, max_records: Int = DEFAULT_BATCH_SIZE) raises -> FastqBatch:
        """Extract a batch of records in Structure-of-Arrays (SoA) format.
        
        Intended for GPU upload or batch processing. Stops at EOF and returns
        a partial batch instead of raising.
        
        Args:
            max_records: Maximum number of records to include (default DEFAULT_BATCH_SIZE from CONSTS).
        
        Returns:
            FastqBatch: SoA batch with 0 to max_records records. Use num_records()
                or len() to get the actual count.
        
        Raises:
            Error: On parse or validation failure (with context); does not
                raise EOFError, returns partial batch instead.
        """
        var limit = max_records if max_records else self._batch_size
        var batch = FastqBatch(batch_size=limit)
        while len(batch) < limit and self.line_iter.has_more():
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
        max_records: Optional[Int] = None,
    ) -> _FastqParserBatchIter[Self.R, Self.config, origin_of(self)]:
        """Return an iterator over FastqBatch (SoA) batches.
        
        Args:
            max_records: Max records per batch; if None, uses parser default (from init).
        
        Returns:
            Iterator yielding FastqBatch; each batch has up to max_records records.
            Use for GPU upload or batch processing.
        
        Note:
            On parse/validation error the error is printed with context and
            iteration stops. Last batch may be partial at EOF.
        """
        var limit = max_records.value() if max_records else self._batch_size
        return _FastqParserBatchIter[Self.R, Self.config, origin_of(self)](
            Pointer(to=self), limit
        )

    

    @always_inline
    fn next_ref(mut self) raises -> RefRecord[origin=MutExternalOrigin]:
        if not self.line_iter.has_more():
            raise EOFError()

        self._record_number += 1

        # ── 1. Fill buffer if empty ───────────────────────────────────────────────
        if self.line_iter.buffer.available() == 0:
            if self.line_iter.buffer.is_eof():
                raise EOFError()
            _ = self.line_iter.buffer._fill_buffer()
            if self.line_iter.buffer.available() == 0:
                raise EOFError()

        # ── 2. Set scan anchor: all relative offsets are from here ────────────────
        #    base = absolute index of view()[0] = buf._head (before any compact)
        var base = self.line_iter.buffer._head
        var offsets = RecordOffsets(
            header_start=0,   # relative to base; '@' is always at offset 0
            seq_start=0,
            sep_start=0,
            qual_start=0,
            record_end=0,
        )
        var phase = SearchPhase.HEADER

        # ── 3. Fast-path scan ─────────────────────────────────────────────────────
        var complete: Bool
        complete, offsets, phase = _scan_record(self.line_iter.buffer, base, offsets, phase)

        # ── 4. Slow path: incomplete record, need more data ───────────────────────
        if not complete:
            complete, offsets, _ = self._next_ref_complete(base, offsets, phase)
            base = 0
            if not complete:
                raise EOFError()
        var id_end   = offsets.seq_start - 1        
        var seq_nl   = offsets.sep_start - 1

        id_span = Span[Byte, MutExternalOrigin](
            ptr    = self.line_iter.buffer._ptr + base + offsets.header_start,
            length = id_end - (offsets.header_start),
        )

        seq_span = Span[Byte, MutExternalOrigin](
            ptr    = self.line_iter.buffer._ptr + base + offsets.seq_start,
            length = seq_nl - offsets.seq_start,
        )
        qual_span = Span[Byte, MutExternalOrigin](
            ptr    = self.line_iter.buffer._ptr + base + offsets.qual_start,
            length = offsets.record_end - offsets.qual_start,
        )

        var ref_rec = RefRecord[origin=MutExternalOrigin](
            id_span,
            seq_span,
            qual_span,
            self.quality_schema.OFFSET,
        )

        # ── 7. Consume the record bytes ───────────────────────────────────────────
        var to_consume = offsets.record_end + 1   # +1 for the '\n'
        # Clamp to available in case record_end == buf._end (EOF, no trailing \n)
        _ = self.line_iter.buffer.consume(min(to_consume, self.line_iter.buffer._end - base))

        # ── 8. Update line counter (4 lines per FASTQ record) ────────────────────
        self.line_iter._current_line_number += 4

        # ── 9. Optional user-level validation (quality scores, ASCII check) ───────
        try:
            self.validator.validate(
                ref_rec,
                self._record_number,
                self.line_iter.get_line_number(),
            )
        except e:
            raise(e^)
            #raise Error(
            #    format_parse_error(
            #        String(e), self, self._get_record_snippet(ref_rec)
            #    )
            #)
        return ref_rec^



    @always_inline
    fn _parse_record_line(mut self) raises -> FastqRecord:
        var line1 = ASCIIString(self.line_iter.next_line())
        var line2 = ASCIIString(self.line_iter.next_line())
        var line3 = self.line_iter.next_line()
        var line4 = ASCIIString(self.line_iter.next_line())
        schema = self.quality_schema.copy()
        return FastqRecord(line1^, line2^, line4^, schema)



    
    @always_inline
    fn _next_ref_complete(
        mut self,
        base        : Int,           # original scan anchor before compaction
        mut offsets     : RecordOffsets,
        phase       : SearchPhase,
    ) raises -> Tuple[Bool, RecordOffsets, SearchPhase]:
        """
        Refill/grow loop for records that span more than what is currently in
        the buffer.  Mirrors Rust next_complete().

        State preservation across iterations
        ─────────────────────────────────────
        After _compact_from(base) the buffer is shifted: the byte that was at
        absolute offset `base` is now at absolute offset 0 (buf._head == 0).
        All relative offsets in `offsets` remain valid because they are relative
        to `base`, and base becomes 0 after compaction — so no adjustment needed.
        """


        var new_base = base

        while True:
            var buf_available = self.line_iter.buffer.available()
            var buf_capacity  = self.line_iter.buffer.capacity()

            # ── Is EOF the reason we can't complete? ─────────────────────────────
            if buf_available < buf_capacity and self.line_iter.buffer.is_eof():
                # Mirrors Rust check_end()
                if phase == SearchPhase.QUAL:
                    # No trailing newline on last record — still valid
                    var got_record: Bool
                    got_record, offsets = _check_end_qual(self.line_iter.buffer, new_base, offsets)
                    return (got_record, offsets, SearchPhase(new_base))
                else:
                    # Incomplete record at EOF → error
                    raise Error(
                        "Unexpected end of file in FASTQ record at phase "
                        + String(phase.value)
                    )

            if new_base == 0:
                # # Record starts at position 0 already; buffer is too small → grow
                # # Mirrors Rust grow(): double capacity
                # var current_cap = self.line_iter.buffer.capacity()
                # var max_cap = self.line_iter._max_capacity
                # if current_cap >= max_cap:
                    max_cap = self.line_iter.buffer.capacity()
                    raise Error(
                        "FASTQ record exceeds maximum buffer capacity ("
                        + String(max_cap)
                        + " bytes). Enable buffer growth or increase max_capacity."
                    )
                # var growth = min(current_cap, max_cap - current_cap)
                # self.line_iter.buffer.resize_buffer(growth, max_cap)
            else:
                # There are consumed records before new_base — discard them
                # After this: the byte at new_base moves to offset 0; new_base = 0
                self.line_iter.buffer._compact_from(new_base)
                new_base = 0
                # All relative offsets in `o` are still valid (they were relative
                # to old new_base, which is now 0)

            # ── Refill ────────────────────────────────────────────────────────────
            var filled = self.line_iter.buffer._fill_buffer()
            if filled == 0 and self.line_iter.buffer.available() == 0:
                raise EOFError()

            # ── Resume scan from saved phase ──────────────────────────────────────
            # Mirrors Rust find_incomplete() which skips already-found positions
            var complete: Bool
            complete, offsets, new_phase = _scan_record(self.line_iter.buffer, new_base, offsets, phase)
            if complete:
                return (True, offsets, new_phase)

            # Not yet complete → loop and try to refill more


    fn _get_record_snippet(self, record: RefRecord) -> String:
        """Get first 200 characters of record for error context."""
        var snippet = String(capacity=200)
        var id_str = StringSlice(unsafe_from_utf8=record.id)
        if len(id_str) > 0:
            snippet += String(id_str)
            if len(snippet) < 200:
                snippet += "\n"
        if len(snippet) < 200 and len(record.sequence) > 0:
            var seq_str = StringSlice(unsafe_from_utf8=record.sequence)
            var seq_len = min(len(seq_str), 200 - len(snippet))
            snippet += String(seq_str[:seq_len])
        if len(snippet) > 200:
            snippet = snippet[:197] + "..."
        return snippet
    
    fn _get_record_snippet_from_fastq(self, record: FastqRecord) -> String:
        """Get first 200 characters of FastqRecord for error context."""
        var snippet = String(capacity=200)
        var id_str = record.id_slice()
        if len(id_str) > 0:
            snippet += String(id_str)
            if len(snippet) < 200:
                snippet += "\n"
        if len(snippet) < 200:
            var seq_str = record.sequence_slice()
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
    """Iterator over `RefRecord`s (zero-copy); use `parser.ref_records()`.
    
    Lifetime: Each yielded `RefRecord` is a view into the parser's buffer and is
    invalidated by the next `__next__` call or any parser mutation. Do not store
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
            if err_str == EOF:
                raise StopIteration()
            else:
                print(err_str)
            raise StopIteration()


struct _FastqParserRecordIter[R: Reader, config: ParserConfig, origin: Origin](
    Iterator
):
    """Iterator over owned `FastqRecord`s; use `parser.records()`.
    
    Each yielded `FastqRecord` is owned and safe to store. On parse/validation
    error the error is printed with context and iteration stops (`StopIteration`).
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
    """Iterator over `FastqBatch` (SoA); use `parser.batched()` or `parser.batched(max_records)`.
    
    Yields batches of up to the given max_records. Last batch may be
    partial at EOF. On parse/validation error the error is printed with
    context and iteration stops.
    """

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
            # Check if it's a ParseError or ValidationError by checking the message format
            # ParseError and ValidationError will have "Record number:" in their string representation
            if "Record number:" in err_str:
                # Print error with context
                print(err_str)
            raise StopIteration()
