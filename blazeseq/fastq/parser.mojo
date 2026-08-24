from blazeseq.fastq.record import FastqRecord, FastqView, Validator
from blazeseq.CONSTS import *
from blazeseq.fastq.quality_schema import QualitySchema, generic_schema
from blazeseq.io.buffered import EOFError
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
from std.pathlib import Path
from blazeseq.byte_string import BString
from blazeseq.utils import _strip_spaces
from blazeseq.fastq.quality_schema import _parse_schema
from blazeseq.fastq.scan import (
    SCAN_MODE_MASKS,
    SCAN_MODE_MEMCHR_SEQ,
    RecordOffsets,
    SearchPhase,
)
from blazeseq.fastq.sources import (
    BufferedSource,
    FoundRecord,
    MmapSource,
    build_record_view,
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


trait FastqParserLike(Movable):
    """Static interface shared by every parser flavor (duck-typed iterators
    below are parameterized on this)."""

    def has_more(self) -> Bool: ...
    def next_view(mut self) raises -> FastqView[
        origin=MutUntrackedOrigin
    ]: ...
    def next_record(mut self) raises -> FastqRecord: ...
    def next_batch(mut self, max_records: Int) raises -> FastqBatch: ...


struct FastqParser[
    R: Reader,
    config: ParserConfig = ParserConfig(),
](Movable, FastqParserLike):
    """Buffered FASTQ parser over any `Reader`.

    Chunked reads through a `BufferedReader`; handles records spanning
    buffer edges via compaction and optional growth. For plain local files,
    `MmapFastqParser` offers a zero-copy alternative with the same API.
    """

    var src: BufferedSource[
        Self.R,
        Self.config.buffer_capacity,
        Self.config.buffer_growth_enabled,
        Self.config.buffer_max_capacity,
    ]
    var quality_schema: QualitySchema
    var validator: Validator
    var _batch_size: Int

    def __init__(
        out self,
        var reader: Self.R,
    ) raises:
        self.src = BufferedSource[
            Self.R,
            Self.config.buffer_capacity,
            Self.config.buffer_growth_enabled,
            Self.config.buffer_max_capacity,
        ](reader^)
        self.quality_schema = _resolve_effective_schema(
            Self.config.quality_schema, ""
        )
        self.validator = Validator(
            Self.config.check_ascii,
            Self.config.check_quality,
            self.quality_schema.copy(),
        )
        self._batch_size = DEFAULT_BATCH_SIZE

    def __init__(
        out self,
        var reader: Self.R,
        quality_schema: String,
    ) raises:
        self.src = BufferedSource[
            Self.R,
            Self.config.buffer_capacity,
            Self.config.buffer_growth_enabled,
            Self.config.buffer_max_capacity,
        ](reader^)
        self.quality_schema = _resolve_effective_schema(
            Self.config.quality_schema, quality_schema
        )
        self.validator = Validator(
            Self.config.check_ascii,
            Self.config.check_quality,
            self.quality_schema.copy(),
        )
        self._batch_size = DEFAULT_BATCH_SIZE

    def __init__(
        out self,
        var reader: Self.R,
        batch_size: Int,
        schema: String = "generic",
    ) raises:
        self.src = BufferedSource[
            Self.R,
            Self.config.buffer_capacity,
            Self.config.buffer_growth_enabled,
            Self.config.buffer_max_capacity,
        ](reader^)
        self.quality_schema = _resolve_effective_schema(
            Self.config.quality_schema, schema
        )
        self.validator = Validator(
            Self.config.check_ascii,
            Self.config.check_quality,
            self.quality_schema.copy(),
        )
        self._batch_size = batch_size

    @always_inline
    def _parse_context(ref self) -> ParseContext:
        return self.src.context()

    @always_inline
    def has_more(self) -> Bool:
        return self.src.has_more()

    @always_inline
    def next_view(mut self) raises -> FastqView[origin=MutUntrackedOrigin]:
        return self._next_view[SCAN_MODE_MASKS]()

    @always_inline
    def next_view_memchr_seq(
        mut self,
    ) raises -> FastqView[origin=MutUntrackedOrigin]:
        """Benchmark-only variant that scans record boundaries via sequential memchr.
        """
        return self._next_view[SCAN_MODE_MEMCHR_SEQ]()

    @always_inline
    def next_view_masks(
        mut self,
    ) raises -> FastqView[origin=MutUntrackedOrigin]:
        """Benchmark-only variant using the hoisted-mask SIMD scanner."""
        return self._next_view[SCAN_MODE_MASKS]()

    @always_inline
    def next_record(mut self) raises -> FastqRecord:
        if not self.has_more():
            raise EOFError()
        return self._record_from_view(self._next_view[SCAN_MODE_MASKS]())

    @always_inline
    def next_record_memchr_seq(mut self) raises -> FastqRecord:
        """Benchmark-only variant that scans record boundaries via sequential memchr.
        """
        if not self.has_more():
            raise EOFError()
        return self._record_from_view(
            self._next_view[SCAN_MODE_MEMCHR_SEQ]()
        )

    @always_inline
    def next_record_masks(mut self) raises -> FastqRecord:
        if not self.has_more():
            raise EOFError()
        return self._record_from_view(self.next_view_masks())

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

    def views(ref self) -> _FastqViewIter[Self, origin_of(self)]:
        return _FastqViewIter[Self, origin_of(self)](Pointer(to=self))

    def records(ref self) -> _FastqRecordIter[Self, origin_of(self)]:
        return _FastqRecordIter[Self, origin_of(self)](Pointer(to=self))

    def batches(
        ref self, max_records: Optional[Int] = None
    ) -> _FastqBatchIter[Self, origin_of(self)]:
        var limit = max_records.value() if max_records else self._batch_size
        return _FastqBatchIter[Self, origin_of(self)](Pointer(to=self), limit)

    @always_inline
    def _next_view[
        mode: Int8,
    ](mut self) raises -> FastqView[origin=MutUntrackedOrigin]:
        var found = self.src.find_next[mode]()
        var ref_rec = build_record_view(found, self.quality_schema.OFFSET)
        self.src.note_consumed()
        self._raise_if_invalid_view(ref_rec)
        return ref_rec

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


@always_inline
def _resolve_effective_schema(
    config_schema: Optional[String], explicit_schema: String
) -> QualitySchema:
    """Resolve the effective quality schema for a parser instance.

    `explicit_schema` wins when non-empty; otherwise the ParserConfig-level
    name (or generic) applies.
    """
    var schema: QualitySchema
    if explicit_schema:
        schema = _parse_schema(explicit_schema)
    elif config_schema:
        schema = _parse_schema(config_schema.value())
    else:
        schema = materialize[generic_schema]()
    return schema


struct MmapFastqParser(Movable, FastqParserLike):
    """Zero-copy FASTQ parser over a memory-mapped file.

    Same API surface as `FastqParser`; parses directly from the page cache
    with no buffering and no kernel-to-user copies. The parser owns the
    mapping, so record views stay valid until the next read. Best for plain
    local files; use `FastqParser` for gzip/network streams.

    Example:
        ```mojo
        var parser = MmapFastqParser(Path("data.fastq"))
        for view in parser.views():
            _ = view.sequence()
        ```
    """

    var src: MmapSource
    var quality_schema: QualitySchema
    var validator: Validator
    var _batch_size: Int

    def __init__(
        out self,
        path: Path,
        check_ascii: Bool = False,
        check_quality: Bool = False,
        quality_schema_name: String = "generic",
    ) raises:
        self.src = MmapSource(path)
        self.quality_schema = _parse_schema(quality_schema_name)
        self.validator = Validator(
            check_ascii,
            check_quality,
            self.quality_schema.copy(),
        )
        self._batch_size = DEFAULT_BATCH_SIZE

    @always_inline
    def _parse_context(ref self) -> ParseContext:
        return self.src.context()

    @always_inline
    def has_more(self) -> Bool:
        return self.src.has_more()

    @always_inline
    def next_view(mut self) raises -> FastqView[origin=MutUntrackedOrigin]:
        return self._next_view[SCAN_MODE_MASKS]()

    @always_inline
    def next_view_memchr_seq(
        mut self,
    ) raises -> FastqView[origin=MutUntrackedOrigin]:
        """Benchmark-only variant that scans record boundaries via sequential memchr.
        """
        return self._next_view[SCAN_MODE_MEMCHR_SEQ]()

    @always_inline
    def next_view_masks(
        mut self,
    ) raises -> FastqView[origin=MutUntrackedOrigin]:
        """Benchmark-only variant using the hoisted-mask SIMD scanner."""
        return self._next_view[SCAN_MODE_MASKS]()

    @always_inline
    def next_record(mut self) raises -> FastqRecord:
        if not self.has_more():
            raise EOFError()
        return self._record_from_view(self._next_view[SCAN_MODE_MASKS]())

    @always_inline
    def next_record_memchr_seq(mut self) raises -> FastqRecord:
        """Benchmark-only variant that scans record boundaries via sequential memchr.
        """
        if not self.has_more():
            raise EOFError()
        return self._record_from_view(
            self._next_view[SCAN_MODE_MEMCHR_SEQ]()
        )

    @always_inline
    def next_record_masks(mut self) raises -> FastqRecord:
        if not self.has_more():
            raise EOFError()
        return self._record_from_view(self.next_view_masks())

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

    def views(ref self) -> _FastqViewIter[Self, origin_of(self)]:
        return _FastqViewIter[Self, origin_of(self)](Pointer(to=self))

    def records(ref self) -> _FastqRecordIter[Self, origin_of(self)]:
        return _FastqRecordIter[Self, origin_of(self)](Pointer(to=self))

    def batches(
        ref self, max_records: Optional[Int] = None
    ) -> _FastqBatchIter[Self, origin_of(self)]:
        var limit = max_records.value() if max_records else self._batch_size
        return _FastqBatchIter[Self, origin_of(self)](Pointer(to=self), limit)

    @always_inline
    def _next_view[
        mode: Int8,
    ](mut self) raises -> FastqView[origin=MutUntrackedOrigin]:
        var found = self.src.find_next[mode]()
        var ref_rec = build_record_view(found, self.quality_schema.OFFSET)
        self.src.note_consumed()
        self._raise_if_invalid_view(ref_rec)
        return ref_rec

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


# Duck-typed iterators shared by every parser flavor: `P` only needs
# next_view()/next_record()/next_batch()/has_more().


struct _FastqViewIter[P: FastqParserLike, origin: Origin](Iterator):
    comptime Element = FastqView[origin=MutUntrackedOrigin]

    var _src: Pointer[Self.P, Self.origin]

    def __init__(out self, src: Pointer[Self.P, Self.origin]):
        self._src = src

    def __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    def __has_next__(self) -> Bool:
        return True

    @always_inline
    def __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[
            Pointer[Self.P, MutUntrackedOrigin]
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


struct _FastqRecordIter[P: FastqParserLike, origin: Origin](Iterator):
    comptime Element = FastqRecord

    var _src: Pointer[Self.P, Self.origin]

    def __init__(out self, src: Pointer[Self.P, Self.origin]):
        self._src = src

    def __iter__(ref self) -> Self:
        return Self(self._src)

    def __has_next__(self) -> Bool:
        return self._src[].has_more()

    def __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[
            Pointer[Self.P, MutUntrackedOrigin]
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


struct _FastqBatchIter[P: FastqParserLike, origin: Origin](Iterator):
    comptime Element = FastqBatch

    var _src: Pointer[Self.P, Self.origin]
    var _max_records: Int

    def __init__(
        out self, src: Pointer[Self.P, Self.origin], max_records: Int
    ):
        self._src = src
        self._max_records = max_records

    def __iter__(ref self) -> Self:
        return Self(self._src, self._max_records)

    def __has_next__(self) -> Bool:
        return self._src[].has_more()

    def __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[
            Pointer[Self.P, MutUntrackedOrigin]
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
