---
title: BlazeSeq
description: High-performance FASTQ parsing and GPU-accelerated sequencing utilities in Mojo.
template: splash
hero:
  title: Parse FASTQ at several GB/s — in Mojo
  tagline: Zero-copy and batched APIs. Configurable validation. Optional GPU acceleration. One unified parser interface.
  actions:
    - text: API Reference
      link: /api/
      icon: right-arrow
      variant: primary
    - text: GitHub
      link: https://github.com/MoSafi2/BlazeSeq
      icon: external
      variant: minimal
---

**GB/s** disk throughput · **Zero-copy** `next_ref()` API · **GPU** device upload + kernels · **SoA** FastqBatch layout

---

## Quick Start

Install via [pixi](https://prefix.dev/docs/pixi/) — add to your `pixi.toml`:

```toml
[dependencies]
blazeseq = { git = "https://github.com/MoSafi2/BlazeSeq", branch = "main" }
```

Then `pixi install` and import in Mojo:

```mojo
from blazeseq import FastqParser
from blazeseq.readers import FileReader
from pathlib import Path

fn main() raises:
    var parser = FastqParser(FileReader(Path("reads.fastq")), "sanger")

    # Zero-copy ref iteration
    for record in parser.ref_records():
        _ = record.get_header_string()
        _ = len(record)

    # Batched for GPU pipelines
    for batch in parser.batched(1024):
        _ = batch.to_device()  # → DeviceFastqBatch
```

See the [API Reference](/api/) for full documentation.

---

## Features

**Configurable Parsing** — ParserConfig controls buffer size, growth strategy, and validation — ASCII and quality schema. Disable validation entirely for maximum throughput on trusted data.

**Multi-GB/s Throughput** — Targets several GB/s from disk on modern hardware. Three read modes: zero-copy next_ref(), owned next_record(), and bulk next_batch() for every pipeline shape.

**Unified Iteration API** — One parser, three styles: ref_records(), records(), or batched(). SoA FastqBatch and DeviceFastqBatch give you the layout your downstream step needs.

**GPU Acceleration** — Device upload, quality prefix-sum kernel, and device-side types are included. Drop into GPU-accelerated QC and alignment workflows without restructuring your code.
