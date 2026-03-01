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

BlazeSeq can be used as a **Python package** (from PyPI), as a **Mojo package** (from PyPI, using the pre-built `.mojopkg`), or as a **Mojo package** (from the repo via Pixi). Choose one depending on your workflow.

### Option 1: Python package (PyPI)

Install the Python bindings from PyPI. Only pre-built wheels are published; the extension is not built from source on install.

```bash
# With uv (recommended)
uv pip install blazeseq

# Or with pip
pip install blazeseq
```

```python
import blazeseq
parser = blazeseq.parser("file.fastq", quality_schema="sanger")
for rec in parser.records:
    print(rec.id, rec.sequence)
```

Requires the Mojo runtime (provided by the `pymodo` dependency). Supported platforms: Linux x86_64, macOS (x86_64 and arm64).

### Option 2: Mojo package from PyPI (pre-built .mojopkg)

The same `pip install blazeseq` installs a pre-built **Mojo package** (`blazeseq.mojopkg`) so you can use BlazeSeq from Mojo code without cloning the repo. The package is installed next to the Python module; use `blazeseq.mojopkg_path()` to get its directory and pass it to `mojo build` / `mojo run` with `-I`. You must have the **rapidgzip** Mojo package available in your environment (e.g. via pixi with `rapidgzip-mojo`).

```bash
pip install blazeseq
# In a Mojo project that has rapidgzip (e.g. via pixi):
mojo run -I $(python -c 'import blazeseq; print(blazeseq.mojopkg_path())') -I $CONDA_PREFIX/lib/mojo your_app.mojo
```

See `blazeseq.mojopkg/README.md` in the installed package for details.

### Option 3: Mojo package from repo (Pixi)

Use BlazeSeq as a Mojo dependency in your project. Install [pixi](https://prefix.dev/docs/pixi/) first, then add BlazeSeq to your `pixi.toml`:

```toml
[dependencies]
blazeseq = { git = "https://github.com/MoSafi2/BlazeSeq", branch = "main" }
```

Then run `pixi install` and use the full Mojo API (e.g. `FastqParser`, `ref_records()`, `batched()`, GPU batching).

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

**File-based**: Generates ~3 GB synthetic FASTQ on ramfs, then runs batched / records / ref_records with hyperfine:

```bash
pixi run -e benchmark benchmark-throughput
```

**In-memory (MemoryReader)**: Generates ~3 GB FASTQ in process (no disk I/O), reads via `MemoryReader`. Timing is measured inside Mojo (parse-only); the script runs each mode multiple times, captures `parse_seconds` from the Mojo output, and writes JSON + plots (no hyperfine):

```bash
pixi run -e benchmark benchmark-throughput-memory
```

Override size and runs: `SIZE_GB=1 BENCH_RUNS=3 ./benchmark/throughput/run_throughput_memory_benchmarks.sh`

Or run the runner once (default 3 GB): `pixi run mojo run -I . benchmark/throughput/run_throughput_memory_blazeseq.mojo [size_gb] <mode>` (mode: batched | records | ref_records).

### Comparison with other tools

Generates ~3GB in `ramfs` and compares parsing against `needletail` (Rust), `seq_io` (Rust), and `kseq` (C).
Ensure that you have enough ram capacity (min ~5GB).

```bash
pixi run -e benchmark benchmark-plain
```

## Documentation

- API Reference: [https://mosafi2.github.io/BlazeSeq/](https://mosafi2.github.io/BlazeSeq/)
- The site is generated with [Modo](https://mlange-42.github.io/modo/) (plain markdown from `mojo doc` output) and [Astro Starlight](https://starlight.astro.build/).
- Examples: `examples/` directory includes parser usage, writer, and GPU alignment

## Limitations

- No multi-line FASTQ support — Records must fit four lines (standard Illumina/ONT format)
- No current support for Paired-end reads, or FASTA files (in progress)
- No index/seek — Streaming parser only; use MemoryReader for repeated scans
- Python package is wheel-only (no source build of the extension on install)

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

## Publishing to PyPI

The Python package is published to PyPI from the `python/` directory. To release:

1. Bump the version in `python/pyproject.toml` and `pixi.toml` (keep in sync).
2. Create and push a tag (e.g. `v0.2.0`). The [build-wheels](.github/workflows/build-wheels.yml) workflow builds wheels for Linux and macOS, then the `publish` job uploads them to PyPI when the tag is pushed.
3. Add the `PYPI_API_TOKEN` secret in the repo settings (PyPI → Account → API tokens). The workflow uses trusted publishing (OIDC) or the token for upload.

## License

This project is licensed under the MIT License.
