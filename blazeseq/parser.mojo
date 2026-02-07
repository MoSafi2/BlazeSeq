from blazeseq.record import FastqRecord, RecordCoord
from blazeseq.CONSTS import *
from blazeseq.iostream import BufferedReader, FileReader, Reader
from blazeseq.device_record import FastqBatch
from blazeseq.utils import memchr
import time


@always_inline
fn _has_more_lines[R: Reader, check_ascii: Bool](
    stream: BufferedReader[R, check_ascii],
) -> Bool:
    """True if there are more lines (data in buffer or more data can be read)."""
    return stream.available() > 0 or not stream.is_eof()


fn _get_n_lines[R: Reader, n: Int, check_ascii: Bool](
    mut stream: BufferedReader[R, check_ascii],
) raises -> InlineArray[Span[Byte, MutExternalOrigin], n]:
    """
    Read exactly n lines from the buffer. Edge cases: EOF before n lines (raise),
    last line without newline (count as one line), line longer than capacity (raise).
    """
    if n == 0:
        return InlineArray[Span[Byte, MutExternalOrigin], n](uninitialized=True)

    var batch_start: Int = 0

    while True:
        if not stream.ensure_available(1):
            if stream.available() == 0:
                raise Error(
                    "EOF reached before getting all requested lines"
                )
        var view = stream.peek(stream.available())
        var current = batch_start
        var results = InlineArray[Span[Byte, MutExternalOrigin], n](
            uninitialized=True
        )
        var need_refill = False

        for i in range(n):
            while True:
                var search_start = current
                if search_start >= len(view):
                    need_refill = True
                    break
                var line_end = memchr(
                    haystack=view, chr=UInt8(new_line), start=search_start
                )

                if line_end >= 0:
                    results[i] = view[current:line_end]
                    current = line_end + 1
                    break

                if stream.is_eof():
                    if current < len(view):
                        results[i] = view[current:len(view)]
                        current = len(view)
                        if i + 1 < n:
                            raise Error(
                                "EOF reached before getting all requested lines"
                            )
                        stream.consume(current)
                        return results^
                    else:
                        raise Error(
                            "EOF reached before getting all requested lines"
                        )

                need_refill = True
                var data_to_preserve = len(view) - batch_start
                if data_to_preserve > stream.capacity():
                    raise Error(
                        "Batch of lines is longer than the buffer capacity."
                    )
                stream.compact_from(stream.read_position() + batch_start)
                batch_start = 0
                if not stream.ensure_available(stream.available() + 1):
                    raise Error(
                        "EOF reached before getting all requested lines"
                    )
                view = stream.peek(stream.available())
                break

            if need_refill:
                break

        if not need_refill:
            stream.consume(current)
            return results^


struct RecordParser[
    R: Reader, check_ascii: Bool = True, check_quality: Bool = True
]:
    var stream: BufferedReader[Self.R, check_ascii = Self.check_ascii]
    var quality_schema: QualitySchema

    fn __init__(
        out self, var reader: Self.R, schema: String = "generic"
    ) raises:
        self.stream = BufferedReader[check_ascii = Self.check_ascii](
            reader^, DEFAULT_CAPACITY
        )
        self.quality_schema = self._parse_schema(schema)

    fn parse_all(mut self) raises:
        # Check if file is empty - if so, raise EOF error
        if not _has_more_lines(self.stream):
            raise Error("EOF")

        while True:
            if not _has_more_lines(self.stream):
                break
            var record: FastqRecord[self.check_quality]
            record = self._parse_record()
            record.validate_record()

            # ASCII validation is carried out in the reader
            @parameter
            if Self.check_quality:
                record.validate_quality_schema()

    @always_inline
    fn next(mut self) raises -> Optional[FastqRecord[val = self.check_quality]]:
        """Method that lazily returns the Next record in the file."""
        if _has_more_lines(self.stream):
            var record: FastqRecord[self.check_quality]
            record = self._parse_record()
            record.validate_record()

            # ASCII validation is carried out in the reader
            @parameter
            if Self.check_quality:
                record.validate_quality_schema()
            return record^
        else:
            return None

    @always_inline
    fn _parse_record(mut self) raises -> FastqRecord[self.check_quality]:
        var lines = _get_n_lines[Self.R, 4, Self.check_ascii](self.stream)
        var l1 = lines[0]
        var l2 = lines[1]
        var l3 = lines[2]
        var l4 = lines[3]
        schema = self.quality_schema.copy()
        return FastqRecord[val = self.check_quality](l1, l2, l3, l4, schema)

    @staticmethod
    @always_inline
    fn _parse_schema(quality_format: String) -> QualitySchema:
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
                """Uknown quality schema please choose one of 'sanger', 'solexa',"
                " 'illumina_1.3', 'illumina_1.5' 'illumina_1.8', or 'generic'.
                Parsing with generic schema."""
            )
            return materialize[generic_schema]()
        return schema^


