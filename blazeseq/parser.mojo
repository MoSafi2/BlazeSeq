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
from std.iter import Iterable, Iterator
import time
from blazeseq.byte_string import ByteString
from blazeseq.utils import _parse_schema


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


struct RecordParser[R: Reader, config: ParserConfig = ParserConfig()](
    Iterable, Movable
):
    """
    FASTQ record parser over a Reader. Supports ``for record in parser``;
    each element is a FastqRecord.
    """

    comptime IteratorType[
        mut: Bool, origin: Origin[mut=mut]
    ] = _RecordParserIter[Self.R, Self.config, origin]

    var line_iter: LineIterator[Self.R]
    var quality_schema: QualitySchema
    var validator: Validator

    fn __init__(
        out self,
        var reader: Self.R,
    ) raises:
        """Initialize RecordParser with optional ParserConfig."""
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

    fn __init__(
        out self,
        var reader: Self.R,
        quality_schema: String,
    ) raises:
        """Initialize RecordParser with optional ParserConfig."""
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

    fn parse_all(mut self) raises:
        # Check if file is empty - if so, raise EOF error
        if not self.line_iter.has_more():
            raise Error(EOF)

        while True:
            if not self.line_iter.has_more():
                break
            var record: FastqRecord
            record = self._parse_record()
            self.validator.validate(record)

    @always_inline
    fn next(
        mut self,
    ) raises -> FastqRecord:
        """Method that lazily returns the Next record in the file."""
        if self.line_iter.has_more():
            var record: FastqRecord
            record = self._parse_record()
            self.validator.validate(record)
            return record^
        else:
            raise EOFError()

    @always_inline
    fn has_more(self) -> Bool:
        """True if there may be more records (more input in the buffer or stream).
        """
        return self.line_iter.has_more()

    fn __iter__(
        ref self,
    ) -> _RecordParserIter[Self.R, Self.config, origin_of(self)]:
        """Return an iterator for use in ``for record in self``."""
        return _RecordParserIter[Self.R, Self.config, origin_of(self)](
            Pointer(to=self)
        )

    @always_inline
    fn _parse_record(
        mut self,
    ) raises -> FastqRecord:
        var line1 = ByteString(self.line_iter.next_line())
        var line2 = ByteString(self.line_iter.next_line())
        var line3 = ByteString(self.line_iter.next_line())
        var line4 = ByteString(self.line_iter.next_line())
        return FastqRecord(line1^, line2^, line3^, line4^, self.quality_schema)


# ---------------------------------------------------------------------------
# Iterator adapter for RecordParser so that ``for record in parser`` works.
# ---------------------------------------------------------------------------


struct _RecordParserIter[R: Reader, config: ParserConfig, origin: Origin](
    Iterator
):
    """Iterator over FASTQ records; yields FastqRecord per record."""

    comptime Element = FastqRecord

    var _src: Pointer[RecordParser[Self.R, Self.config], Self.origin]

    fn __init__(
        out self,
        src: Pointer[RecordParser[Self.R, Self.config], Self.origin],
    ):
        self._src = src

    fn __has_next__(self) -> Bool:
        return self._src[].has_more()

    fn __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[
            Pointer[RecordParser[Self.R, Self.config], MutExternalOrigin]
        ](self._src)
        try:
            return mut_ptr[].next()
        except Error:
            if String(Error) == EOF:
                raise StopIteration()
            else:
                print(String(Error))
            raise StopIteration()


