from blazeseq.record import FastqRecord, RecordCoord, Validator
from blazeseq.CONSTS import *
from blazeseq.iostream import BufferedReader, Reader, LineIterator
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

    var line_iter: LineIterator[Self.R, check_ascii = Self.config.check_ascii]
    var quality_schema: QualitySchema
    var validator: Validator

    fn __init__(
        out self,
        var reader: Self.R,
    ) raises:
        """Initialize RecordParser with optional ParserConfig."""
        self.line_iter = LineIterator[check_ascii = Self.config.check_ascii](
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
            self.config.check_quality,
            self.quality_schema.copy(),
        )

    fn __init__(
        out self,
        var reader: Self.R,
        quality_schema: String,
    ) raises:
        """Initialize RecordParser with optional ParserConfig."""
        self.line_iter = LineIterator[check_ascii = Self.config.check_ascii](
            reader^,
            self.config.buffer_capacity,
            self.config.buffer_growth_enabled,
            self.config.buffer_max_capacity,
        )
        self.quality_schema = _parse_schema(quality_schema)
        self.validator = Validator(
            self.config.check_quality,
            self.quality_schema.copy(),
        )

    fn parse_all(mut self) raises:
        # Check if file is empty - if so, raise EOF error
        if not self.line_iter.has_more():
            raise Error("EOF")

        while True:
            if not self.line_iter.has_more():
                break
            var record: FastqRecord
            record = self._parse_record()
            self.validator.validate(record)

    @always_inline
    fn _next(
        mut self,
    ) raises -> Optional[FastqRecord]:
        """Method that lazily returns the Next record in the file."""
        if self.line_iter.has_more():
            var record: FastqRecord
            record = self._parse_record()
            self.validator.validate(record)
            return record^
        else:
            return None

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
            var opt = mut_ptr[]._next()
            if not opt:
                raise StopIteration()
            return opt.take()
        except:
            raise StopIteration()


# struct BatchedParser[
#     R: Reader,
#     check_ascii: Bool = True,
#     check_quality: Bool = True,
#     batch_size: Int = 1024,
# ]:
#     """
#     Parser that extracts batches of FASTQ records in either Array-of-Structures (AoS)
#     format for CPU parallelism or Structure-of-Arrays (SoA) format for GPU operations.
#     """

#     var line_iter: LineIterator[Self.R, check_ascii = Self.check_ascii]
#     var quality_schema: QualitySchema
#     var _batch_size: Int

#     fn __init__(
#         out self,
#         var reader: Self.R,
#         config: ParserConfig = ParserConfig(),
#     ) raises:
#         """Initialize BatchedParser with optional ParserConfig."""
#         self.line_iter = LineIterator[check_ascii = Self.check_ascii](
#             reader^,
#             config.buffer_capacity,
#             config.buffer_growth_enabled,
#             config.buffer_max_capacity,
#         )
#         self.quality_schema = self._parse_schema(config.quality_schema)
#         # Use config batch_size if provided, otherwise use compile-time parameter
#         if config.batch_size:
#             self._batch_size = config.batch_size.value()
#         else:
#             self._batch_size = Self.batch_size

#     fn __init__(
#         out self,
#         var reader: Self.R,
#         schema: String = "generic",
#         default_batch_size: Int = 1024,
#     ) raises:
#         """Legacy constructor for backward compatibility."""
#         var config = ParserConfig(
#             quality_schema=schema,
#             batch_size=default_batch_size,
#         )
#         self.line_iter = LineIterator[check_ascii = Self.check_ascii](
#             reader^,
#             config.buffer_capacity,
#             config.buffer_growth_enabled,
#             config.buffer_max_capacity,
#         )
#         self.quality_schema = self._parse_schema(config.quality_schema)
#         # Use config batch_size if provided, otherwise use compile-time parameter
#         if config.batch_size:
#             self._batch_size = config.batch_size.value()
#         else:
#             self._batch_size = Self.batch_size

#     @staticmethod
#     @always_inline
#     fn _parse_schema(quality_format: String) -> QualitySchema:
#         """Parse quality schema string into QualitySchema."""
#         var schema: QualitySchema

