---
title: Introduction
description: High-performance bioinformatics I/O for Mojo with zero-copy parsing and GPU-ready data flows.
---

## High-Performance Bioinformatics I/O for Mojo

[GitHub](https://github.com/MoSafi2/BlazeSeq) · [API Reference](/api/blazeseq/) · [PyPI](https://pypi.org/project/blazeseq/)

BlazeSeq is a cohesive parsing stack for genomics formats in Mojo. It is designed for the full path from local files to accelerated compute with high throughput, explicit data ownership, and GPU-ready batch layouts.

## Why BlazeSeq

- **One stack, multiple formats**: FASTQ, FASTA, FAI, and BED in one library.
- **Performance by default**: SIMD-oriented parsing and low-allocation APIs.
- **CPU to GPU bridge**: Batch APIs and upload utilities for accelerator workflows.
- **Ergonomic interfaces**: Stream views, owned records, or batch iteration from the same parser.

## Supported Formats

| Format | Parser | Typical use |
| --- | --- | --- |
| `FASTQ` | `FastqParser` | Read sequencing reads with quality scores |
| `FASTA` | `FastaParser` | Reference and assembly sequence parsing |
| `FAI` | `FaiParser` | FASTA/FASTQ index metadata access |
| `BED` | `BedParser` | Genomic interval and region processing |

## Quick Start

Install via [pixi](https://prefix.dev/docs/pixi/) by adding BlazeSeq to your `pixi.toml`:

```toml
[dependencies]
blazeseq = { git = "https://github.com/MoSafi2/BlazeSeq", branch = "main" }
```

Then run `pixi install` and parse FASTQ data:

```mojo
from blazeseq import FastqParser, FileReader
from std.pathlib import Path

def main() raises:
    var parser = FastqParser[FileReader](FileReader(Path("reads.fastq")), "sanger")
    for view in parser.views():
        _ = view.id()
        _ = len(view)
```

## Parser Workflows

### FASTA

```mojo
from blazeseq import FastaParser, FileReader
from std.pathlib import Path

def main() raises:
    var parser = FastaParser[FileReader](FileReader(Path("ref.fa")))
    for record in parser:
        print(record.id(), len(record))
```

### FAI

```mojo
from blazeseq import FaiParser, FileReader
from std.pathlib import Path

def main() raises:
    var parser = FaiParser[FileReader](FileReader(Path("ref.fa.fai")))
    for rec in parser:
        print(rec.name(), rec.length(), rec.offset())
```

### BED

```mojo
from blazeseq import BedParser, FileReader
from std.pathlib import Path

def main() raises:
    var parser = BedParser[FileReader](FileReader(Path("regions.bed")))
    for interval in parser.views():
        print(interval.chrom(), interval.chrom_start, interval.chrom_end)
```

## GPU Pipeline Example

```mojo
from blazeseq import FastqParser, RapidgzipReader
from std.pathlib import Path

def main() raises:
    var reader = RapidgzipReader(Path("reads.fastq.gz"), parallelism=4)
    var parser = FastqParser[RapidgzipReader](reader^, "illumina_1.8")
    for batch in parser.batches(1024):
        var device_batch = batch.to_device()
        _ = device_batch
```

## Next Steps

- Explore the complete [API Reference](/api/blazeseq/).
- Run end-to-end examples in [`examples/`](https://github.com/MoSafi2/BlazeSeq/tree/main/examples).
- Review benchmark tooling in [`benchmark/`](https://github.com/MoSafi2/BlazeSeq/tree/main/benchmark).
