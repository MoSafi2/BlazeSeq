"""
Python bindings for BlazeSeq FASTQ parser.

Exposes parser (returns a FastqParser) and type bindings for FastqRecord
and FastqBatch. Parser methods: has_more(), next_record(), next_ref_as_record(),
next_batch(max_records). Supports plain (.fastq, .fq) and gzip (.fastq.gz, .fq.gz).
Use from Python with:

  import blazeseq
  parser = blazeseq.parser("file.fastq", "sanger")
  # or for gzip: blazeseq.parser("file.fastq.gz", "sanger", parallelism=4)
  while parser.has_more():
      rec = parser.next_record()
      ...
"""

from std.python import PythonObject, Python
from std.python.bindings import PythonModuleBuilder
from std.pathlib import Path
from std.os import abort
from std.memory import UnsafePointer, alloc
from std.collections.string import StringSlice
from blazeseq.fastq.parser import FastqParser, ParserConfig
from blazeseq.fastq.record import FastqRecord, FastqView
from blazeseq.fastq.record_batch import FastqBatch
from blazeseq.io.readers import FileReader, RapidgzipReader
from blazeseq.io.writers import Writer
from blazeseq.io.buffered import EOFError
from blazeseq.CONSTS import EOF

# Concrete parser type for Python (FileReader + default ParserConfig).
comptime PyFastqParser = FastqParser[FileReader, ParserConfig()]
comptime PyFastqGZParser = FastqParser[RapidgzipReader, ParserConfig()]


# Holder for the parser so we can register it with add_type (FastqParser does not implement Writable).
struct BlazeSeqParserHolder(Movable, Writable):
    var _parser_ptr: UnsafePointer[PyFastqParser, MutAnyOrigin]

    fn __init__(out self, var parser: PyFastqParser):
        var storage = alloc[PyFastqParser](1)
        storage[0] = parser^
        self._parser_ptr = storage

    fn __del__(deinit self):
        self._parser_ptr.destroy_pointee()

    fn __repr__(self) -> String:
        return "BlazeSeqParser(...)"

    fn write_to(self, mut writer: Some[Writer]):
        writer.write("BlazeSeqParser(...)")


# Opaque holder: parser stored behind pointer because FastqParser[RapidgzipReader]
# does not implement Writable (RapidgzipFile from rapidgzip package doesn't).
struct BlazeSeqGZParserHolder(Movable, Writable):
    var _parser_ptr: UnsafePointer[PyFastqGZParser, MutAnyOrigin]

    fn __init__(out self, var parser: PyFastqGZParser):
        var storage = alloc[PyFastqGZParser](1)
        storage[0] = parser^
        self._parser_ptr = storage

    fn __del__(deinit self):
        self._parser_ptr.destroy_pointee()

    fn __repr__(self) -> String:
        return "BlazeSeqParser(...)"

    fn write_to(self, mut writer: Some[Writer]):
        writer.write("BlazeSeqParser(...)")


# ---------------------------------------------------------------------------
# parser (module-level) and parser method wrappers
# ---------------------------------------------------------------------------