struct BatchedParser[
    R: Reader,
    config: ParserConfig = ParserConfig(),
](Iterable, Movable):
    """
    Parser that extracts batches of FASTQ records in either Array-of-Structures (AoS)
    format for CPU parallelism or Structure-of-Arrays (SoA) format for GPU operations.
    Supports ``for batch in parser``; each element is a FastqBatch.
    """

    comptime IteratorType[
        mut: Bool, origin: Origin[mut=mut]
    ] = _BatchedParserIter[Self.R, Self.config, origin]

    var line_iter: LineIterator[Self.R]
    var quality_schema: QualitySchema
    var _batch_size: Int

    fn __init__(
        out self,
        var reader: Self.R,
        schema: String = "generic",
        default_batch_size: Int = 1024,
    ) raises:
        """Legacy constructor for backward compatibility."""
        self.line_iter = LineIterator(
            reader^,
            Self.config.buffer_capacity,
            Self.config.buffer_growth_enabled,
            Self.config.buffer_max_capacity,
        )
        if Self.config.quality_schema:
            self.quality_schema = self._parse_schema(
                Self.config.quality_schema.value()
            )
        else:
            self.quality_schema = self._parse_schema(schema)
        # Use config batch_size if provided, otherwise use default_batch_size
        if Self.config.batch_size:
            self._batch_size = Self.config.batch_size.value()
        else:
            self._batch_size = default_batch_size

    @staticmethod
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

    fn next_batch(mut self, max_records: Int = 1024) raises -> FastqBatch:
        """
        Extract a batch of records in Structure-of-Arrays format for GPU operations.

        Args:
            max_records: Maximum number of records to extract (default: batch_size).

        Returns:
            FastqBatch containing the extracted records in SoA format.
        """
        var actual_max = min(max_records, self._batch_size)
        var batch = FastqBatch(batch_size=actual_max)

        while len(batch) < actual_max and self.line_iter.has_more():
            var record = self._parse_record()
            batch.add(record^)
        return batch^

    @always_inline
    fn _has_more(self) -> Bool:
        """True if there may be more input (more lines in the buffer or stream).
        """
        return self.line_iter.has_more()

    fn __iter__(
        ref self,
    ) -> _BatchedParserIter[Self.R, Self.config, origin_of(self)]:
        """Return an iterator for use in ``for batch in self``."""
        return _BatchedParserIter[Self.R, Self.config, origin_of(self)](
            Pointer(to=self)
        )

    # TODO: Replace by a ref_based record parsing
    @always_inline
    fn _parse_record(mut self) raises -> FastqRecord:
        """Parse a single FASTQ record (4 lines) from the stream."""
        var line1 = ByteString(self.line_iter.next_line())
        var line2 = ByteString(self.line_iter.next_line())
        var line3 = ByteString(self.line_iter.next_line())
        var line4 = ByteString(self.line_iter.next_line())
        schema = self.quality_schema.copy()
        return FastqRecord(line1^, line2^, line3^, line4^, schema)


# ---------------------------------------------------------------------------
# Iterator adapter for BatchedParser so that ``for batch in parser`` works.
# ---------------------------------------------------------------------------


struct _BatchedParserIter[R: Reader, config: ParserConfig, origin: Origin](
    Iterator
):
    """Iterator over FASTQ batches; yields FastqBatch per batch."""

    comptime Element = FastqBatch

    var _src: Pointer[BatchedParser[Self.R, Self.config], Self.origin]

    fn __init__(
        out self,
        src: Pointer[BatchedParser[Self.R, Self.config], Self.origin],
    ):
        self._src = src

    fn __has_next__(self) -> Bool:
        return self._src[]._has_more()

    fn __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[
            Pointer[BatchedParser[Self.R, Self.config], MutExternalOrigin]
        ](self._src)
        try:
            var batch = mut_ptr[].next_batch()
            if len(batch) == 0:
                raise StopIteration()
            return batch^
        except:
            raise StopIteration()


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
struct SearchResults(Copyable, ImplicitlyDestructible, Movable):
    var start: Int
    var header_end: Int
    var seq_end: Int
    var qual_header_end: Int
    var qual_end: Int
    var step: Int

    comptime DEFAULT = Self(-1, -1, -1, -1, -1, 1)

    @always_inline
    fn is_set(self) -> Bool:
        return (
            not self.start == -1
            and not self.header_end == -1
            and not self.seq_end == -1
            and not self.qual_header_end == -1
            and not self.qual_end == -1
        )

    # How this work with line breaks \n or \r\n?
    @always_inline
    fn as_spans(
        self, ptr: UnsafePointer[Byte, MutExternalOrigin]
    ) raises -> InlineArray[Span[Byte, MutExternalOrigin], 4]:
        if not self.is_set():
            raise Error("SearchResults is not set")

        return InlineArray[Span[Byte, MutExternalOrigin], 4](
            Span[Byte, MutExternalOrigin](
                ptr=ptr + self.start,
                length=self.header_end - self.start - self.step,
            ),
            Span[Byte, MutExternalOrigin](
                ptr=ptr + self.header_end,
                length=self.seq_end - self.header_end - self.step,
            ),
            Span[Byte, MutExternalOrigin](
                ptr=ptr + self.seq_end,
                length=self.qual_header_end - self.seq_end - self.step,
            ),
            Span[Byte, MutExternalOrigin](
                ptr=ptr + self.qual_header_end,
                length=self.qual_end - self.qual_header_end - self.step,
            ),
        )

    @always_inline
    fn _add_if_set(self, val: Int, amt: Int) -> Int:
        return val + amt if val != -1 else val

    fn __add__(self, amt: Int) -> Self:
        return Self(
            self._add_if_set(self.start, amt),
            self._add_if_set(self.header_end, amt),
            self._add_if_set(self.seq_end, amt),
            self._add_if_set(self.qual_header_end, amt),
            self._add_if_set(self.qual_end, amt),
            self.step,
        )

    fn __sub__(self, amt: Int) -> Self:
        return Self(
            self._add_if_set(self.start, -amt),
            self._add_if_set(self.header_end, -amt),
            self._add_if_set(self.seq_end, -amt),
            self._add_if_set(self.qual_header_end, -amt),
            self._add_if_set(self.qual_end, -amt),
            self.step,
        )

    fn __getitem__(self, index: Int) -> Int:
        if index == 0:
            return self.start
        elif index == 1:
            return self.header_end
        elif index == 2:
            return self.seq_end
        elif index == 3:
            return self.qual_header_end
        elif index == 4:
            return self.qual_end
        else:
            return -1

    fn __setitem__(mut self, index: Int, value: Int):
        if index == 0:
            self.start = value
        elif index == 1:
            self.header_end = value
        elif index == 2:
            self.seq_end = value
        elif index == 3:
            self.qual_header_end = value
        elif index == 4:
            self.qual_end = value
        else:
            pass


