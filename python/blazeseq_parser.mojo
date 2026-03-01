"""
Python bindings for BlazeSeq FASTQ parser.

Exposes create_parser (returns a FastqParser) and type bindings for FastqRecord
and FastqBatch. Parser methods: has_more(), next_record(), next_ref_as_record(),
next_batch(max_records). Supports plain (.fastq, .fq) and gzip (.fastq.gz, .fq.gz).
Use from Python with:

  import blazeseq
  parser = blazeseq.create_parser("file.fastq", "sanger")
  # or for gzip: blazeseq.create_parser("file.fastq.gz", "sanger", parallelism=4)
  while parser.has_more():
      rec = parser.next_record()
      ...
"""

from python import PythonObject, Python
from python.bindings import PythonModuleBuilder
from pathlib import Path
from os import abort
from memory import UnsafePointer
from blazeseq.parser import FastqParser, ParserConfig
from blazeseq.record import FastqRecord, RefRecord
from blazeseq import FastqBatch
from blazeseq.io.readers import FileReader, RapidgzipReader
from blazeseq.io.buffered import EOFError
from blazeseq.CONSTS import EOF

# Concrete parser type for Python (FileReader + default ParserConfig).
comptime PyFastqParser = FastqParser[FileReader, ParserConfig()]
comptime PyFastqGZParser = FastqParser[RapidgzipReader, ParserConfig()]


# Holder for the parser so we can register it with add_type (FastqParser does not implement Representable).
struct BlazeSeqParserHolder(Movable, Representable):
    var parser: PyFastqParser

    fn __init__(out self, var parser: PyFastqParser):
        self.parser = parser^

    fn __repr__(self) -> String:
        return "BlazeSeqParser(...)"


struct BlazeSeqGZParserHolder(Movable, Representable):
    var parser: PyFastqGZParser

    fn __init__(out self, var parser: PyFastqGZParser):
        self.parser = parser^

    fn __repr__(self) -> String:
        return "BlazeSeqParser(...)"


# Wrapper so create_parser returns one type; has_more/next_* dispatch on plain vs gz.
struct BlazeSeqAnyParserHolder(Movable, Representable):
    var _plain: Optional[BlazeSeqParserHolder]
    var _gz: Optional[BlazeSeqGZParserHolder]

    fn __init__(out self, var holder: BlazeSeqParserHolder):
        self._plain = Optional[BlazeSeqParserHolder](holder^)
        self._gz = Optional[BlazeSeqGZParserHolder]()

    fn __init__(out self, var holder: BlazeSeqGZParserHolder):
        self._plain = Optional[BlazeSeqParserHolder]()
        self._gz = Optional[BlazeSeqGZParserHolder](holder^)

    fn __repr__(self) -> String:
        return "BlazeSeqParser(...)"


# ---------------------------------------------------------------------------
# create_parser (module-level) and parser method wrappers
# ---------------------------------------------------------------------------


fn parser(
    path: PythonObject, quality_schema: PythonObject, parallelism: PythonObject
) raises -> PythonObject:
    """Create a FASTQ parser for the given file path and quality schema.

    Args:
        path: File path as string (e.g. "data.fastq" or "data.fastq.gz").
        quality_schema: Schema name: "generic", "sanger", "solexa", "illumina_1.3", "illumina_1.5", "illumina_1.8".
        parallelism: Number of threads for gzip decompression (only for .fastq.gz / .fq.gz); pass 4 as default.

    Returns:
        Parser handle to pass to has_more, next_record, next_batch.
    """
    var path_str = String(path)
    var schema_str = String(quality_schema)
    var par = Int(py=parallelism)
    if path_str.endswith(".fastq.gz") or path_str.endswith(".fq.gz"):
        var reader = RapidgzipReader(path_str, par)
        var p = PyFastqGZParser(reader^, schema_str)
        var inner = BlazeSeqGZParserHolder(p^)
        var holder = BlazeSeqAnyParserHolder(inner^)
        return PythonObject(alloc=holder^)
    elif path_str.endswith(".fastq") or path_str.endswith(".fq"):
        var reader = FileReader(Path(path_str))
        var p = PyFastqParser(reader^, schema_str)
        var inner = BlazeSeqParserHolder(p^)
        var holder = BlazeSeqAnyParserHolder(inner^)
        return PythonObject(alloc=holder^)
    else:
        raise Error(
            "Unsupported file extension. Use .fastq, .fq, .fastq.gz, or .fq.gz"
        )


