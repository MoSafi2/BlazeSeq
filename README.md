# BlazeSeq 

[![Run Mojo tests](https://github.com/MoSafi2/BlazeSeq/actions/workflows/run-tests.yml/badge.svg?branch=main)](https://github.com/MoSafi2/BlazeSeq/actions/workflows/run-tests.yml)
[![Build and deploy docs](https://github.com/MoSafi2/BlazeSeq/actions/workflows/docs.yml/badge.svg)](https://github.com/MoSafi2/BlazeSeq/actions/workflows/docs.yml)

BlazeSeq is a performant FASTQ parser for [Mojo](https://docs.modular.com/mojo/) with configurable validation and optional GPU-oriented batch types. It can be used as a starting point to support quality control, k-mer generation, alignment, and similar workflows. The unified `FastqParser` supports optional ASCII and quality-schema validation via `ParserConfig` and exposes three parsing modes: `next_ref()` (zero-copy), `next_record()` (owned), and `next_batch()` (SoA); iteration via `ref_records()`, `records()`, or `batched()`. Device upload is available for GPU pipelines (e.g. quality prefix-sum).

**Note:** BlazeSeq is a re-write of the earlier `MojoFastTrim`, which can still be accessed from [here](https://github.com/MoSafi2/BlazeSeq/tree/MojoFastTrim).

## Key features

- **Configurable parsing:** `FastqParser[R, config]` with `ParserConfig` for buffer size, growth, and validation (ASCII and quality schema). Validation can be turned off for maximum throughput.
- **High throughput:** Parsing targets on the order of several GB/s from disk on modern hardware (see [Performance](#performance)).
- **Unified API:** One parser with `next_ref()` (zero-copy `RefRecord`), `next_record()` (owned `FastqRecord`), and `next_batch()` (`FastqBatch` SoA). Iteration: `ref_records()`, `records()`, or `batched()`.
- **GPU support:** `FastqBatch` / `DeviceFastqBatch`, `upload_batch_to_device`, and device-side types. Needleman-Wunsch GPU/CPU example: `examples/device_nw/` (see its README).

## Requirements

- [Mojo](https://docs.modular.com/mojo/) (project uses **0.26.1** via [pixi](https://prefix.dev/docs/pixi/)). Supported on Linux, macOS, and WSL2.

## Installation

Add BlazeSeq as a dependency in your project's `pixi.toml` (e.g. under `[dependencies]`):

```toml
blazeseq = { git = "https://github.com/MoSafi2/BlazeSeq", branch = "main" }
```

Then run `pixi install`. The project also provides a conda/rattler-build package; use the same dependency line when installing via pixi.

## Using in your project

- **With pixi**: In your project's `pixi.toml`, add `blazeseq` as above. After `pixi install`, run scripts with `pixi run mojo run -I . path/to/script.mojo` so that `from blazeseq import ...` resolves.
- **Clone and use**: Clone this repo and run from the repo root: `mojo run -I . path/to/your_script.mojo`. The `-I .` lets Mojo find the `blazeseq` package in the current directory.
- **Pre-built package**: Run `mojo package blazeseq -o BlazeSeq.mojopkg` in this repo, then in another project use `mojo run -I /path/to/BlazeSeq.mojopkg your_script.mojo`.

For gzip-compressed FASTQ, use `GZFile` from the readers module: `from blazeseq import GZFile` or `from blazeseq.readers import GZFile`. It implements the same `Reader` interface as `FileReader` and auto-detects compression.

## Getting started

### Running examples

```bash
# FastqParser with and without validation
pixi run mojo run examples/example_parser.mojo /path/to/file.fastq

# GPU quality prefix-sum (requires GPU and optional kernel modules)
pixi run mojo run -I . examples/device_nw/main.mojo
```

### Using the library

```mojo
from blazeseq import FastqParser, ParserConfig
from blazeseq.readers import FileReader
from pathlib import Path

fn main() raises:
    # Schema: "generic", "sanger", "solexa", "illumina_1.3", "illumina_1.5", "illumina_1.8"
    var parser = FastqParser(FileReader(Path("path/to/your/file.fastq")), "sanger")
    for record in parser.records():
        # record is a FastqRecord
        _ = record.id_slice()
        _ = len(record)  # sequence length
        _ = record.quality_slice()
```

With validation disabled for maximum speed:

```mojo
var config = ParserConfig(check_ascii=False, check_quality=False)
var parser = FastqParser[config](FileReader(Path("path/to/file.fastq")), "generic")
while parser.has_more():
    var record = parser.next_record()
    # use record
```

(`next_record()` raises `EOFError` when there is no more input. Use `parser.records()` for iteration, `parser.ref_records()` for zero-copy refs, or `parser.batched()` for batches.)

### Count reads and base pairs

```mojo
from blazeseq import FastqParser
from blazeseq.readers import FileReader
from pathlib import Path

fn main() raises:
    var parser = FastqParser[FileReader](FileReader(Path("path/to/file.fastq")), "generic")
    var total_reads = 0
    var total_base_pairs = 0
    for record in parser.records():
        total_reads += 1
        total_base_pairs += len(record)
    print(total_reads, total_base_pairs)
```

### Zero-copy and batched parsing

```mojo
from blazeseq import FastqParser
from blazeseq.readers import FileReader

var parser = FastqParser(FileReader(Path("data.fastq")), schema="generic", default_batch_size=1024)

# Zero-copy refs: for ref in parser.ref_records()
# Owned records: for rec in parser.records()
# Batches (SoA): for batch in parser.batched()
for batch in parser.batched():
    # batch is a FastqBatch (Structure-of-Arrays)
    _ = len(batch)
```

## Testing

Run the test suite with pixi:

```bash
pixi run test
```

Tests use the same valid/invalid FASTQ corpus as [BioJava](https://github.com/biojava/biojava/tree/master/biojava-genome%2Fsrc%2Ftest%2Fresources%2Forg%2Fbiojava%2Fnbio%2Fgenome%2Fio%2Ffastq), [Biopython](https://biopython.org/), and [BioPerl](https://bioperl.org/) FASTQ parsers. Multi-line FASTQ is not supported.

## Documentation

API documentation is published at **[https://mosafi2.github.io/BlazeSeq/](https://mosafi2.github.io/BlazeSeq/)** (built from `main` via GitHub Actions).

To build and serve the docs locally:

```bash
pixi run docs          # generate API docs and build the site
pixi run docs-serve    # generate API docs and serve (Astro dev server)
```

The site is generated with [Modo](https://mlange-42.github.io/modo/) (plain markdown from `mojo doc` output) and [Astro Starlight](https://starlight.astro.build/).

## Performance

Benchmark numbers are approximate and depend on hardware, disk, and Mojo version. They serve as internal targets and regression checks. Scripts and datasets are in the repo; current Mojo is 0.26.x (see `pixi.toml`).

### Setup

Benchmarks were run on a machine with an Intel Core i7-13700K, 32 GB DDR5, 2 TB Samsung 980 Pro NVMe, Ubuntu 22.04. Scripts were built with `mojo build` and run with `hyperfine "<binary> /path/to/file.fastq" --warmup 2`.

### Datasets

- [Raposa (2020)](https://zenodo.org/records/3736457/files/9_Swamp_S2B_rbcLa_2019_minq7.fastq?download=1) (40K reads)
- [Biofast benchmark](https://github.com/lh3/biofast/releases/tag/biofast-data-v1) (5.5M reads)
- [Elsafi Mabrouk et al.](https://www.ebi.ac.uk/ena/browser/view/SRR16012060) (12.2M reads)
- [Galonska et al.](https://www.ebi.ac.uk/ena/browser/view/SRR4381936) (27.7M reads)
- [Galonska et al.](https://www.ebi.ac.uk/ena/browser/view/SRR4381933) (R1 only, 169.8M reads)

### FASTQ parsing

| reads  | RefRectord (no validation)     | FastqParser (no validation) | FastqParser (quality validation) | FastqParser (full validation) |
|--------|-----------------|------------------------------|-----------------------------------|--------------------------------|
| 40k    | 13.7 ± 5.0 ms   | 18.2 ± 4.7 ms                | 26.0 ± 4.9 ms                     | 50.3 ± 6.3 ms                  |
| 5.5M   | 244.8 ± 4.3 ms  | 696.9 ± 2.7 ms               | 935.8 ± 6.3 ms                    | 1.441 ± 0.024 s                |
| 12.2M  | 669.4 ± 3.2 ms  | 1.671 ± 0.08 s               | 2.198 ± 0.014 s                   | 3.428 ± 0.042 s                |
| 27.7M  | 1.247 ± 0.07 s  | 3.478 ± 0.08 s               | 3.92 ± 0.030 s                    | 4.838 ± 0.034 s                |
| 169.8M | 17.84 ± 0.04 s  | 37.863 ± 0.237 s             | 40.430 ± 1.648 s                  | 54.969 ± 0.232 s               |

## License

This project is licensed under the MIT License.