fn parser(
    path: PythonObject, quality_schema: PythonObject, parallelism: PythonObject
) raises -> PythonObject:
    """Create a FASTQ parser for the given file path and quality schema.

    Args:
        path: File path as string (e.g. "data.fastq" or "data.fastq.gz").
        quality_schema: Schema name: "generic", "sanger", "solexa", "illumina_1.3", "illumina_1.5", "illumina_1.8".
        parallelism: Number of threads for gzip decompression (only for .fastq.gz / .fq.gz); 0 = auto-detect. Used for all reads (init and iteration).

    Returns:
        Parser handle to pass to has_more, next_record, next_batch.
    """
    var path_str = String(path)
    var schema_str = String(quality_schema)
    # Convert parallelism; RapidgzipReader expects UInt32. 0 = auto-detect. Clamp negative to 0.
    var par_int = Int(py=parallelism)
    var par = UInt32(0)
    if par_int > 0:
        par = UInt32(par_int)
    if path_str.endswith(".fastq.gz") or path_str.endswith(".fq.gz"):
        # Reader uses this parallelism for all decompression (every next_record/next_batch).
        var reader = RapidgzipReader(path_str, parallelism=par)
        var p = PyFastqGZParser(reader^, schema_str)
        var holder = BlazeSeqGZParserHolder(p^)
        return PythonObject(alloc=holder^)
    elif path_str.endswith(".fastq") or path_str.endswith(".fq"):
        var reader = FileReader(Path(path_str))
        var p = PyFastqParser(reader^, schema_str)
        var holder = BlazeSeqParserHolder(p^)
        return PythonObject(alloc=holder^)
    else:
        raise Error(
            "Unsupported file extension. Use .fastq, .fq, .fastq.gz, or .fq.gz"
        )


# Method wrappers for plain-file parser (BlazeSeqParserHolder).
struct ParserMethodsPlain:
    @staticmethod
    fn has_more(py_self: PythonObject) raises -> PythonObject:
        var holder_ptr = py_self.downcast_value_ptr[BlazeSeqParserHolder]()
        return PythonObject(holder_ptr[]._parser_ptr[].has_more())

    @staticmethod
    fn next_record(py_self: PythonObject) raises -> PythonObject:
        var holder_ptr = py_self.downcast_value_ptr[BlazeSeqParserHolder]()
        try:
            var record = holder_ptr[]._parser_ptr[].next_record()
            return PythonObject(alloc=record^)
        except e:
            if String(e) == EOF or String(e).startswith(EOF):
                raise Error("EOF")
            raise e^

    @staticmethod
    fn next_ref_as_record(py_self: PythonObject) raises -> PythonObject:
        var holder_ptr = py_self.downcast_value_ptr[BlazeSeqParserHolder]()
        try:
            var view = holder_ptr[]._parser_ptr[].next_view()
            var record = FastqRecord(
                view._id,
                view._sequence,
                view._quality,
                Int8(holder_ptr[]._parser_ptr[].quality_schema.OFFSET),
            )
            return PythonObject(alloc=record^)
        except e:
            if String(e) == EOF or String(e).startswith(EOF):
                raise Error("EOF")
            raise e^

    @staticmethod
    fn next_batch(
        py_self: PythonObject, max_records: PythonObject
    ) raises -> PythonObject:
        var holder_ptr = py_self.downcast_value_ptr[BlazeSeqParserHolder]()
        var batch = holder_ptr[]._parser_ptr[].next_batch(Int(py=max_records))
        return PythonObject(alloc=batch^)

    @staticmethod
    fn parser_py_iter(py_self: PythonObject) raises -> PythonObject:
        return py_self

    @staticmethod
    fn parser_py_next(py_self: PythonObject) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[BlazeSeqParserHolder]()
        if not self_ptr[]._parser_ptr[].has_more():
            raise Error("StopIteration")
        try:
            var record = self_ptr[]._parser_ptr[].next_record()
            return PythonObject(alloc=record^)
        except e:
            if String(e) == EOF or String(e).startswith(EOF):
                raise Error("StopIteration")
            raise e^


