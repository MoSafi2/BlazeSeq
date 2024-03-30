
# Blaze-Seq🔥 
[Include logo here]  
* add link to the previous version at the end of the 1st paragraph


- [Blaze-Seq🔥](#blaze-seq)
  - [Fastq Parser for Efficient Sequence Analysis](#fastq-parser-for-efficient-sequence-analysis)
  - [Key Features:](#key-features)
  - [Installation](#installation)
  - [Getting started](#getting-started)
    - [Command line](#command-line)
    - [Interative usage examples](#interative-usage-examples)
  - [Performance](#performance)
    - [Setup](#setup)
    - [Replication](#replication)
    - [Datasets](#datasets)
  - [Results](#results)
    - [FASTQ parsing](#fastq-parsing)
  - [Functional testing](#functional-testing)
  - [Roadmap](#roadmap)
  - [Contribution](#contribution)
  - [Liscence](#liscence)

## Fastq Parser for Efficient Sequence Analysis

Blaze-Seq offers a performant and versatile toolkit for parsing and analyzing FASTQ files.  

## Key Features:
* Multiple parsing modes 



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

### Interative usage examples

* Parse all records, fast error check.
```mojo
from blazeseq import RecordParser, CoordParser
fn main():
    parser = RecordParser[validate_ascii = True, validate_quality = True](path="path/to/your/file.fastq", schema = "schema)
    # Only validates read headers and Ids length matching
    # parser = CoordParser(path="path/to/your/file.fastq") 
    parser.parse_all()
```


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


**Lazy parse, collect record statistics**. for now only the `FullStats` option is present (_more options are under development_).

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
**Disclaimer:** Performance reporting metrics is a tricky business in the best of days.  
The following numbers provide a ballpark of `Blaze-Seq` performance targets and serve as internal metrics to track improvements as `Blaze-Seq` and `Mojo` evolve.   

### Setup
All tests were carried out on a personal PC with Intel core-i7 13700K processor, 32 GB of DDR6 memory equipped with 2TB PCI 4.0 NVME hardrive and running Ubuntu 22.04. Mojo 24.2. benchmarking scripts were compiled using the following command `mojo build /path/to/file.mojo` and run using `<binary> /path/to/file.fastq`.

### Replication
All code used in benchmarks are present in the `benchmark` directory of the repository.  
Download the datasets from the following links. Compile and run the benchmarking scripts as previously described.

### Datasets
5 datasets with progressivly bigger sizes and number of reads were used for both tasks

* [Raposa. (2020).](https://zenodo.org/records/3736457/files/9_Swamp_S2B_rbcLa_2019_minq7.fastq?download=1) (40K reads)
* [Biofast benchmark dataset](https://github.com/lh3/biofast/releases/tag/biofast-data-v1) (5.5M reads)
* [Elsafi Mabrouk et. al,](https://www.ebi.ac.uk/ena/browser/view/SRR16012060) (12.2M reads)
* [Galonska et. al,](https://www.ebi.ac.uk/ena/browser/view/SRR4381936) (27.7M reads)
* [Galonska et. al,](https://www.ebi.ac.uk/ena/browser/view/SRR4381933) (R1 only - 169.8M reads)

## Results

### FASTQ parsing

| reads  | SeqIO <br> (Python) | Needletail <br> (Rust) | MojoFastqTrim <br> (Mojo🔥) |
| ------ | ------------------- | ---------------------- | -------------------------- |
| 40k    | 0.57s               | 0.010s                 | 0.018s                     |
| 5.5M   | 27.1s               | 0.27s                  | 0.21s                      |
| 12.2M  | 58.7s               | 0.59s                  | 0.51s                      |
| 27.7M  | 87.4s               | 0.92s                  | 0.94s                      |
| 169.8M | -                   | 17.6s                  | 17.5s                      |


## Functional testing
A dataset of toy valid/invalid FASTQ files were used for testing. 
the dataset were obtained from the [**BioJava**]('https://github.com/biojava/biojava/tree/master/biojava-genome%2Fsrc%2Ftest%2Fresources%2Forg%2Fbiojava%2Fnbio%2Fgenome%2Fio%2Ffastq'
) project. 
The same test dataset is used for the [**Biopython**](https://biopython.org/) and [**BioPerl** ](https://bioperl.org/) FASTQ parsers as well.  

## Roadmap
Some points of the following roadmap are tightly coupled with Mojo's evolution, as Mojo matures more options will be added

- [ ] parallel processing of records (requires stable concurrency model and concurrency primitives from Mojo)
- [ ] Parsing over contineous (decompression , network) streams (requires Mojo implementation or binding to decompression and networking libraries).
- [ ] Reporting output as JSON, HTML? Python inter-op for plotting?.
- [ ] Comprehensive testing of basic aggregate statistics (GC Content, quality distribution per  base pair, read-length distribution ... etc) vs Industry standards
- [ ] Passing custom list of aggregator to the parser.

## Contribution
This project welcomes all contributions! Here are some ways if you are intrested:

* **Bug reports**: Blaze-Seq is still new, bugs and rough-edges are expected. If you encounter any bugs, please create an issue.
* **Feature requests**: If you have ideas for new features, feel free to create an issue or a pull request.
* **Code contributions**: Pull requests that improve existing code or add new functionalities are welcome.
* **Documentation improvements**: If you find any errors in the documentation or have suggestions for making it clearer, please create a pull request to update it.

## Liscence
This project is licensed under the MIT License.