struct BatchedParser[
    R: Reader,
    check_ascii: Bool = True,
    check_quality: Bool = True,
    batch_size: Int = 1024,
]:
    """
    Parser that extracts batches of FASTQ records in either Array-of-Structures (AoS)
    format for CPU parallelism or Structure-of-Arrays (SoA) format for GPU operations.
    """

    var stream: BufferedReader[Self.R, check_ascii = Self.check_ascii]
    var quality_schema: QualitySchema
    var _batch_size: Int

    fn __init__(
        out self,
        var reader: Self.R,
        schema: String = "generic",
        default_batch_size: Int = 1024,
    ) raises:
        self.stream = BufferedReader[check_ascii = Self.check_ascii](
            reader^, DEFAULT_CAPACITY
        )
        self.quality_schema = self._parse_schema(schema)
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

    fn next_record_list(
        mut self, max_records: Int = 0
    ) raises -> List[FastqRecord[Self.check_quality]]:
        """
        Extract a batch of records in Array-of-Structures format for CPU parallelism.

        Args:
            max_records: Maximum number of records to extract (default: batch_size).

        Returns:
            List[FastqRecord[Self.check_quality]] containing the extracted records.
        """
        var actual_max = min(max_records, self._batch_size)
        var batch = List[FastqRecord[Self.check_quality]](capacity=actual_max)
        while len(batch) < actual_max and _has_more_lines(self.stream):
            batch.append(self._parse_record())

        return batch^

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

        while len(batch) < actual_max and _has_more_lines(self.stream):
            var record = self._parse_record()
            batch.add(record^)
        return batch^

    @always_inline
    fn _parse_record(mut self) raises -> FastqRecord[self.check_quality]:
        """Parse a single FASTQ record (4 lines) from the stream."""
        var lines = _get_n_lines[Self.R, 4, Self.check_ascii](self.stream)
        var l1 = lines[0]
        var l2 = lines[1]
        var l3 = lines[2]
        var l4 = lines[3]
        schema = self.quality_schema.copy()
        return FastqRecord[val = self.check_quality](l1, l2, l3, l4, schema)


# struct CoordParser[
#     R: Reader, check_ascii: Bool = True, check_quality: Bool = True
# ]:
#     var stream: BufferedReader[Self.R, check_ascii = Self.check_ascii]

#     fn __init__(
#         out self, var reader: Self.R, schema: String = "generic"
#     ) raises:
#         self.stream = BufferedReader[check_ascii = self.check_ascii](
#             reader^, DEFAULT_CAPACITY
#         )

#     @always_inline
#     fn parse_all(mut self) raises:
#         if not self.stream.has_more_lines():
#             raise Error("EOF")
#         while True:
#             if not self.stream.has_more_lines():
#                 break
#             record = self._parse_record()
#             record.validate_record()

#             @parameter
#             if Self.check_quality:
#                 record.validate_quality_schema()

#     @always_inline
#     fn next(
#         mut self,
#     ) raises -> RecordCoord[validate_quality = Self.check_quality]:
#         read = self._parse_record()
#         read.validate_record()

#         @parameter
#         if self.check_quality:
#             read.validate_quality_schema()
#         return read^

#     @always_inline
#     fn _parse_record(
#         mut self,
#     ) raises -> RecordCoord[validate_quality = Self.check_quality]:
#         lines = self.stream.get_n_lines[4]()
#         l1, l2, l3, l4 = lines[0], lines[1], lines[2], lines[3]

#         return RecordCoord[validate_quality = self.check_quality](
#             l1, l2, l3, l4
#         )
