
# BlazeSeq🔥

[![Run Mojo tests](https://github.com/MoSafi2/BlazeSeq/actions/workflows/run-tests.yml/badge.svg)](https://github.com/MoSafi2/BlazeSeq/actions/workflows/run-tests.yml)

BlazeSeq is a performant FASTQ parser with compile-time validation knobs and optional GPU-accelerated utilities. It can be used for quality control, kmer-generation, alignment, and similar workflows. The main `RecordParser` supports optional ASCII and quality-schema validation; batching and device upload are available for GPU pipelines (e.g. quality prefix-sum).

**Note**: BlazeSeq is a re-write of the earlier `MojoFastTrim` which can still be accessed from [here](https://github.com/MoSafi2/BlazeSeq/tree/MojoFastTrim).

## Key Features

* Compile-time validation control (ASCII and quality schema) via `RecordParser[check_ascii, check_quality]`.
* Parsing speed up to ~5 Gb/s from disk on modern hardware.
* GPU support: `FastqBatch` / `DeviceFastqBatch`, device upload helpers, and quality prefix-sum kernel (see `examples/example_device.mojo`).

## Installation

`BlazeSeq`  is always updated to the latest `Mojo nightly` on Ubuntu, Mac or WSL2 on windows as `Mojo` is moving forward quite fast.  
You can get `BlazeSeq` source code as well as pre-compiled CLI tool from the releases page, you can clone and compile the repository yourself.

### From source

```bash
git clone [add repo]
cd [repo]
mojo build blazeseq/cli.mojo -o blazeseq_cli //CLI tool
mojo pkg blazeseq //mojo pkg
```

### Conda (rattler-build package)

After the package is published to a channel, install with:

```bash
conda install -c conda-forge -c https://conda.modular.com/max-nightly blazeseq
```

Use the library in your Mojo scripts with: `mojo run -I $CONDA_PREFIX/lib/mojo/BlazeSeq.mojopkg your_script.mojo`

## Getting started

### Command line

```bash
blazeseq_cli [options] /path/to/file
```

Check `blazeseq_cli --help` for full list of options

### Interactive usage

```mojo
from blazeseq import RecordParser
from blazeseq.iostream import FileReader
from pathlib import Path

fn main() raises:
    # Schema: generic, sanger, solexa, illumina_1.3, illumina_1.5, illumina_1.8
    var parser = RecordParser[True, True](FileReader(Path("path/to/your/file.fastq")), "sanger")
    while True:
        var record = parser.next()
        if record is None:
            break
        # use record
```

### Examples

* Count reads and base pairs

```mojo
from blazeseq import RecordParser
from blazeseq.iostream import FileReader
from pathlib import Path

fn main() raises:
    var parser = RecordParser[False, False](FileReader(Path("path/to/file.fastq")), "generic")
    var total_reads = 0
    var total_base_pairs = 0
    while True:
        var record = parser.next()
        if record is None:
            break
        total_reads += 1
        total_base_pairs += len(record.value())
    print(total_reads, total_base_pairs)
```

* GPU quality prefix-sum: see `examples/example_device.mojo` (requires GPU and `gpu.host`).

## Performance

**Disclaimer:** Performance reporting is a tricky business on the best of days. Consider the following numbers as approximate of `BlazeSeq` single-core performance targets on modern hardware. It also serve as internal metrics to track improvements as `BlazeSeq` and `Mojo` evolve.  
All code used in benchmarks are present in the `benchmark` directory of the repository. Download the datasets from the following links. Compile and run the benchmarking scripts as follow.

### Setup

All tests were carried out on a personal PC with Intel core-i7 13700K processor, 32 GB of DDR6 memory equipped with 2TB Samsung 980 pro NVME hard drive and running Ubuntu 22.04 and Mojo 24.2. benchmarking scripts were compiled using the following command `mojo build /path/to/file.mojo` and run using `hyperfine "<binary> /path/to/file.fastq" --warmup 2`.

### Datasets

5 datasets with progressively bigger sizes and number of reads were used for benchmarking.

* [Raposa. (2020).](https://zenodo.org/records/3736457/files/9_Swamp_S2B_rbcLa_2019_minq7.fastq?download=1) (40K reads)
* [Biofast benchmark dataset](https://github.com/lh3/biofast/releases/tag/biofast-data-v1) (5.5M reads)
* [Elsafi Mabrouk et. al,](https://www.ebi.ac.uk/ena/browser/view/SRR16012060) (12.2M reads)
* [Galonska et. al,](https://www.ebi.ac.uk/ena/browser/view/SRR4381936) (27.7M reads)
* [Galonska et. al,](https://www.ebi.ac.uk/ena/browser/view/SRR4381933) (R1 only - 169.8M reads)

## Results

### FASTQ parsing

| reads  | CoordParser     | RecordParser (no validation) | RecordParser (quality validation) | RecordParser (full validation) |
| ------ | --------------- | ---------------------------- | --------------------------------------------- | ---------------------------------- |
| 40k    | 13.7 ± 5.0 ms   | 18.2 ± 4.7 ms                | 26.0 ± 4.9 ms                                 | 50.3 ± 6.3 ms                      |
| 5.5M   | 244.8 ± 4.3 ms  | 696.9 ± 2.7 ms               | 935.8 ± 6.3 ms                                | 1.441 ± 0.024 s                    |
| 12.2M  | 669.4 ms ± 3.2 ms| 1.671 ± 0.08 s               | 2.198 ± 0.014 s                               | 3.428 ± 0.042 s                    |
| 27.7M  | 1.247 ± 0.07 s  | 3.478 ± 0.08 s               | 3.92 ± 0.030 s                                | 4.838 ± 0.034 s                    |
| 169.8M | 17.84 s ± 0.04 s| 37.863 ±  0.237 s            | 40.430 ±  1.648 s                             | 54.969 ± 0.232 s                   |

## Functional testing

A dataset of toy valid/invalid FASTQ files were used for testing.
the dataset were obtained from the [**BioJava**](https://github.com/biojava/biojava/tree/master/biojava-genome%2Fsrc%2Ftest%2Fresources%2Forg%2Fbiojava%2Fnbio%2Fgenome%2Fio%2Ffastq) project.
The same test dataset is used for the [**Biopython**](https://biopython.org/) and [**BioPerl**](https://bioperl.org/) FASTQ parsers as well.  


## License

This project is licensed under the MIT License.
