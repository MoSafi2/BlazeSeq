"""
Python bindings for BlazeSeq FASTQ parser.

Exposes create_parser, has_more, next_record, next_ref_as_record, next_batch,
and type bindings for FastqRecord and FastqBatch. Use from Python with:

  import mojo.importer
  import blazeseq_parser
  parser = blazeseq_parser.create_parser("file.fastq", "sanger")
  while blazeseq_parser.has_more(parser):
      rec = blazeseq_parser.next_record(parser)
      ...
"""

from python import PythonObject, Python
from python.bindings import PythonModuleBuilder
from pathlib import Path
from os import abort
from blazeseq.parser import FastqParser, ParserConfig
from blazeseq.record import FastqRecord, RefRecord
from blazeseq import FastqBatch
from blazeseq.io.readers import FileReader
from blazeseq.io.buffered import EOFError
from blazeseq.CONSTS import EOF

# Concrete parser type for Python (FileReader + default ParserConfig).
comptime PyFastqParser = FastqParser[FileReader, ParserConfig()]

# Holder for the parser so we can register it with add_type (FastqParser does not implement Representable).
struct BlazeSeqParserHolder(Representable, Movable):
    var parser: PyFastqParser

    fn __init__(out self, var parser: PyFastqParser):
        self.parser = parser^

    fn __repr__(self) -> String:
        return "BlazeSeqParser(...)"


# ---------------------------------------------------------------------------
# Module-level parser functions
# ---------------------------------------------------------------------------


fn create_parser(path: PythonObject, quality_schema: PythonObject) raises -> PythonObject:
    """Create a FASTQ parser for the given file path and quality schema.

    Args:
        path: File path as string (e.g. "data.fastq").
        quality_schema: Schema name: "generic", "sanger", "solexa", "illumina_1.3", "illumina_1.5", "illumina_1.8".

    Returns:
        Parser handle to pass to has_more, next_record, next_batch.
    """
    var path_str = String(path)
    var schema_str = String(quality_schema)
    var reader = FileReader(Path(path_str))
    var parser = PyFastqParser(reader^, schema_str)
    var holder = BlazeSeqParserHolder(parser^)
    return PythonObject(alloc=holder^)


fn has_more(parser_py: PythonObject) raises -> PythonObject:
    """Return True if there may be more records to read."""
    var holder_ptr = parser_py.downcast_value_ptr[BlazeSeqParserHolder]()
    return PythonObject(holder_ptr[].parser.has_more())


fn next_record(parser_py: PythonObject) raises -> PythonObject:
    """Return the next record as an owned FastqRecord. Raises on EOF or parse error."""
    var holder_ptr = parser_py.downcast_value_ptr[BlazeSeqParserHolder]()
    try:
        var record = holder_ptr[].parser.next_record()
        return PythonObject(alloc=record^)
    except e:
        if String(e) == EOF or String(e).startswith(EOF):
            raise Error("EOF")
        raise e^


fn next_ref_as_record(parser_py: PythonObject) raises -> PythonObject:
    """Return the next record as an owned FastqRecord (from zero-copy ref). Raises on EOF or parse error."""
    var holder_ptr = parser_py.downcast_value_ptr[BlazeSeqParserHolder]()
    try:
        var ref_rec = holder_ptr[].parser.next_ref()
        var record = FastqRecord(
            ref_rec.id,
            ref_rec.sequence,
            ref_rec.quality,
            Int8(holder_ptr[].parser.quality_schema.OFFSET),
        )
        return PythonObject(alloc=record^)
    except e:
        if String(e) == EOF or String(e).startswith(EOF):
            raise Error("EOF")
        raise e^


fn next_batch(parser_py: PythonObject, max_records: PythonObject) raises -> PythonObject:
    """Return a batch of up to max_records records as FastqBatch. Returns partial batch at EOF."""
    var holder_ptr = parser_py.downcast_value_ptr[BlazeSeqParserHolder]()
    var limit = Int(py=max_records)
    var batch = holder_ptr[].parser.next_batch(limit)
    return PythonObject(alloc=batch^)


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
    fn get_record_at(py_self: PythonObject, index: PythonObject) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[FastqBatch]()
        var idx = Int(py=index)
        var record = self_ptr[].get_record(idx)
        return PythonObject(alloc=record^)


# ---------------------------------------------------------------------------
# PyInit
# ---------------------------------------------------------------------------


@export
fn PyInit_blazeseq_parser() -> PythonObject:
    try:
        var mb = PythonModuleBuilder("blazeseq_parser")
        # Module-level functions
        mb.def_function[create_parser]("create_parser", docstring="Create a FASTQ parser for the given path and quality schema.")
        mb.def_function[has_more]("has_more", docstring="Return True if there may be more records to read.")
        mb.def_function[next_record]("next_record", docstring="Return the next record as an owned FastqRecord. Raises on EOF or parse error.")
        mb.def_function[next_ref_as_record]("next_ref_as_record", docstring="Return the next record (from zero-copy ref) as owned FastqRecord. Raises on EOF or parse error.")
        mb.def_function[next_batch]("next_batch", docstring="Return a batch of up to max_records records as FastqBatch.")
        # Types (order: register parser holder first so create_parser return value works, then record and batch)
        _ = mb.add_type[BlazeSeqParserHolder]("FastqParser")
        _ = (
            mb.add_type[FastqRecord]("FastqRecord")
            .def_method[FastqRecordMethods.get_id]("id", docstring="Read identifier (without leading '@').")
            .def_method[FastqRecordMethods.get_sequence]("sequence", docstring="Sequence line.")
            .def_method[FastqRecordMethods.get_quality]("quality", docstring="Quality line.")
            .def_method[FastqRecordMethods.get_len]("__len__", docstring="Sequence length (number of bases).")
            .def_method[FastqRecordMethods.get_phred_scores]("phred_scores", docstring="Phred quality scores as a Python list.")
        )
        _ = (
            mb.add_type[FastqBatch]("FastqBatch")
            .def_method[FastqBatchMethods.get_num_records]("num_records", docstring="Number of records in the batch.")
            .def_method[FastqBatchMethods.get_record_at]("get_record", docstring="Return the record at the given index as FastqRecord.")
        )
        return mb.finalize()
    except e:
        print(String("error creating blazeseq_parser module: ") + String(e))
        abort()