# Method wrappers for gzip parser (BlazeSeqGZParserHolder).
struct ParserMethodsGz:
    @staticmethod
    fn has_more(py_self: PythonObject) raises -> PythonObject:
        var holder_ptr = py_self.downcast_value_ptr[BlazeSeqGZParserHolder]()
        return PythonObject(holder_ptr[]._parser_ptr[].has_more())

    @staticmethod
    fn next_record(py_self: PythonObject) raises -> PythonObject:
        var holder_ptr = py_self.downcast_value_ptr[BlazeSeqGZParserHolder]()
        try:
            var record = holder_ptr[]._parser_ptr[].next_record()
            return PythonObject(alloc=record^)
        except e:
            if String(e) == EOF or String(e).startswith(EOF):
                raise Error("EOF")
            raise e^

    @staticmethod
    fn next_ref_as_record(py_self: PythonObject) raises -> PythonObject:
        var holder_ptr = py_self.downcast_value_ptr[BlazeSeqGZParserHolder]()
        try:
            var view = holder_ptr[]._parser_ptr[].next_view()
            var record = FastqRecord(
                view._id,
                view._sequence,
                view._quality,
                Int8(holder_ptr[]._parser_ptr[].quality_schema.OFFSET),
            )
            return PythonObject(alloc=record^)
        except e:
            if String(e) == EOF or String(e).startswith(EOF):
                raise Error("EOF")
            raise e^

    @staticmethod
    fn next_batch(
        py_self: PythonObject, max_records: PythonObject
    ) raises -> PythonObject:
        var holder_ptr = py_self.downcast_value_ptr[BlazeSeqGZParserHolder]()
        var batch = holder_ptr[]._parser_ptr[].next_batch(Int(py=max_records))
        return PythonObject(alloc=batch^)

    @staticmethod
    fn parser_py_iter(py_self: PythonObject) raises -> PythonObject:
        return py_self

    @staticmethod
    fn parser_py_next(py_self: PythonObject) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[BlazeSeqGZParserHolder]()
        if not self_ptr[]._parser_ptr[].has_more():
            raise Error("StopIteration")
        try:
            var record = self_ptr[]._parser_ptr[].next_record()
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
        return String(self_ptr[].id())

    @staticmethod
    fn get_sequence(py_self: PythonObject) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[FastqRecord]()
        return String(self_ptr[].sequence())

    @staticmethod
    fn get_quality(py_self: PythonObject) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[FastqRecord]()
        return String(self_ptr[].quality())

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
        """Return an iterator over records in the batch. Iterator is invalid after batch is discarded.
        """
        var batch_ptr = py_self.downcast_value_ptr[FastqBatch]()
        var count = batch_ptr[].num_records()
        var iter_val = FastqBatchIterator(batch_ptr, 0, count)
        return PythonObject(alloc=iter_val^)