#         if quality_format == "sanger":
#             schema = materialize[sanger_schema]()
#         elif quality_format == "solexa":
#             schema = materialize[solexa_schema]()
#         elif quality_format == "illumina_1.3":
#             schema = materialize[illumina_1_3_schema]()
#         elif quality_format == "illumina_1.5":
#             schema = materialize[illumina_1_5_schema]()
#         elif quality_format == "illumina_1.8":
#             schema = materialize[illumina_1_8_schema]()
#         elif quality_format == "generic":
#             schema = materialize[generic_schema]()
#         else:
#             print(
#                 """Unknown quality schema please choose one of 'sanger', 'solexa',"
#                 " 'illumina_1.3', 'illumina_1.5' 'illumina_1.8', or 'generic'.
#                 Parsing with generic schema."""
#             )
#             return materialize[generic_schema]()
#         return schema^


#     fn next_record_list(
#         mut self, max_records: Int = 0
#     ) raises -> List[FastqRecord[Self.check_quality]]:
#         """
#         Extract a batch of records in Array-of-Structures format for CPU parallelism.

#         Args:
#             max_records: Maximum number of records to extract (default: batch_size).

#         Returns:
#             List[FastqRecord[Self.check_quality]] containing the extracted records.
#         """
#         var actual_max = min(max_records, self._batch_size)
#         var batch = List[FastqRecord[Self.check_quality]](capacity=actual_max)
#         while len(batch) < actual_max and self.line_iter.has_more():
#             batch.append(self._parse_record())

#         return batch^

#     fn next_batch(mut self, max_records: Int = 1024) raises -> FastqBatch:
#         """
#         Extract a batch of records in Structure-of-Arrays format for GPU operations.

#         Args:
#             max_records: Maximum number of records to extract (default: batch_size).

#         Returns:
#             FastqBatch containing the extracted records in SoA format.
#         """
#         var actual_max = min(max_records, self._batch_size)
#         var batch = FastqBatch(batch_size=actual_max)

#         while len(batch) < actual_max and self.line_iter.has_more():
#             var record = self._parse_record()
#             batch.add(record^)
#         return batch^

#     @always_inline
#     fn _parse_record(mut self) raises -> FastqRecord[self.check_quality]:
#         """Parse a single FASTQ record (4 lines) from the stream."""
#         var lines = _get_n_lines[Self.R, 4, Self.check_ascii](self.line_iter.buffer)
#         var l1 = lines[0]
#         var l2 = lines[1]
#         var l3 = lines[2]
#         var l4 = lines[3]
#         schema = self.quality_schema.copy()
#         return FastqRecord[val = self.check_quality](l1, l2, l3, l4, schema)


# struct CoordParser[R: Reader, config: ParserConfig = ParserConfig()]:
#     var stream: LineIterator[Self.R, check_ascii = Self.config.check_ascii]
#     var quality_schema: QualitySchema
#     var validator: Validator

#     fn __init__(
#         out self,
#         var reader: Self.R,
#     ) raises:
#         self.stream = LineIterator[check_ascii = Self.config.check_ascii](
#             reader^,
#             Self.config.buffer_capacity,
#             Self.config.buffer_growth_enabled,
#             Self.config.buffer_max_capacity,
#         )
#         if Self.config.quality_schema:
#             self.quality_schema = _parse_schema(
#                 Self.config.quality_schema.value()
#             )
#         else:
#             self.quality_schema = materialize[generic_schema]()
#         self.validator = Validator(
#             Self.config.check_quality,
#             self.quality_schema.copy(),
#         )

#     @always_inline
#     fn parse_all(mut self) raises:
#         if not self.stream.has_more():
#             raise Error("EOF")
#         while True:
#             if not self.stream.has_more():
#                 break
#             record = self._parse_record()
#             record.validate_record()

#             @parameter
#             if Self.config.check_quality:
#                 record.validate_quality_schema()

#     @always_inline
#     fn next(
#         mut self,
#     ) raises -> RecordCoord[validate_quality = Self.config.check_quality]:
#         read = self._parse_record()
#         read.validate_record()

#         @parameter
#         if Self.config.check_quality:
#             read.validate_quality_schema()
#         return read^

#     @always_inline
#     fn _parse_record(
#         mut self,
#     ) raises -> RecordCoord[validate_quality = Self.config.check_quality]:
#         lines = self.stream.get_n_lines[4]()
#         l1, l2, l3, l4 = lines[0], lines[1], lines[2], lines[3]

#         return RecordCoord[
#             validate_quality = self.config.__del__is_trivialcheck_quality
#         ](l1, l2, l3, l4)