struct RefParser[R: Reader, config: ParserConfig = ParserConfig()]:
    var stream: LineIterator[Self.R]
    var quality_schema: QualitySchema
    var validator: Validator
    var _staging: List[ByteString]

    fn __init__(
        out self,
        var reader: Self.R,
    ) raises:
        self.stream = LineIterator(
            reader^,
            Self.config.buffer_capacity,
            Self.config.buffer_growth_enabled,
            Self.config.buffer_max_capacity,
        )
        if Self.config.quality_schema:
            self.quality_schema = _parse_schema(
                Self.config.quality_schema.value()
            )
        else:
            self.quality_schema = materialize[generic_schema]()
        self.validator = Validator(
            Self.config.check_ascii,
            Self.config.check_quality,
            self.quality_schema.copy(),
        )
        self._staging = List[ByteString](capacity=4)

    @always_inline
    fn next(
        mut self,
    ) raises -> RefRecord[origin=MutExternalOrigin]:
        ref_record = self._parse_record()
        self.validator.validate(ref_record)
        return ref_record^

    fn _parse_record(
        mut self,
    ) raises -> RefRecord[origin=MutExternalOrigin]:
        if not self.stream.has_more():
            raise EOFError()

        var state = SearchState.START
        var interim = SearchResults.DEFAULT
        try:
            return _parse_record_fast_path(
                self.stream, interim, state, self.quality_schema
            )
        except e:
            if e == LineIteratorError.EOF:
                raise EOFError()
            if e == LineIteratorError.INCOMPLETE_LINE:
                return _handle_incomplete_line(
                    self.stream, interim, state, self.quality_schema
                )
            else:
                raise e


@always_inline
fn _handle_incomplete_line[
    R: Reader
](
    mut stream: LineIterator[R],
    mut interim: SearchResults,
    mut state: SearchState,
    quality_schema: QualitySchema,
) raises -> RefRecord[origin=MutExternalOrigin]:
    stream.buffer._compact_from(interim.start)
    interim = interim - interim.start

    lines_left = 5 - state.state
    for i in range(1, lines_left):
        try:
            var line = stream.next_complete_line()
            pos = stream.buffer.buffer_position()
            interim[i] = pos
            # Get the step needed 1 or 2 if \n or \r\n respectively
            interim.step = pos - interim[i - 1] - len(line)
            state = state + 1
        except e:
            if e == LineIteratorError.EOF:
                raise EOFError()
            else:
                raise e
    return _construct_ref_record(
        stream.buffer.view().unsafe_ptr(), interim, quality_schema
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
    interim[0] = stream.buffer.buffer_position()
    for i in range(1, 5):
        try:
            var line = stream.next_complete_line()
            pos = stream.buffer.buffer_position()
            interim[i] = pos
            # Get the step needed 1 or 2 if \n or \r\n respectively
            interim.step = pos - interim[i - 1] - len(line)
            state = state + 1
        except e:
            raise e

    try:
        return _construct_ref_record(
            stream.buffer.view().unsafe_ptr(), interim, quality_schema
        )
    except Error:
        raise LineIteratorError.OTHER


@always_inline
fn _construct_ref_record(
    ptr: UnsafePointer[Byte, MutExternalOrigin],
    interim: SearchResults,
    quality_schema: QualitySchema,
) raises -> RefRecord[origin=MutExternalOrigin]:
    var spans = interim.as_spans(ptr)
    return RefRecord[origin=MutExternalOrigin](
        spans[0],
        spans[1],
        spans[2],
        spans[3],
        Int8(quality_schema.OFFSET),
    )
