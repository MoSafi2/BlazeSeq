"""BlazeSeq: Fast FASTQ parsing and GPU batch types for Mojo.

BlazeSeq provides high-performance FASTQ parsing with configurable validation
and optional GPU-oriented batch types. It supports multiple parsing modes:
zero-copy views (`FastqView`), owned records (`FastqRecord`), and
Structure-of-Arrays batches (`FastqBatch`) for GPU upload.

Key features:
- High-throughput parsing (targets several GB/s from disk).
- Configurable validation: ASCII and quality-schema checks (can be disabled for speed).
- Zero-copy parsing via `next_view()` / `views()`.
- GPU batch support: `FastqBatch`, `DeviceFastqBatch`, `upload_batch_to_device()`.
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
from blazeseq.fastq.parser import FastqParser
from blazeseq.fasta import FastaRecord, FastaParser
from blazeseq.fai import FaiRecord, FaiView, FaiParser
from blazeseq.bed import (
    BedRecord,
    BedView,
    BedParser,
)
from blazeseq.gff import (
    Gff3Record,
    Gff3View,
    Gff3Strand,
    Gff3Attributes,
    Gff3Parser,
    SequenceRegion,
    TargetAttribute,
    parse_target_attribute,
)
from blazeseq.gtf import (GtfRecord, GtfView, GtfStrand, GtfAttributes, GtfParser)
from blazeseq.fastq.record_batch import FastqBatch, upload_batch_to_device

from blazeseq.io import (
    FileReader,
    GZFile,
    RapidgzipReader,
)