# Iterator over FastqBatch records. Holds a pointer to the batch; batch must outlive the iterator.
struct FastqBatchIterator(Movable, Writable):
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
            "FastqBatchIterator(index=", self.index, ", count=", self.count, ")"
        )

    @staticmethod
    fn py_iter(py_self: PythonObject) raises -> PythonObject:
        """Return self as the iterator."""
        return py_self

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
        # Module-level: parser only (parallelism passed at init, used for all reads)
        mb.def_function[parser](
            "parser",
            docstring=(
                "Create a FASTQ parser for the given path and quality"
                " schema.\n\nArgs:\n  path: File path (.fastq, .fq, .fastq.gz,"
                " or .fq.gz).\n  quality_schema: One of 'generic', 'sanger',"
                " 'solexa', 'illumina_1.3', 'illumina_1.5', 'illumina_1.8'.\n "
                " parallelism: Decompression threads for gzip (default 4); 0 ="
                " auto. Used for all reads.\n\nReturns:\n  Parser instance with"
                " has_more(), next_record(), next_batch(max_records), and"
                " iteration."
            ),
        )
        # Types: FastqParser (plain) and FastqGZParser (gzip); same API.
        _ = (
            mb.add_type[BlazeSeqParserHolder]("FastqParser")
            .def_method[ParserMethodsPlain.has_more](
                "has_more",
                docstring="Return True if there may be more records to read.",
            )
            .def_method[ParserMethodsPlain.next_record](
                "next_record",
                docstring=(
                    "Return the next record as a FastqRecord. Raises on EOF or"
                    " parse error."
                ),
            )
            .def_method[ParserMethodsPlain.next_ref_as_record](
                "next_ref_as_record",
                docstring=(
                    "Return the next record (from zero-copy ref) as an owned"
                    " FastqRecord. Raises on EOF or parse error."
                ),
            )
            .def_method[ParserMethodsPlain.next_batch](
                "next_batch",
                docstring=(
                    "Return a batch of up to max_records records as a"
                    " FastqBatch."
                ),
            )
            .def_method[ParserMethodsPlain.parser_py_iter](
                "__iter__",
                docstring=(
                    "Return self as the iterator for 'for rec in parser'."
                ),
            )
            .def_method[ParserMethodsPlain.parser_py_next](
                "__next__",
                docstring=(
                    "Return the next FastqRecord. Raises StopIteration when"
                    " exhausted."
                ),
            )
        )
        _ = (
            mb.add_type[BlazeSeqGZParserHolder]("FastqGZParser")
            .def_method[ParserMethodsGz.has_more](
                "has_more",
                docstring="Return True if there may be more records to read.",
            )
            .def_method[ParserMethodsGz.next_record](
                "next_record",
                docstring=(
                    "Return the next record as a FastqRecord. Raises on EOF or"
                    " parse error."
                ),
            )
            .def_method[ParserMethodsGz.next_ref_as_record](
                "next_ref_as_record",
                docstring=(
                    "Return the next record (from zero-copy ref) as an owned"
                    " FastqRecord. Raises on EOF or parse error."
                ),
            )
            .def_method[ParserMethodsGz.next_batch](
                "next_batch",
                docstring=(
                    "Return a batch of up to max_records records as a"
                    " FastqBatch."
                ),
            )
            .def_method[ParserMethodsGz.parser_py_iter](
                "__iter__",
                docstring=(
                    "Return self as the iterator for 'for rec in parser'."
                ),
            )
            .def_method[ParserMethodsGz.parser_py_next](
                "__next__",
                docstring=(
                    "Return the next FastqRecord. Raises StopIteration when"
                    " exhausted."
                ),
            )
        )
        _ = (
            mb.add_type[FastqRecord]("FastqRecord")
            .def_method[FastqRecordMethods.get_id](
                "id",
                docstring=(
                    "Return the read identifier (without the leading '@')."
                ),
            )
            .def_method[FastqRecordMethods.get_sequence](
                "sequence",
                docstring="Return the sequence line (bases).",
            )
            .def_method[FastqRecordMethods.get_quality](
                "quality",
                docstring="Return the quality line (encoded quality scores).",
            )
            .def_method[FastqRecordMethods.get_len](
                "__len__",
                docstring="Return the sequence length (number of bases).",
            )
            .def_method[FastqRecordMethods.get_phred_scores](
                "phred_scores",
                docstring=(
                    "Return Phred quality scores as a Python list of integers."
                ),
            )
        )
        _ = (
            mb.add_type[FastqBatch]("FastqBatch")
            .def_method[FastqBatchMethods.get_num_records](
                "num_records",
                docstring="Return the number of records in the batch.",
            )
            .def_method[FastqBatchMethods.get_record_at](
                "get_record",
                docstring=(
                    "Return the record at the given index (0-based) as a"
                    " FastqRecord."
                ),
            )
            .def_method[FastqBatchMethods.batch_py_iter](
                "__iter__",
                docstring="Return an iterator over the records in the batch.",
            )
        )
        _ = (
            mb.add_type[FastqBatchIterator]("FastqBatchIterator")
            .def_method[FastqBatchIterator.py_iter](
                "__iter__",
                docstring="Return self as the iterator.",
            )
            .def_method[FastqBatchIterator.py_next](
                "__next__",
                docstring=(
                    "Return the next FastqRecord in the batch. Raises"
                    " StopIteration when exhausted."
                ),
            )
        )
        return mb.finalize()
    except e:
        print(String("error creating blazeseq_parser module: ") + String(e))
        abort()
