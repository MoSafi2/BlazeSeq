# 🔥 BlazeSeq

**High-Performance FASTQ Parsing for Mojo — Zero-Copy to GPU**

[![Run Mojo tests](https://github.com/MoSafi2/BlazeSeq/actions/workflows/run-tests.yml/badge.svg?branch=main)](https://github.com/MoSafi2/BlazeSeq/actions/workflows/run-tests.yml)
[![Build and deploy docs](https://github.com/MoSafi2/BlazeSeq/actions/workflows/docs.yml/badge.svg)](https://github.com/MoSafi2/BlazeSeq/actions/workflows/docs.yml)
[![Docs](https://img.shields.io/badge/docs-GitHub_Pages-blue)](https://mosafi2.github.io/BlazeSeq/)
[![Mojo](https://img.shields.io/badge/Mojo-0.26.1-fire)](https://docs.modular.com)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)

A high-throughput FASTQ parser written in [Mojo](https://docs.modular.com/mojo/). BlazeSeq targets several GB/s throughput from disk using zero-copy parsing (similar to `needletail` and `seq_io`), with additional support for owned records and GPU-friendly batching. It handles gzip input via `zlib` bindings and offers configurable validation — all through a single unified API.

## ✨ Key Features

- **SIMD-accelerated scanning** — Vectorized from the ground up using mojo SIMD first-class support.
- **Three parsing modes** — Choose your trade-off between speed and convenience:
  - `ref_records()` — Zero-copy views (fastest, borrow semantics)
  - `records()` — Owned records (thread-safe)
  - `batched()` — Structure-of-Arrays for GPU upload
- **Compile-time validation toggles** — Enable/Disable ASCII/quality-range checks at compile time for maximum throughput

## Quick Start

### Installation (Pixi)

If you don't have pixi already, install it first:

```sh
curl -fsSL https://pixi.sh/install.sh | sh
```

This will install the `pixi` environment manager (see [pixi documentation](https://prefix.dev/docs/pixi/)). BlazeSeq uses pixi to manage dependencies and compatible Mojo toolchains.

```toml
# In your pixi.toml
[dependencies]
blazeseq = { git = "https://github.com/MoSafi2/BlazeSeq", branch = "main" }
# pixi install
```

### 🛠 Usage examples

```sh
# FastqParser with and without validation
pixi run mojo run examples/example_parser.mojo /path/to/file.fastq

# GPU needleman-wunsch global alignment (requires GPU)
pixi run mojo run examples/nw_gpu/main.mojo
```

### Count reads and base pairs

```mojo
from blazeseq import FastqParser, FileReader
from pathlib import Path

fn main() raises:
    var parser = FastqParser(FileReader(Path("data.fastq")), "sanger")
    var reads = 0
    var bases = 0
    for record in parser.records():
        reads += 1
        bases += len(record)
    print(reads, bases)
```

### Maximum speed (validation off)

```mojo
from blazeseq import FastqParser, ParserConfig, FileReader
from pathlib import Path

fn main() raises:
    comptime config = ParserConfig(check_ascii=False, check_quality=False)
    var parser = FastqParser[config=config](FileReader(Path("data.fastq")), "generic")
    for record in parser.ref_records():   # zero-copy
        _ = len(record)
```

### Batched (for GPU pipelines)

```mojo
from blazeseq import FastqBatch
from gpu.host import DeviceContext

var ctx = DeviceContext()
var parser = FastqParser(FileReader(Path("data.fastq")), schema="generic", batch_size=4096)
for batch in parser.batched():
    # batch is a FastqBatch (Structure-of-Arrays)
    var device_batch = batch.to_device(ctx)   # GPU upload
    # Your GPU kernel, check examples
```

### Reading gzip

```mojo
from blazeseq import GZFile, FastqParser

var parser = FastqParser(GZFile("data.fastq.gz", "rb"), "illumina_1.8")
for record in parser.records():
    _ = record.id_slice()
```

## Architecture & Trade-offs

| Mode                           | Return Type        | Copies Data? | Use When                                                           |
| ------------------------------ | ------------------ | ------------ | ------------------------------------------------------------------ |
| `next_ref()` / `ref_records()` | `RefRecord`        | **No**       | Streaming transforms (QC, filtering) where you process and discard. Not thread-safe |
| `next_record()` / `records()`  | `FastqRecord`      | **Yes**      | Simple scripting, building in-memory collections       |
| `next_batch()` / `batched()`   | `FastqBatch` (SoA) | **Yes**      | GPU pipelines, parallel CPU operations                |

**Critical**: `RefRecord` spans are only valid untill the next parser operation. Do not store them in collections or use after iteration advances.

## Benchmarks

Benchmark numbers are hardware- and Mojo-version-dependent.

### Throughput benchmark

The throughput (`benchmark/throughput_benchmark.mojo`) generates ~3 GB of synthetic FASTQ in memory and times all three parsing modes. Run it yourself:

```bash
pixi run mojo run -I . benchmark/throughput_benchmark.mojo
```

### Comparison with other tools

Generates ~3GB in `ramfs` and compares parsing against `needletail` (Rust), `seq_io` (Rust), `KSeq` (C) and `Fastx.jl` (Julia).
Ensure that you have enough ram capacity (min ~5GB).

```bash
pixi run -e benchmark benchmark
```

## Documentation

- API Reference: [https://mosafi2.github.io/BlazeSeq/](https://mosafi2.github.io/BlazeSeq/)
- The site is generated with [Modo](https://mlange-42.github.io/modo/) (plain markdown from `mojo doc` output) and [Astro Starlight](https://starlight.astro.build/).
- Examples: `examples/` directory includes parser usage, writer, and GPU alignment

## Limitations

- No multi-line FASTQ support — Records must fit four lines (standard Illumina/ONT format)
- No current support for Paired-end reads, or FASTA files (in progress)
- No index/seek — Streaming parser only; use MemoryReader for repeated scans
- Mojo-only — No Python interop (python binding in progress)

## Testing

Run the test suite with pixi:

```bash
pixi run test
```

Tests use the same valid/invalid FASTQ corpus as [BioJava](https://github.com/biojava/biojava/tree/master/biojava-genome%2Fsrc%2Ftest%2Fresources%2Forg%2Fbiojava%2Fnbio%2Fgenome%2Fio%2Ffastq), [Biopython](https://biopython.org/), and [BioPerl](https://bioperl.org/) FASTQ parsers. Multi-line FASTQ is not supported.

## Project History

BlazeSeq is a ground-up rewrite of MojoFastTrim (archived [here](https://github.com/MoSafi2/BlazeSeq/tree/MojoFastTrim)), redesigned for:

- Unified parser architecture (one parser, three modes)
- GPU-oriented batch types
- Compile-time configuration

## License

This project is licensed under the MIT License.