struct ParserMethods:
    @staticmethod
    fn has_more(py_self: PythonObject) raises -> PythonObject:
        """Return True if there may be more records to read."""
        var holder_ptr = py_self.downcast_value_ptr[BlazeSeqAnyParserHolder]()
        if holder_ptr[]._plain:
            return PythonObject(holder_ptr[]._plain.value().parser.has_more())
        return PythonObject(holder_ptr[]._gz.value().parser.has_more())

    @staticmethod
    fn next_record(py_self: PythonObject) raises -> PythonObject:
        """Return the next record as an owned FastqRecord. Raises on EOF or parse error."""
        var holder_ptr = py_self.downcast_value_ptr[BlazeSeqAnyParserHolder]()
        try:
            if holder_ptr[]._plain:
                var record = holder_ptr[]._plain.value().parser.next_record()
                return PythonObject(alloc=record^)
            var record = holder_ptr[]._gz.value().parser.next_record()
            return PythonObject(alloc=record^)
        except e:
            if String(e) == EOF or String(e).startswith(EOF):
                raise Error("EOF")
            raise e^

    @staticmethod
    fn next_ref_as_record(py_self: PythonObject) raises -> PythonObject:
        """Return the next record (from zero-copy ref) as owned FastqRecord. Raises on EOF or parse error."""
        var holder_ptr = py_self.downcast_value_ptr[BlazeSeqAnyParserHolder]()
        try:
            if holder_ptr[]._plain:
                var ref_rec = holder_ptr[]._plain.value().parser.next_ref()
                var record = FastqRecord(
                    ref_rec.id,
                    ref_rec.sequence,
                    ref_rec.quality,
                    Int8(holder_ptr[]._plain.value().parser.quality_schema.OFFSET),
                )
                return PythonObject(alloc=record^)
            var ref_rec = holder_ptr[]._gz.value().parser.next_ref()
            var record = FastqRecord(
                ref_rec.id,
                ref_rec.sequence,
                ref_rec.quality,
                Int8(holder_ptr[]._gz.value().parser.quality_schema.OFFSET),
            )
            return PythonObject(alloc=record^)
        except e:
            if String(e) == EOF or String(e).startswith(EOF):
                raise Error("EOF")
            raise e^

    @staticmethod
    fn next_batch(py_self: PythonObject, max_records: PythonObject) raises -> PythonObject:
        """Return a batch of up to max_records records as FastqBatch. Returns partial batch at EOF."""
        var holder_ptr = py_self.downcast_value_ptr[BlazeSeqAnyParserHolder]()
        var limit = Int(py=max_records)
        if holder_ptr[]._plain:
            var batch = holder_ptr[]._plain.value().parser.next_batch(limit)
            return PythonObject(alloc=batch^)
        var batch = holder_ptr[]._gz.value().parser.next_batch(limit)
        return PythonObject(alloc=batch^)

    # Iterator protocol: parser is both iterable and iterator.
    @staticmethod
    fn parser_py_iter(py_self: PythonObject) raises -> PythonObject:
        """Return self as the iterator."""
        return py_self

    @staticmethod
    @staticmethod
    fn parser_py_next(py_self: PythonObject) raises -> PythonObject:
        """Return the next FastqRecord or raise StopIteration when exhausted."""
        var self_ptr = py_self.downcast_value_ptr[BlazeSeqAnyParserHolder]()
        if self_ptr[]._plain:
            if not self_ptr[]._plain.value().parser.has_more():
                raise Error("StopIteration")
            try:
                var record = self_ptr[]._plain.value().parser.next_record()
                return PythonObject(alloc=record^)
            except e:
                if String(e) == EOF or String(e).startswith(EOF):
                    raise Error("StopIteration")
                raise e^
        if not self_ptr[]._gz.value().parser.has_more():
            raise Error("StopIteration")
        try:
            var record = self_ptr[]._gz.value().parser.next_record()
            return PythonObject(alloc=record^)
        except e:
            if String(e) == EOF or String(e).startswith(EOF):
                raise Error("StopIteration")
            raise e^


# ---------------------------------------------------------------------------
# FastqRecord method wrappers (@staticmethod with py_self for def_method)
# ---------------------------------------------------------------------------


struct FastqRecordMethods:
    @staticmethod
    fn get_id(py_self: PythonObject) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[FastqRecord]()
        return String(self_ptr[].id_slice())

    @staticmethod
    fn get_sequence(py_self: PythonObject) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[FastqRecord]()
        return String(self_ptr[].sequence_slice())

    @staticmethod
    fn get_quality(py_self: PythonObject) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[FastqRecord]()
        return String(self_ptr[].quality_slice())

    @staticmethod
    fn get_len(py_self: PythonObject) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[FastqRecord]()
        return PythonObject(self_ptr[].__len__())

    @staticmethod
    fn get_phred_scores(py_self: PythonObject) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[FastqRecord]()
        var scores = self_ptr[].phred_scores()
        var py_list = Python.evaluate("[]")
        for i in range(len(scores)):
            var append_fn = py_list.__getattr__("append")
            append_fn(Int(scores[i]))
        return py_list


# ---------------------------------------------------------------------------
# FastqBatch method wrappers
# ---------------------------------------------------------------------------


