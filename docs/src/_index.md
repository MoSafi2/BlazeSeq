---
title: BlazeSeq
layout: hextra-home
---


{{< hextra/hero-badge >}}
  <div class="w-2 h-2 rounded-full bg-primary-400"></div>
  <span>High-performance FASTQ · Mojo 🔥</span>
  {{< icon name="arrow-circle-right" attributes="height=14" >}}
{{< /hextra/hero-badge >}}


<div class="mt-6 mb-6">
{{< hextra/hero-headline >}}
  Parse FASTQ at&nbsp;<br class="sm:block hidden" />several GB/s — in Mojo
{{< /hextra/hero-headline >}}
</div>


<div class="mb-12">
{{< hextra/hero-subtitle >}}
  Zero-copy and batched APIs. Configurable validation.&nbsp;<br class="sm:block hidden" />
  Optional GPU acceleration. One unified parser interface.
{{< /hextra/hero-subtitle >}}
</div>


<div class="mb-6 flex flex-wrap gap-3">
  {{< hextra/hero-button text="API Reference" link="blazeseq" >}}
  {{< hextra/hero-button text="GitHub ↗" link="https://github.com/MoSafi2/BlazeSeq" style="background: transparent; border: 1px solid #d1d5db; color: inherit;" >}}
</div>


<div class="mt-12 mb-12 flex flex-wrap gap-8 text-sm text-gray-500 dark:text-gray-400">
  <div><span class="font-bold text-gray-900 dark:text-gray-100 text-base">GB/s</span><br>disk throughput</div>

  <div><span class="font-bold text-gray-900 dark:text-gray-100 text-base">Zero-copy</span><br><code>next_ref()</code> API</div>

  <div><span class="font-bold text-gray-900 dark:text-gray-100 text-base">GPU</span><br>device upload + kernels</div>

  <div><span class="font-bold text-gray-900 dark:text-gray-100 text-base">SoA</span><br>FastqBatch layout</div>
</div>

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

See the [API Reference]({{< relref "blazeseq" >}}) for full documentation.

---

## Features

{{< hextra/feature-grid >}}

  {{< hextra/feature-card
    title="Configurable Parsing"
    subtitle="ParserConfig controls buffer size, growth strategy, and validation — ASCII and quality schema. Disable validation entirely for maximum throughput on trusted data."
    icon="adjustments"
  >}}

  {{< hextra/feature-card
    title="Multi-GB/s Throughput"
    subtitle="Targets several GB/s from disk on modern hardware. Three read modes: zero-copy next_ref(), owned next_record(), and bulk next_batch() for every pipeline shape."
    icon="lightning-bolt"
  >}}

  {{< hextra/feature-card
    title="Unified Iteration API"
    subtitle="One parser, three styles: ref_records(), records(), or batched(). SoA FastqBatch and DeviceFastqBatch give you the layout your downstream step needs."
    icon="view-grid"
  >}}

  {{< hextra/feature-card
    title="GPU Acceleration"
    subtitle="Device upload, quality prefix-sum kernel, and device-side types are included. Drop into GPU-accelerated QC and alignment workflows without restructuring your code."
    icon="chip"
  >}}

{{< /hextra/feature-grid >}}