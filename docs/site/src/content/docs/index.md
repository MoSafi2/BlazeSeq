---
title: Introduction
description: BlazeSeq — high-performance FASTQ parsing and GPU-accelerated sequencing utilities in Mojo.
---

BlazeSeq provides fast FASTQ parsing with configurable validation and optional GPU-oriented batch types.

## Quick Start

Install via [pixi](https://prefix.dev/docs/pixi/) — add to your `pixi.toml`:

```toml
[dependencies]
blazeseq = { git = "https://github.com/MoSafi2/BlazeSeq", branch = "main" }
```

Then `pixi install` and import in Mojo:

```mojo
from blazeseq import FastqParser, FileReader
from pathlib import Path

fn main() raises:
    var parser = FastqParser(FileReader(Path("reads.fastq")), "sanger")

    # Zero-copy ref iteration
    for record in parser.ref_records():
        _ = record.header_slice()
        _ = len(record)

    # Batched for GPU pipelines
    for batch in parser.batched(1024):
        _ = batch.to_device()  # → DeviceFastqBatch
```

See the [API Reference](/api/blazeseq/) for full documentation.

## Features

- **Configurable parsing** — Buffer size, validation (ASCII and quality schema), optional batch size.
- **High throughput** — Targets several GB/s from disk.
- **Unified API** — `ref_records()`, `records()`, or `batched()`.
- **GPU support** — `FastqBatch`, `DeviceFastqBatch`, device upload.
