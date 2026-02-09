from blazeseq.record import FastqRecord, RecordCoord
from blazeseq.CONSTS import *
from blazeseq.iostream import BufferedReader, Reader
from blazeseq.readers import Reader
from blazeseq.device_record import FastqBatch
from blazeseq.utils import memchr
from std.iter import Iterable, Iterator
import time


# ---------------------------------------------------------------------------
# ParserConfig: Configuration struct for parser options
# ---------------------------------------------------------------------------


struct ParserConfig:
    """
    Configuration struct for FASTQ parser options.
    Centralizes buffer capacity, growth policy, validation flags, and quality schema settings.
    """

    var buffer_capacity: Int
    var buffer_max_capacity: Int
    var buffer_growth_enabled: Bool
    var check_ascii: Bool
    var check_quality: Bool
    var quality_schema: String
    var batch_size: Optional[Int]

    fn __init__(
        out self,
        buffer_capacity: Int = DEFAULT_CAPACITY,
        buffer_max_capacity: Int = MAX_CAPACITY,
        buffer_growth_enabled: Bool = False,
        check_ascii: Bool = True,
        check_quality: Bool = True,
        quality_schema: String = "generic",
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
# LineIterator: newline-separated line reading on top of BufferedReader.
# Line bytes exclude newline; optionally trim trailing \\r.
# Caller must not hold returned spans across next next_line() or buffer mutation.
# ---------------------------------------------------------------------------


struct LineIterator[R: Reader, check_ascii: Bool = False](Iterable):
    """
    Iterates over newline-separated lines from a BufferedReader.
    Owns the buffer; parsers hold LineIterator and use next_line/next_n_lines.

    Supports the Mojo Iterator protocol: ``for line in line_iterator`` works.
    Each ``line`` is a ``Span[Byte, MutExternalOrigin]`` invalidated by the
    next iteration or any buffer mutation (same contract as ``next_line()``).
    """

    comptime IteratorType[
        mut: Bool, origin: Origin[mut=mut]
    ] = _LineIteratorIter[Self.R, Self.check_ascii, origin]

    var buffer: BufferedReader[Self.R, check_ascii = Self.check_ascii]
    var _growth_enabled: Bool
    var _max_capacity: Int

    fn __init__(
        out self,
        var reader: Self.R,
        capacity: Int = DEFAULT_CAPACITY,
        growth_enabled: Bool = False,
        max_capacity: Int = MAX_CAPACITY,
    ) raises:
        self.buffer = BufferedReader[check_ascii = Self.check_ascii](
            reader^, capacity
        )
        self._growth_enabled = growth_enabled
        self._max_capacity = max_capacity

    @always_inline
    fn position(self) -> Int:
        """Logical byte position of next line start (for errors and compaction).
        """
        return self.buffer.stream_position()

    @always_inline
    fn has_more(self) -> Bool:
        """True if there is at least one more line (data in buffer or more can be read).
        """
        return self.buffer.available() > 0 or not self.buffer.is_eof()

    fn __iter__(
        ref self,
    ) -> _LineIteratorIter[Self.R, Self.check_ascii, origin_of(self)]:
        """Return an iterator for use in ``for line in self``."""
        return _LineIteratorIter[Self.R, Self.check_ascii, origin_of(self)](
            Pointer(to=self)
        )

    fn next_line(mut self) raises -> Optional[Span[Byte, MutExternalOrigin]]:
        """
        Next line as span excluding newline (and trimming trailing \\r). None at EOF.
        Invalidated by next next_line() or any buffer mutation.
        """
        while True:
            if not self.buffer.ensure_available(1):
                if self.buffer.available() == 0:
                    return None
            var view = self.buffer.view()
            var line_end = memchr(haystack=view, chr=UInt8(new_line), start=0)
            if line_end >= 0:
                var start = 0
                var end = line_end
                if end > start and view[end - 1] == carriage_return:
                    end -= 1
                var span = view[start:end]
                self.buffer.consume(line_end + 1)
                return span

            if self.buffer.is_eof():
                if len(view) > 0:
                    var end = len(view)
                    if end > 0 and view[end - 1] == carriage_return:
                        end -= 1
                    var span = view[0:end]
                    self.buffer.consume(len(view))
                    return span
                return None

            if len(view) > self.buffer.capacity():
                if self._growth_enabled:
                    # Try to grow buffer
                    var current_capacity = self.buffer.capacity()
                    if current_capacity >= self._max_capacity:
                        raise Error(
                            "Line is longer than the maximum buffer capacity."
                        )
                    # Grow by doubling capacity or adding fixed amount, up to max
                    var growth_amount = min(
                        current_capacity, self._max_capacity - current_capacity
                    )
                    if growth_amount > 0:
                        self.buffer.grow_buffer(
                            growth_amount, self._max_capacity
                        )
                        # Retry reading after growth - continue loop to read more data
                        continue
                    else:
                        raise Error(
                            "Line is longer than the maximum buffer capacity."
                        )
                else:
                    raise Error("Line is longer than the buffer capacity.")
            self.buffer._compact_from(self.buffer.buffer_position())
            if not self.buffer.ensure_available(self.buffer.available() + 1):
                if self.buffer.available() == 0:
                    return None
                var v = self.buffer.view()
                var e = len(v)
                if e > 0 and v[e - 1] == carriage_return:
                    e -= 1
                var sp = v[0:e]
                self.buffer.consume(len(v))
                return sp

    fn next_n_lines[
        n: Int
    ](mut self) raises -> InlineArray[Span[Byte, MutExternalOrigin], n]:
        """
        Exactly n lines; raises if EOF before n. Convenience for FASTQ (4 lines per record).
        """
        if n == 0:
            return InlineArray[Span[Byte, MutExternalOrigin], n](
                uninitialized=True
            )
        var batch_start: Int = 0
        while True:
            if not self.buffer.ensure_available(1):
                if self.buffer.available() == 0:
                    raise Error(
                        "EOF reached before getting all requested lines"
                    )
            var view = self.buffer.view()
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
                        var lo = current
                        var hi = line_end
                        if hi > lo and view[hi - 1] == carriage_return:
                            hi -= 1
                        results[i] = view[lo:hi]
                        current = line_end + 1
                        break
                    if self.buffer.is_eof():
                        if current < len(view):
                            var lo = current
                            var hi = len(view)
                            if hi > lo and view[hi - 1] == carriage_return:
                                hi -= 1
                            results[i] = view[lo:hi]
                            current = len(view)
                            if i + 1 < n:
                                raise Error(
                                    "EOF reached before getting all requested"
                                    " lines"
                                )
                            self.buffer.consume(current)
                            return results^
                        else:
                            raise Error(
                                "EOF reached before getting all requested lines"
                            )
                    need_refill = True
                    var data_to_preserve = len(view) - batch_start
                    if data_to_preserve > self.buffer.capacity():
                        if self._growth_enabled:
                            # Try to grow buffer
                            var current_capacity = self.buffer.capacity()
                            if current_capacity >= self._max_capacity:
                                raise Error(
                                    "Line is longer than the maximum buffer"
                                    " capacity."
                                )
                            # Grow by doubling capacity or adding fixed amount, up to max
                            var growth_amount = min(
                                current_capacity,
                                self._max_capacity - current_capacity,
                            )
                            if growth_amount > 0:
                                self.buffer.grow_buffer(
                                    growth_amount, self._max_capacity
                                )
                                # Retry reading after growth - continue inner loop
                                if not self.buffer.ensure_available(
                                    self.buffer.available() + 1
                                ):
                                    raise Error(
                                        "EOF reached before getting all"
                                        " requested lines"
                                    )
                                view = self.buffer.view()
                                continue
                            else:
                                raise Error(
                                    "Line is longer than the maximum buffer"
                                    " capacity."
                                )
                        else:
                            raise Error(
                                "Line is longer than the buffer capacity."
                            )
                    self.buffer._compact_from(
                        self.buffer.buffer_position() + batch_start
                    )
                    batch_start = 0
                    if not self.buffer.ensure_available(
                        self.buffer.available() + 1
                    ):
                        raise Error(
                            "EOF reached before getting all requested lines"
                        )
                    view = self.buffer.view()
                    break
                if need_refill:
                    break
            if not need_refill:
                self.buffer.consume(current)
                return results^


# ---------------------------------------------------------------------------
# Iterator adapter for LineIterator so that ``for line in line_iter`` works.
# ---------------------------------------------------------------------------


struct _LineIteratorIter[R: Reader, check_ascii: Bool, origin: Origin](
    Iterator
):
    """Iterator over lines; yields Span[Byte, MutExternalOrigin] per line."""

    comptime Element = Span[Byte, MutExternalOrigin]

    var _src: Pointer[LineIterator[Self.R, Self.check_ascii], Self.origin]

    fn __init__(
        out self,
        src: Pointer[LineIterator[Self.R, Self.check_ascii], Self.origin],
    ):
        self._src = src

    fn __has_next__(self) -> Bool:
        return self._src[].has_more()

    fn __next__(mut self) raises StopIteration -> Self.Element:
        # Rebind pointer to mutable origin so we can call next_line().
        var mut_ptr = rebind[
            Pointer[LineIterator[Self.R, Self.check_ascii], MutExternalOrigin]
        ](self._src)
        try:
            var opt = mut_ptr[].next_line()
            if not opt:
                raise StopIteration()
            return opt.value()
        except:
            # I/O or other errors from next_line() surfaced as StopIteration
            # so the Iterator trait is satisfied; callers using next_line()
            # directly still get proper Error propagation.
            raise StopIteration()


@always_inline
fn _has_more_lines[
    R: Reader, check_ascii: Bool
](stream: BufferedReader[R, check_ascii],) -> Bool:
    """True if there are more lines (data in buffer or more data can be read).
    """
    return stream.available() > 0 or not stream.is_eof()


fn _get_n_lines[
    R: Reader, n: Int, check_ascii: Bool
](
    mut stream: BufferedReader[R, check_ascii],
) raises -> InlineArray[
    Span[Byte, MutExternalOrigin], n
]:
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
                raise Error("EOF reached before getting all requested lines")
        var view = stream.view()
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
                        results[i] = view[current : len(view)]
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
                    raise Error("Line is longer than the buffer capacity.")
                stream._compact_from(stream.buffer_position() + batch_start)
                batch_start = 0
                if not stream.ensure_available(stream.available() + 1):
                    raise Error(
                        "EOF reached before getting all requested lines"
                    )
                view = stream.view()
                break

            if need_refill:
                break

        if not need_refill:
            stream.consume(current)
            return results^


struct RecordParser[
    R: Reader, check_ascii: Bool = True, check_quality: Bool = True
]:
    var line_iter: LineIterator[Self.R, check_ascii = Self.check_ascii]
    var quality_schema: QualitySchema

    fn __init__(
        out self,
        var reader: Self.R,
        config: ParserConfig = ParserConfig(),
    ) raises:
        """Initialize RecordParser with optional ParserConfig."""
        self.line_iter = LineIterator[check_ascii = Self.check_ascii](
            reader^,
            config.buffer_capacity,
            config.buffer_growth_enabled,
            config.buffer_max_capacity,
        )
        self.quality_schema = self._parse_schema(config.quality_schema)

    fn __init__(
        out self,
        var reader: Self.R,
        schema: String = "generic",
    ) raises:
        """Legacy constructor for backward compatibility."""
        var config = ParserConfig(quality_schema=schema)
        self.line_iter = LineIterator[check_ascii = Self.check_ascii](
            reader^,
            config.buffer_capacity,
            config.buffer_growth_enabled,
            config.buffer_max_capacity,
        )
        self.quality_schema = self._parse_schema(config.quality_schema)

    fn parse_all(mut self) raises:
        # Check if file is empty - if so, raise EOF error
        if not self.line_iter.has_more():
            raise Error("EOF")

        while True:
            if not self.line_iter.has_more():
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
        if self.line_iter.has_more():
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
        var lines = self.line_iter.next_n_lines[4]()
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

    var line_iter: LineIterator[Self.R, check_ascii = Self.check_ascii]
    var quality_schema: QualitySchema
    var _batch_size: Int

    fn __init__(
        out self,
        var reader: Self.R,
        config: ParserConfig = ParserConfig(),
    ) raises:
        """Initialize BatchedParser with optional ParserConfig."""
        self.line_iter = LineIterator[check_ascii = Self.check_ascii](
            reader^,
            config.buffer_capacity,
            config.buffer_growth_enabled,
            config.buffer_max_capacity,
        )
        self.quality_schema = self._parse_schema(config.quality_schema)
        # Use config batch_size if provided, otherwise use compile-time parameter
        if config.batch_size:
            self._batch_size = config.batch_size.value()
        else:
            self._batch_size = Self.batch_size

    fn __init__(
        out self,
        var reader: Self.R,
        schema: String = "generic",
        default_batch_size: Int = 1024,
    ) raises:
        """Legacy constructor for backward compatibility."""
        var config = ParserConfig(
            quality_schema=schema,
            batch_size=default_batch_size,
        )
        self.line_iter = LineIterator[check_ascii = Self.check_ascii](
            reader^,
            config.buffer_capacity,
            config.buffer_growth_enabled,
            config.buffer_max_capacity,
        )
        self.quality_schema = self._parse_schema(config.quality_schema)
        # Use config batch_size if provided, otherwise use compile-time parameter
        if config.batch_size:
            self._batch_size = config.batch_size.value()
        else:
            self._batch_size = Self.batch_size

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
        while len(batch) < actual_max and self.line_iter.has_more():
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

        while len(batch) < actual_max and self.line_iter.has_more():
            var record = self._parse_record()
            batch.add(record^)
        return batch^

    @always_inline
    fn _parse_record(mut self) raises -> FastqRecord[self.check_quality]:
        """Parse a single FASTQ record (4 lines) from the stream."""
        var lines = self.line_iter.next_n_lines[4]()
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
