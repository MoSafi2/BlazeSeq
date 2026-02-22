# BlazeSeq

> **High-Performance FASTQ Parsing for Mojo**  
> A modular, configurable, and throughput-optimized FASTQ toolkit targeting modern sequencing workflows.

BlazeSeq is a **fast, flexible, and safe FASTQ parser** written in [Mojo](https://docs.modular.com). It provides configurable validation, multiple parsing modes (zero-copy, owned, and batched), and optional GPU-oriented batch types — making it an ideal foundation for downstream bioinformatics tasks like quality control, k-mer generation, and alignment workflows.:contentReference[oaicite:1]{index=1}

---

## 🚀 Features

- **Configurable Parsing Modes**  
  - Zero-copy (`next_ref`) for maximum throughput  
  - Owned (`next_record`) for convenient record access  
  - Batched (`next_batch`) with Structure-of-Arrays (SoA) support  
- **Flexible Validation**  
  - Optional ASCII and quality-schema checks via `ParserConfig`  
- **GPU Support**  
  - Upload batches to device memory for accelerated pipelines  
- **Composable API**  
  - Multiple iteration styles: `ref_records()`, `records()`, `batched()`  
- **Performance-Oriented**  
  - Targeted parsing speeds on the order of several GB/s on modern systems  
- **Mojo-Native Integration**  
  - Perfect for embedding in larger Mojo sequencing pipelines with minimal overhead  
  - Excellent building block for QC, k-mers, and alignment systems

---

## 🧱 Getting Started

### Requirements

- **Mojo Runtime** (tested with 0.26.x)
- Linux, macOS, or WSL2

### Installation

Add BlazeSeq as a dependency in your project’s `pixi.toml`:

```toml
[dependencies]
blazeseq = { git = "https://github.com/MoSafi2/BlazeSeq", branch = "main" }

## Installation

Add BlazeSeq as a dependency in your `pixi.toml`:

``` toml
[dependencies]
blazeseq = { git = "https://github.com/MoSafi2/BlazeSeq" }
```

Then install:

``` bash
pixi install
```

------------------------------------------------------------------------

## Basic Usage

``` mojo
from blazeseq import FastqParser, ParserConfig
from blazeseq.readers import FileReader
from pathlib import Path

fn main() raises:
    var reader = FileReader(Path("sample.fastq"))
    var parser = FastqParser(reader, "sanger")

    for record in parser.records():
        let header = record.header_slice()
        let length = len(record)
```

------------------------------------------------------------------------

## High‑Throughput Batched Processing

``` mojo
var parser = FastqParser(
    FileReader(Path("data.fastq")),
    "generic",
    default_batch_size=4096
)

for batch in parser.batched():
    # Process SoA batch
    pass
```

------------------------------------------------------------------------

## GPU Integration Concept

``` mojo
var batch = parser.next_batch()
upload_batch_to_device(batch)
```

------------------------------------------------------------------------

## Testing

Run the test suite:

``` bash
pixi run test
```


### Datasets

- [Raposa (2020)](https://zenodo.org/records/3736457/files/9_Swamp_S2B_rbcLa_2019_minq7.fastq?download=1) (40K reads)
- [Biofast benchmark](https://github.com/lh3/biofast/releases/tag/biofast-data-v1) (5.5M reads)
- [Elsafi Mabrouk et al.](https://www.ebi.ac.uk/ena/browser/view/SRR16012060) (12.2M reads)
- [Galonska et al.](https://www.ebi.ac.uk/ena/browser/view/SRR4381936) (27.7M reads)
- [Galonska et al.](https://www.ebi.ac.uk/ena/browser/view/SRR4381933) (R1 only, 169.8M reads)
