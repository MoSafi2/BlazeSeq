# BlazeSeq

[![Mojo-0.26.2](https://img.shields.io/badge/Mojo-0.26.2-orange?logo=mojo)](https://www.modular.com/mojo)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

High-performance bioinformatics IO for Mojo — SIMD-accelerated parsers for FASTQ, FASTA, FAI, BED, GFF3, and GTF.

BlazeSeq provides streaming parsers for the most common bioinformatics file formats, built to extract maximum throughput from modern hardware. Parsers are parameterized at compile time, so unused validation logic is eliminated entirely by the compiler rather than gated by runtime branches. The unified I/O layer handles plain files, in-memory buffers, single-threaded gzip (`GZFile`), and parallel gzip decoding (`RapidgzipReader`) behind a common `Reader` trait — you swap the reader type parameter and nothing else changes.

---

## Format Support

| Format | Parser | Views | Records | Batches | Validation options |
|--------|--------|:-----:|:-------:|:-------:|-------------------|
| FASTQ | `FastqParser` | ✓ | ✓ | ✓ (SoA) | ASCII, quality schema |
| FASTA | `FastaParser` | — | ✓ | — | ASCII |
| FAI | `FaiParser` | ✓ | ✓ | — | — |
| BED | `BedParser` | ✓ | ✓ | — | Column count (BED3–BED12, BED10/11 rejected) |
| GFF3 | `Gff3Parser` | ✓ | ✓ | — | — |
| GTF | `GtfParser` | ✓ | ✓ | — | — |

---

## Installation

### Mojo (via pixi)

Add BlazeSeq to your `pixi.toml`:

```toml
[dependencies]
blazeseq = { git = "https://github.com/MoSafi2/BlazeSeq", branch = "main" }
```

**Platforms:** linux-64, osx-arm64, linux-aarch64
**Requires:** Mojo 0.26.2, [pixi](https://pixi.sh)

### Python (via pip)

```bash
pip install blazeseq
# or
uv pip install blazeseq
```

> **Note:** The Python package exposes the FASTQ parser only. GFF3, GTF, FASTA, FAI, and BED are Mojo-only.

---

## Core Concept: Three Access Modes

FASTQ supports three ways to consume records. Most other parsers support the first two.

| API | Return type | Copies data? | Best for |
|-----|-------------|:------------:|----------|
| `next_view()` / `views()` | Zero-copy view | No | Streaming transforms, immediate consumption |
| `next_record()` / `records()` | Owned record | Yes | General use, storing records in collections |
| `next_batch()` / `batches()` | SoA batch | Yes | GPU / parallel compute pipelines |

**Lifetime caveat for views:** A `FastqView` (or any `*View` type) borrows directly from the parser's internal buffer. It is invalidated the moment the parser advances. Do not store views across loop iterations without copying the data first — use `records()` if you need owned values.

---

## Usage Examples

### FASTQ

#### Owned records

```mojo
from blazeseq import FastqParser, FileReader
from std.pathlib import Path

def main() raises:
    var parser = FastqParser[FileReader](FileReader(Path("data.fastq")), "generic")
    for record in parser.records():
        print(record.id(), record.sequence())
```

#### Zero-copy views (maximum throughput)

Views avoid all heap allocation inside the loop. Disable validation when the input is trusted.

```mojo
from blazeseq import FastqParser, FileReader
from blazeseq.fastq.parser import ParserConfig
from std.pathlib import Path

def main() raises:
    var parser = FastqParser[
        FileReader,
        ParserConfig(check_ascii=False, check_quality=False),
    ](FileReader(Path("data.fastq")))
    for view in parser.views():
        print(view.id(), len(view.sequence()))
```

#### Gzip — single-threaded (GZFile)

`GZFile` is a simple drop-in for plain files when parallel decoding is not needed or not available.

```mojo
from blazeseq import FastqParser, GZFile

def main() raises:
    var parser = FastqParser[GZFile](GZFile("data.fastq.gz", "rb"), "generic")
    for record in parser.records():
        print(record.id())
```

#### Gzip — parallel decoding (RapidgzipReader)

`RapidgzipReader` uses multiple threads to decompress; `parallelism=0` lets the library choose automatically.

```mojo
from blazeseq import FastqParser, RapidgzipReader
from std.pathlib import Path

def main() raises:
    var reader = RapidgzipReader(Path("data.fastq.gz"), parallelism=0)
    var parser = FastqParser[RapidgzipReader](reader^, "generic")
    for record in parser.records():
        print(record.id())
```

> **Platform note:** `RapidgzipReader` is available on linux-64 and osx-arm64 only. Use `GZFile` on linux-aarch64.

#### GPU batches (FastqBatch)

`FastqBatch` stores records in Structure-of-Arrays layout ready for GPU upload.

```mojo
from blazeseq import FastqParser, FileReader
from blazeseq.fastq.record_batch import upload_batch_to_device
from std.pathlib import Path

def main() raises:
    var parser = FastqParser[FileReader](FileReader(Path("data.fastq")), "generic")
    for batch in parser.batches():
        var device_batch = upload_batch_to_device(batch)
        # pass device_batch to your GPU kernel
```

For a complete end-to-end GPU example (Needleman–Wunsch alignment), see [`examples/nw_gpu/`](examples/nw_gpu/).

---

### FASTA

Multi-line sequences are normalized automatically — the full sequence is concatenated before the record is returned.

```mojo
from blazeseq import FastaParser, FileReader
from std.pathlib import Path

def main() raises:
    # Iterator form
    var parser = FastaParser[FileReader](FileReader(Path("seqs.fa")))
    for rec in parser:
        print(rec.id(), len(rec.sequence()))
```

Direct call form (useful when you need finer control over the loop):

```mojo
def main() raises:
    var parser = FastaParser[FileReader](FileReader(Path("seqs.fa")))
    while True:
        try:
            var rec = parser.next_record()
            print(rec.id(), len(rec.sequence()))
        except EOFError:
            break
```

---

### FAI (FASTA/FASTQ Index)

FAI records provide random-access coordinate metadata for indexed FASTA/FASTQ files. Both FASTA (5-column) and FASTQ (6-column, with `qualoffset`) index files are supported.

```mojo
from blazeseq import FaiParser, FileReader
from std.pathlib import Path

def main() raises:
    var parser = FaiParser[FileReader](FileReader(Path("genome.fa.fai")))
    for view in parser.views():
        print(view.name(), view.length, view.offset)
```

Use `records()` for owned copies:

```mojo
def main() raises:
    var parser = FaiParser[FileReader](FileReader(Path("genome.fa.fai")))
    for rec in parser.records():
        print(rec.name(), rec.length, rec.offset)
```

---

### BED

BED3 through BED12 are supported. BED10 and BED11 column counts are rejected per the UCSC spec. All fields beyond column 3 are optional and parsed lazily.

```mojo
from blazeseq import BedParser, FileReader
from std.pathlib import Path

def main() raises:
    var parser = BedParser[FileReader](FileReader(Path("regions.bed")))
    for view in parser.views():
        print(view.chrom(), view.chromStart, view.chromEnd)
```

For BED records with optional fields (strand, name, score, etc.):

```mojo
def main() raises:
    var parser = BedParser[FileReader](FileReader(Path("regions.bed")))
    for rec in parser.records():
        print(rec.chrom(), rec.chromStart, rec.chromEnd, rec.name())
```

---

### GFF3

`Gff3Parser` handles the nine standard tab-delimited columns. Coordinates are 1-based and inclusive (as per spec). The parser skips `#` comment lines, processes `##gff-version` and `##sequence-region` directives, and stops at the `##FASTA` section if one is present. `SequenceRegion` and `TargetAttribute` are exported for working with those directive types.

```mojo
from blazeseq import Gff3Parser, FileReader
from std.pathlib import Path

def main() raises:
    var parser = Gff3Parser[FileReader](FileReader(Path("annot.gff3")))
    for feature in parser.records():
        print(
            feature.seqid(),
            feature.feature_type(),
            feature.Start,
            feature.End,
        )
```

Accessing optional fields:

```mojo
def main() raises:
    var parser = Gff3Parser[FileReader](FileReader(Path("annot.gff3")))
    for feature in parser.records():
        var gene_id = feature.get_attribute("ID")
        if gene_id:
            print(feature.seqid(), gene_id.value().to_string())
```

GFF3 attribute values may be percent-encoded (e.g. `%3B` for `;`). Use `percent_decode` on the raw attribute value when you need the decoded form.

---

### GTF

`GtfParser` handles GTF 2.2 format. Coordinates are 1-based inclusive. Attribute values are quoted strings (`tag "value";`). The mandatory `gene_id` and `transcript_id` attributes are accessible directly on `GtfAttributes`; all other attributes are accessible via `get_attribute()`.

```mojo
from blazeseq import GtfParser, FileReader
from std.pathlib import Path

def main() raises:
    var parser = GtfParser[FileReader](FileReader(Path("annot.gtf")))
    for feature in parser.records():
        print(
            feature.seqid(),
            feature.feature_type(),
            feature.Start,
            feature.End,
        )
```

Accessing standard and custom attributes:

```mojo
def main() raises:
    var parser = GtfParser[FileReader](FileReader(Path("annot.gtf")))
    for feature in parser.records():
        var gene_id = feature.Attributes.gene_id.to_string()
        var transcript_id = feature.Attributes.transcript_id.to_string()
        var custom = feature.get_attribute("Kraken_mapped")
        if custom:
            print(gene_id, transcript_id, custom.value().to_string())
```

---

## Reader and Writer Types

All parsers accept any type that satisfies the `Reader` trait. All writers satisfy the `WriterBackend` trait. Swap the type parameter to change the I/O backend — the parser code is identical.

### Readers

| Type | Description | Platforms |
|------|-------------|-----------|
| `FileReader` | Standard buffered file reader | all |
| `MemoryReader` | Reads from an in-memory buffer, `List[Byte]`, or `String` | all |
| `GZFile` | Single-threaded gzip decompression | all |
| `RapidgzipReader` | Multi-threaded gzip via rapidgzip; `parallelism=0` auto-selects thread count | linux-64, osx-arm64 |

`FileReader`, `GZFile`, and `RapidgzipReader` are exported from the top-level `blazeseq` module. `MemoryReader` is available from `blazeseq.io`.

### Writers

| Type | Description |
|------|-------------|
| `FileWriter` | Buffered file output |
| `MemoryWriter` | Writes to an in-memory buffer; retrieve with `.get_data()` |
| `GZWriter` | Gzip-compressed file output |

Writers are used with the record's `write_to` method (available on `FastqRecord`, `FastaRecord`, etc.) and are available from `blazeseq.io`.

---

## Compile-Time Configuration

Parsers are parameterized by a `ParserConfig` struct that is evaluated at compile time. This means validation logic is emitted or omitted by the compiler — there is no runtime branch around it.

### FASTQ ParserConfig

```mojo
from blazeseq.fastq.parser import ParserConfig

# All fields with their defaults:
alias cfg = ParserConfig(
    buffer_capacity       = DEFAULT_CAPACITY,   # initial buffer size
    buffer_max_capacity   = MAX_CAPACITY,        # cap on dynamic growth
    buffer_growth_enabled = False,               # allow buffer to grow beyond capacity
    check_ascii           = False,               # validate that all bytes are printable ASCII
    check_quality         = False,               # validate quality bytes against a schema
    quality_schema        = None,                # schema name; required when check_quality=True
)
```

**Quality schemas:** `"generic"`, `"sanger"`, `"solexa"`, `"illumina_1.3"`, `"illumina_1.5"`, `"illumina_1.8"`

Example — enable ASCII and Sanger quality validation:

```mojo
from blazeseq import FastqParser, FileReader
from blazeseq.fastq.parser import ParserConfig
from std.pathlib import Path

alias ValidatingConfig = ParserConfig(
    check_ascii    = True,
    check_quality  = True,
    quality_schema = "sanger",
)

def main() raises:
    var parser = FastqParser[FileReader, ValidatingConfig](
        FileReader(Path("data.fastq"))
    )
    for record in parser.records():
        print(record.id())
```

### FASTA ParserConfig

```mojo
from blazeseq.fasta.parser import ParserConfig

alias cfg = ParserConfig(
    check_ascii = False,   # validate that sequence bytes are printable ASCII
)
```

---

## Python Bindings

The Python package exposes the FASTQ parser as a thin wrapper around the native Mojo implementation.

```bash
pip install blazeseq
```

> The Python package exposes **FASTQ only**. GFF3, GTF, FASTA, FAI, and BED are Mojo-only.

### Basic iteration

```python
from blazeseq import parser

p = parser("data.fastq")
for record in p:
    print(record.id, record.seq)
```

### Gzip with parallel decoding

```python
from blazeseq import parser

p = parser("data.fastq.gz", parallelism=4)
for record in p:
    print(record.id)
```

### Key Python types

| Type | Key attributes / methods |
|------|--------------------------|
| `parser` | Iterable; `__iter__` yields `FastqRecord` |
| `FastqRecord` | `.id`, `.seq`, `.qual`, `.phred_scores(offset=33)` |
| `FastqBatch` | SoA layout; `.ids`, `.seqs`, `.quals` |

See [`python/README.md`](python/README.md) for the full Python API reference and local development instructions.

---

## Testing

```bash
pixi run test
```

The test suite covers all six parsers:

- **FASTQ** — ~140 files from the BioPython, BioJava, and BioPerl test corpora, covering valid and malformed inputs; round-trip write + parse tests.
- **FASTA** — valid and malformed files; round-trip write + parse tests.
- **FAI** — FASTA index (5-column) and FASTQ index (6-column) files.
- **BED** — BED3 through BED9 and BED12; invalid column counts.
- **GFF3** — AGAT fixture suite (48+ files from the AGAT project's test corpus); correctness tests against field values.
- **GTF** — AGAT fixture suite; attribute parsing including pipes and custom tags.
- **IO layer** — buffered reader/writer, line iterator, delimited reader, gzip readers.
- **Python bindings** — basic iteration and batch collection.

---

## Known Limitations

- FASTQ assumes the standard four-line record format. Multi-line FASTQ is not supported.
- No paired-end specific API — process two files in parallel manually if needed.
- Parsers are stream-oriented. Random-access into a file requires the FAI index format combined with a separate seek mechanism.
- `RapidgzipReader` requires the optional `rapidgzip-mojo` dependency and is available on linux-64 and osx-arm64 only. Use `GZFile` on linux-aarch64.
- GFF3 attribute values are parsed lazily — the raw attribute span is not automatically split into key-value pairs at parse time. Access individual attributes via `get_attribute("key")`.
- The Python package exposes the FASTQ parser only.

---

## Resources

- **API docs:** [mosafi2.github.io/BlazeSeq](https://mosafi2.github.io/BlazeSeq)
- **Examples:** [`examples/`](examples/) — `example_parser.mojo`, `biofast_example.mojo`, `nw_gpu/` (GPU alignment)
- **Benchmarks:** [`benchmark/README.md`](benchmark/README.md) — reproducible scripts for all benchmark workloads
- **Changelog:** [`CHANGELOG.md`](CHANGELOG.md)

---

## Acknowledgements

Parser design inspired by [needletail](https://github.com/onecodex/needletail).

Licensed under the [MIT License](LICENSE).
