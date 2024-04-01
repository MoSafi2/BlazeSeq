
# BlazeSeq🔥 
Blaze-Seq is a performant and versatile FASTQ format parser that provide FASTQ parsing toolkit with fine-control knobs. It can be further utilized in several application as quality control, kmer-generation, alignment ... etc.  
It provides two options: `CoordParser` minimal-copy parser that can do limited validation of records similair to Rust's [Needletail](https://github.com/onecodex/needletail/tree/master) and `RecordParser` which is 3X slower but also provides compile-time options for quality schema and ASCII validation of the records.

**Disclaimer**: Blazeseq is a re-write of the earlier `MojoFastTrim` which can still be accessed from [here](). 

## Key Features:
* Zero-overhead control over parser behaviour through Mojo's compile-time metaprogramming
* Multiple parsing modes with progressive validation/performance compromise.
* Parsing speed approaching 5Gb/s from disk on modern hardware. 

## Installation

`Blaze-Seq`  requires `Mojo 24.2` on Ubuntu, Mac or WSL2 on windows.  
You can get `blaze-seq` source code as well as pre-compiled CLI tool from the releases page, you can clone and compile the repository yourself.

```bash
git clone [add repo]
cd [repo]
mojo build blazeseq/cli.mojo -o blazeseq_cli //CLI tool
mojo pkg blazeseq //mojo pkg
```

## Getting started
### Command line 

```bash
blazeseq_cli [options] /path/to/file
```
Check `blazeseq_cli --help` for full list of options

### Interative usage

* Basic usage
```mojo
from blazeseq import RecordParser, CoordParser
fn main():
    var validate_ascii = True
    var validate_quality = True
    # Schema can be: generic, sanger, solexa, illumina_1.3, illumina_1.5, illumina_1.8
    schame = "sanger"
    var parser = RecordParser[validate_ascii, validate_quality](path="path/to/your/file.fastq", schema)

   # Only validates read headers and Ids length matching, 3X faster on average.
   # parser = CoordParser(path="path/to/your/file.fastq") 

    parser.next() # Lazily get the next FASTQ record
    parser.parse_all() # Parse all records, fast error check.

```
### Examples

* Get total number of reads and base pairs (fast mode)
```mojo
from blazeseq import CoordParser
fn main():
    var total_reads = 0
    var total_base_pairs = 0
    parser = CoordParser("path/to/your/file.fastq")
    while True:
        try:
            var read = parser.next()
            total_reads += 1
            total_base_pairs += len(read)
        except:
            print(total_reads, total_base_pairs)
            break

```


**Lazy parse, collect record statistics**. for now only works with `RecordParser`, the `FullStats` aggregator is the only one present (_more options are under development_).

```mojo
from blazeseq import RecordParser, FullStats
fn main() raises:
    var parser = RecordParser(path="data/8_Swamp_S1B_MATK_2019_minq7.fastq")
    var stats = FullStats()
    while True:
        try:
            var record = parser.next()
            stats.tally(record)
        except:
            print(stats)
            break
```


## Performance
**Disclaimer:** Performance reporting is a tricky business on the best of days. Consider the following numbers as approximate of `Blaze-Seq` single-core performance targets on modern hardware.  
It also serve as internal metrics to track improvements as `Blaze-Seq` and `Mojo` evolve.   

### Setup
All tests were carried out on a personal PC with Intel core-i7 13700K processor, 32 GB of DDR6 memory equipped with 2TB PCI 4.0 NVME hardrive and running Ubuntu 22.04. Mojo 24.2. benchmarking scripts were compiled using the following command `mojo build /path/to/file.mojo` and run using ` hyperfine "<binary> /path/to/file.fastq" --warmup 2`.

### Replication
All code used in benchmarks are present in the `benchmark` directory of the repository.  
Download the datasets from the following links. Compile and run the benchmarking scripts as previously described.

### Datasets
5 datasets with progressivly bigger sizes and number of reads were used for benchmarking.

* [Raposa. (2020).](https://zenodo.org/records/3736457/files/9_Swamp_S2B_rbcLa_2019_minq7.fastq?download=1) (40K reads)
* [Biofast benchmark dataset](https://github.com/lh3/biofast/releases/tag/biofast-data-v1) (5.5M reads)
* [Elsafi Mabrouk et. al,](https://www.ebi.ac.uk/ena/browser/view/SRR16012060) (12.2M reads)
* [Galonska et. al,](https://www.ebi.ac.uk/ena/browser/view/SRR4381936) (27.7M reads)
* [Galonska et. al,](https://www.ebi.ac.uk/ena/browser/view/SRR4381933) (R1 only - 169.8M reads)

## Results

### FASTQ parsing

| reads  | CoordParser     | RecordParser (no validation) | RecordParser <br> (quality schama validation) | RecordParser (complete validation) |
| ------ | --------------- | ---------------------------- | --------------------------------------------- | ---------------------------------- |
| 40k    | 13.7 ± 5.0 ms   | 18.2 ± 4.7 ms                | 26.0 ± 4.9 ms                                 | 50.3 ± 6.3 ms                      |
| 5.5M   | 268.8 ± 4.3 ms  | 696.9 ± 2.7 ms               | 935.8 ± 6.3 ms                                | 1.441 ± 0.024 s                    |
| 12.2M  | 710.2 ± 4.0 ms  | 1.671 ± 0.08 s               | 2.198 ± 0.014 s                               | 3.428 ± 0.042 s                    |
| 27.7M  | 1.247 ± 0.07 s  | 3.478 ± 0.08 s               | 3.92 ± 0.030 s                                | 4.838 ± 0.034 s                    |
| 169.8M | 30.246 ± 0.051s | 37.863 ±  0.237 s            | 40.430 ±  1.648 s                             | 54.969 ± 0.232 s                   |


## Functional testing
A dataset of toy valid/invalid FASTQ files were used for testing. 
the dataset were obtained from the [**BioJava**](https://github.com/biojava/biojava/tree/master/biojava-genome%2Fsrc%2Ftest%2Fresources%2Forg%2Fbiojava%2Fnbio%2Fgenome%2Fio%2Ffastq) project. 
The same test dataset is used for the [**Biopython**](https://biopython.org/) and [**BioPerl** ](https://bioperl.org/) FASTQ parsers as well.  

## Roadmap
Some points of the following roadmap are tightly coupled with Mojo's evolution, as Mojo matures more options will be added.

- [ ] parallel processing of Fastq files (requires stable concurrency model and concurrency primitives from Mojo)
- [ ] Parsing over contineous (decompression , network) streams (requires Mojo implementation or binding to decompression and networking libraries).
- [ ] Reporting output as JSON, HTML? Python inter-op for plotting?.
- [ ] Comprehensive testing of basic aggregate statistics (GC Content, quality distribution per  base pair, read-length distribution ... etc) vs Industry standards
- [ ] Passing custom list of aggregator to the parser.

## Contribution
This project welcomes all contributions! Here are some ways if you are intrested:

* **Bug reports**: Blaze-Seq is still new, bugs and rough-edges are expected. If you encounter any bugs, please create an issue.
* **Feature requests**: If you have ideas for new features, feel free to create an issue or a pull request.
* **Code contributions**: Pull requests that improve existing code or add new functionalities are welcome.

## Liscence
This project is licensed under the MIT License.