struct FastqBatchMethods:
    @staticmethod
    fn get_num_records(py_self: PythonObject) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[FastqBatch]()
        return PythonObject(self_ptr[].num_records())

    @staticmethod
    fn get_record_at(
        py_self: PythonObject, index: PythonObject
    ) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[FastqBatch]()
        var idx = Int(py=index)
        var record = self_ptr[].get_record(idx)
        return PythonObject(alloc=record^)

    @staticmethod
    fn batch_py_iter(py_self: PythonObject) raises -> PythonObject:
        """Return an iterator over records in the batch. Iterator is invalid after batch is discarded."""
        var batch_ptr = py_self.downcast_value_ptr[FastqBatch]()
        var count = batch_ptr[].num_records()
        var iter_val = FastqBatchIterator(batch_ptr, 0, count)
        return PythonObject(alloc=iter_val^)


# Iterator over FastqBatch records. Holds a pointer to the batch; batch must outlive the iterator.
struct FastqBatchIterator(Movable, Representable):
    var batch_ptr: UnsafePointer[FastqBatch, MutAnyOrigin]
    var index: Int
    var count: Int

    fn __init__(
        out self,
        batch_ptr: UnsafePointer[FastqBatch, MutAnyOrigin],
        index: Int,
        count: Int,
    ):
        self.batch_ptr = batch_ptr
        self.index = index
        self.count = count

    fn __repr__(self) -> String:
        return String(
            "FastqBatchIterator(index=",
            self.index,
            ", count=",
            self.count,
            ")"
        )

    @staticmethod
    fn py_iter(py_self: PythonObject) raises -> PythonObject:
        """Return self as the iterator."""
        return py_self

    @staticmethod
    @staticmethod
    fn py_next(py_self: PythonObject) raises -> PythonObject:
        """Return the next FastqRecord or raise StopIteration when exhausted."""
        var self_ptr = py_self.downcast_value_ptr[FastqBatchIterator]()
        if self_ptr[].index >= self_ptr[].count:
            raise Error("StopIteration")
        var record = self_ptr[].batch_ptr[].get_record(self_ptr[].index)
        self_ptr[].index += 1
        return PythonObject(alloc=record^)


# ---------------------------------------------------------------------------
# PyInit
# ---------------------------------------------------------------------------


@export
fn PyInit_blazeseq_parser() -> PythonObject:
    try:
        var mb = PythonModuleBuilder("blazeseq_parser")
        # Module-level: only create_parser
        mb.def_function[parser](
            "create_parser",
            docstring=(
                "Create a FASTQ parser for the given path and quality schema."
            ),
        )
        # Types: FastqParser with methods has_more, next_record, next_ref_as_record, next_batch
        _ = (
            mb.add_type[BlazeSeqAnyParserHolder]("FastqParser")
            .def_method[ParserMethods.has_more](
                "has_more",
                docstring="Return True if there may be more records to read.",
            )
            .def_method[ParserMethods.next_record](
                "next_record",
                docstring=(
                    "Return the next record as an owned FastqRecord. Raises on EOF"
                    " or parse error."
                ),
            )
            .def_method[ParserMethods.next_ref_as_record](
                "next_ref_as_record",
                docstring=(
                    "Return the next record (from zero-copy ref) as owned"
                    " FastqRecord. Raises on EOF or parse error."
                ),
            )
            .def_method[ParserMethods.next_batch](
                "next_batch",
                docstring=(
                    "Return a batch of up to max_records records as FastqBatch."
                ),
            )
            .def_method[ParserMethods.parser_py_iter]("__iter__")
            .def_method[ParserMethods.parser_py_next]("__next__")
        )
        _ = (
            mb.add_type[FastqRecord]("FastqRecord")
            .def_method[FastqRecordMethods.get_id](
                "id", docstring="Read identifier (without leading '@')."
            )
            .def_method[FastqRecordMethods.get_sequence](
                "sequence", docstring="Sequence line."
            )
            .def_method[FastqRecordMethods.get_quality](
                "quality", docstring="Quality line."
            )
            .def_method[FastqRecordMethods.get_len](
                "__len__", docstring="Sequence length (number of bases)."
            )
            .def_method[FastqRecordMethods.get_phred_scores](
                "phred_scores",
                docstring="Phred quality scores as a Python list.",
            )
        )
        _ = (
            mb.add_type[FastqBatch]("FastqBatch")
            .def_method[FastqBatchMethods.get_num_records](
                "num_records", docstring="Number of records in the batch."
            )
            .def_method[FastqBatchMethods.get_record_at](
                "get_record",
                docstring=(
                    "Return the record at the given index as FastqRecord."
                ),
            )
            .def_method[FastqBatchMethods.batch_py_iter]("__iter__")
        )
        _ = (
            mb.add_type[FastqBatchIterator]("FastqBatchIterator")
            .def_method[FastqBatchIterator.py_iter]("__iter__")
            .def_method[FastqBatchIterator.py_next]("__next__")
        )
        return mb.finalize()
    except e:
        print(String("error creating blazeseq_parser module: ") + String(e))
        abort()
