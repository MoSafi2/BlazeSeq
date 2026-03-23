# 🔥 BlazeSeq

## High-Performance Bioinformatics IO for Mojo - Zero-Copy to GPU

[![Run Mojo tests](https://github.com/MoSafi2/BlazeSeq/actions/workflows/run-tests.yml/badge.svg?branch=main)](https://github.com/MoSafi2/BlazeSeq/actions/workflows/run-tests.yml)
[![Build and deploy docs](https://github.com/MoSafi2/BlazeSeq/actions/workflows/docs.yml/badge.svg)](https://github.com/MoSafi2/BlazeSeq/actions/workflows/docs.yml)
[![Docs](https://img.shields.io/badge/docs-GitHub_Pages-blue)](https://mosafi2.github.io/BlazeSeq/)
[![Mojo](https://img.shields.io/badge/Mojo-0.26.2-fire)](https://docs.modular.com)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

BlazeSeq is a high-throughput parser for biological sequence and interval data in [Mojo](https://docs.modular.com/mojo/). It combines SIMD-accelerated parsing, a unified reader layer, and GPU-ready data layouts to support production pipelines from local files to accelerated kernels.

BlazeSeq currently supports:

- `FASTQ` via `FastqParser` (zero-copy views, owned records, and SoA batches)
- `FASTA` via `FastaParser` (including multi-line sequence normalization)
- `FAI` via `FaiParser` (FASTA/FASTQ index rows)
- `BED` via `BedParser` (genomic interval records)

## Project Goals

- Build one cohesive parsing stack for common genomics formats in Mojo.
- Keep throughput high by default with SIMD and low-allocation APIs.
- Bridge CPU parsing and GPU compute with explicit batch types and upload utilities.
- Offer ergonomic APIs for both exploratory scripting and production workflows.

## Key Features

- **Multi-format parsing**: FASTQ, FASTA, FAI, and BED in a single library (support for others format follows).
- **Unified I/O layer**.
- **Three Unified access modes**:
  - `views()` for zero-copy streaming
  - `records()` for owned records
  - `batches()` for Structure-of-Arrays GPU pipelines
- **GPU-oriented data flow**: `FastqBatch` plus device upload support for accelerated kernels.
- **Parallel gzip decode**: `RapidgzipReader` enables multithreaded `.fastq.gz` ingestion.
- **Compile-time tuning**: Toggle validation checks for speed/safety trade-offs.
- **Python bindings (experimental)**: Wheel package for Python integration.

![Throughput](assets/throughput_gbps.png)

## Quick Start

### Install as a Mojo dependency (Pixi)

Add BlazeSeq to your `pixi.toml`:

```toml
[dependencies]
blazeseq = { git = "https://github.com/MoSafi2/BlazeSeq", branch = "main" }
```

Then install dependencies:

```bash
pixi install
```

### Python bindings (experimental)

Install from PyPI:

```bash
pip install blazeseq
```

or:

```bash
uv pip install blazeseq
```

Python usage details are documented in [python/README.md](python/README.md).

## Usage Examples

### FASTQ: iterate owned records

```mojo
from blazeseq import FastqParser, FileReader
from std.pathlib import Path

def main() raises:
    var parser = FastqParser[FileReader](FileReader(Path("data.fastq")), "sanger")
    var reads = 0
    var bases = 0
    for record in parser.records():
        reads += 1
        bases += len(record)
    print(reads, bases)
```

### FASTQ: maximum speed with validation off

```mojo
from blazeseq import FastqParser, FileReader
from blazeseq.fastq import ParserConfig
from std.pathlib import Path

def main() raises:
    var parser = FastqParser[
        FileReader, ParserConfig(check_ascii=False, check_quality=False)
    ](FileReader(Path("data.fastq")), "generic")
    for view in parser.views():
        _ = len(view)
```

### FASTA: parse multi-line records

```mojo
from blazeseq import FastaParser, FileReader
from std.pathlib import Path

def main() raises:
    var parser = FastaParser[FileReader](FileReader(Path("ref.fa")))
    for record in parser:
        print(record.id(), len(record))
```

### FAI: read FASTA/FASTQ index entries

```mojo
from blazeseq import FaiParser, FileReader
from std.pathlib import Path

def main() raises:
    var parser = FaiParser[FileReader](FileReader(Path("ref.fa.fai")))
    for rec in parser:
        print(rec.name(), rec.length(), rec.offset())
```

### BED: stream genomic intervals

```mojo
from blazeseq import BedParser, FileReader
from std.pathlib import Path

def main() raises:
    var parser = BedParser[FileReader](FileReader(Path("regions.bed")))
    for interval in parser.views():
        print(interval.chrom(), interval.chrom_start, interval.chrom_end)
```

### Gzip FASTQ with parallel decoding

```mojo
from blazeseq import FastqParser, RapidgzipReader
from std.pathlib import Path

def main() raises:
    var reader = RapidgzipReader(Path("data.fastq.gz"), parallelism=4)
    var parser = FastqParser[RapidgzipReader](reader^, "illumina_1.8")
    for record in parser.records():
        _ = record.id()
```

### GPU alignment example

Run the end-to-end GPU Needleman-Wunsch example:

```bash
pixi run mojo run examples/nw_gpu/main.mojo
```

## FASTQ Access Modes and Trade-offs

| API | Return Type | Copies Data? | Best For |
| --- | --- | --- | --- |
| `next_view()` / `views()` | `FastqView` | No | Streaming transforms and filtering where data is consumed immediately |
| `next_record()` / `records()` | `FastqRecord` | Yes | General scripting and in-memory storage |
| `next_batch()` / `batches()` | `FastqBatch` | Yes | GPU and parallel batch compute |

Important: `FastqView` spans are valid only until parser state advances to the next operation.

## Benchmarks

See [benchmark/README.md](benchmark/README.md) for benchmark commands and comparisons against other sequence parsers.

## Documentation

- API docs: [https://mosafi2.github.io/BlazeSeq/](https://mosafi2.github.io/BlazeSeq/)
- Examples: [examples/](examples/)
- Benchmark scripts: [benchmark/](benchmark/)

## Limitations

- FASTQ parser expects standard four-line records (multi-line FASTQ is not supported).
- Paired-end specific APIs are not yet implemented.
- Parsers are stream-oriented; random seek/index-aware scanning is limited to indexed formats.
- Python package is currently wheel-only.

## Testing

Run all Mojo tests:

```bash
pixi run test
```

The test corpus includes valid and invalid edge cases across FASTQ, FASTA, FAI, BED, and I/O layers derived from the [Biopython](https://biopython.org/) project.

## Project History

BlazeSeq began as a rewrite of MojoFastTrim and has since expanded into a broader parsing and compute-ready genomics toolkit with a unified architecture.

## Acknowledgements

The FASTQ parser design is inspired by [needletail](https://github.com/onecodex/needletail), adapted and optimized for Mojo's SIMD-oriented programming model.

## License

This project is licensed under the MIT License.
