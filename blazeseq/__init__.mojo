"""BlazeSeq: Fast FASTQ parsing and GPU batch types for Mojo.

BlazeSeq provides high-performance FASTQ parsing with configurable validation
and optional GPU-oriented batch types. It supports multiple parsing modes:
zero-copy references (`RefRecord`), owned records (`FastqRecord`), and
Structure-of-Arrays batches (`FastqBatch`) for GPU upload.

Key features:
- High-throughput parsing (targets several GB/s from disk).
- Configurable validation: ASCII and quality-schema checks (can be disabled for speed).
- Zero-copy parsing via `next_ref()` / `ref_records()`.
- GPU batch support: `FastqBatch`, `DeviceFastqBatch`, `upload_batch_to_device()`.
- Multiple quality schemas: generic, sanger, solexa, illumina_1.3/1.5/1.8.
- Readers: `FileReader`, `MemoryReader`, `GZFile`, `RapidgzipReader`. Writers: `FileWriter`, `MemoryWriter`, `GZWriter`.

Example:
    ```mojo
    from blazeseq import FastqParser, FileReader
    from pathlib import Path

    var parser = FastqParser[FileReader](FileReader(Path("data.fastq")), "generic")
    for record in parser.records():
        print(record.id_slice())
    ```
"""

from blazeseq.record import FastqRecord, RefRecord, Validator
from blazeseq.parser import FastqParser, ParserConfig
from blazeseq.device_record import (
    FastqBatch,
    upload_batch_to_device,
)
from blazeseq.io.readers import FileReader, MemoryReader, GZFile, RapidgzipReader
from blazeseq.io.writers import Writer, FileWriter, MemoryWriter, GZWriter
from blazeseq.errors import ParseError, ValidationError
