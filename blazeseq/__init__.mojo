"""BlazeSeq: fast FASTX parsing and GPU batching for Mojo.

BlazeSeq provides high-performance FASTQ parsing with configurable validation
and GPU-oriented batch types. It supports multiple parsing modes:
zero-copy views (`FastqView`), owned records (`FastqRecord`), and
Structure-of-Arrays batches (`FastqBatch`) for GPU upload.

Key features:
- High-throughput parsing (targets several GB/s from disk).
- Configurable validation: ASCII and quality-schema checks (can be disabled for speed).
- Zero-copy parsing via `next_view()` / `views()`.
- CPU and GPU batching with `FastqBatch`, `StagedFastqBatch`, and `DeviceFastqBatch`.
- Multiple quality schemas: generic, sanger, solexa, illumina_1.3/1.5/1.8.
- Readers: `FileReader`, `MemoryReader`, `GZFile`, `RapidgzipReader`. Writers: `FileWriter`, `MemoryWriter`, `GZWriter`.

Exceptions:
- The public API (e.g. `FastqParser.next_view()`, `next_record()`) raises only Mojo `Error` and `EOFError`. Parse and buffer-capacity failures use `Error` with consistent messages; end-of-input uses `EOFError`. Iterators (`records()`, `views()`, `batches()`) catch `EOFError` and raise `StopIteration` instead.

Example:
    ```mojo
    from blazeseq import FastqParser, FileReader
    from std.pathlib import Path

    var parser = FastqParser[FileReader](FileReader(Path("data.fastq")), "generic")
    for record in parser.records():
        print(record.id())
    ```
"""

from blazeseq.fastq.record import FastqRecord, FastqView
from blazeseq.fastq.parser import FastqParser, ParserConfig
from blazeseq.fasta import FastaRecord, FastaParser
from blazeseq.fai import FaiRecord, FaiView, FaiParser
from blazeseq.fastq.record_batch import (
    FastqBatch,
    DeviceFastqBatch,
    StagedFastqBatch,
    upload_batch_to_device,
    stage_batch_to_host,
    move_staged_to_device,
    download_device_batch_to_staged,
)
from blazeseq.bed import (
    BedParser,
    BedRecord,
    BedView,
    BedWriter,
    Strand,
    ItemRgb,
)
from blazeseq.gtf import (
    GtfParser,
    GtfRecord,
    GtfView,
    GtfStrand,
    GtfAttributes,
)
from blazeseq.gff import (
    Gff3Parser,
    Gff3Record,
    Gff3View,
    Gff3Strand,
    Gff3Attributes,
    SequenceRegion,
)

from blazeseq.io import (
    FileReader,
    MemoryReader,
    GZFile,
    RapidgzipReader,
    Reader,
    EOFError,
    LineIteratorError,
    BufferedReader,
    BufferedWriter,
    LineIterator,
    Writer,
    WriterBackend,
    FileWriter,
    MemoryWriter,
    GZWriter,
    DelimitedRecord,
    DelimitedReader,
)
