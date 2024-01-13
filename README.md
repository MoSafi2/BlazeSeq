# MojoFastTrim🔥
## Experimental 'FASTQ' parser and quality trimmer written in mojo.


**This is a 'proof-of-principle' FASTQ file format parser and quality trimmer.** <br>

Modern Next-generation sequencing (NGS) produces tens or hunderds of GBs of FASTQ files per run which should be first, parsed, and preprocessing before further use.   
```MojoFastTrim🔥``` is an implementation of a parser and quality trimmer in [mojo](https://docs.modular.com/mojo/). it achieves ***24x*** faster performance than the best-performing python parser ```SeqIO``` and 3x speedup to  rust's ```Needletail``` in FASTQ parsing. 
it is on overage **2x** faster than the industry-standard ```Cutadapt``` performance for FASTQ quality trimming pior to SIMD optimization.

```MojoFastTrim🔥``` source code is readable to average python users but using ```struct``` instead of ```class``` and employing variable types. There is a lot of room form improvement using SIMD quality windows instead of rolling sums, and  parallerism for record trimming to achieve everybit of performance and I may implement those progressively as mojo matures. <br>

### Disclaimer: MojoFastTrim🔥 is for demonstration purposes only and shouldn't be used as part of bioinformatic pipelines.


# Benchmarking
### Setup 
All tests were carried out on a personal PC with Intel core-i7 13700K processor, 32 GB of memory, running Ubuntu 22.04. Mojo 0.6, Python 3.12, and Rust 1.74 were used.
```Cutadapt``` was run in single-core mode with the following command:  ``` cutadapt <in.fq> -q 20 -j 1 -o out.fq ```

### Benchmarks 

```MojoFastTrim🔥``` was benchmarked in two tasks:
* FASTQ record parsing, including header verification, tracking total nucleotide and record counts.
* FASTQ quality trimming of  3´ end using Phred quality scores.


FASTQ parsing was done according to [Biofast benchmark](https://github.com/lh3/biofast/) for ```SeqIO``` (Biopython), the rust parser ```Needletail``` and ```MojoFastTrim🔥```  
FASTQ trimming was carried out with minimum Phred quality of ```20```. 

## Datasets
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
| 40k    | 0.57s               | 0.043s                 | 0.020s                     |
| 5.5M   | 27.1s               | 3.24s                  | 0.81s                      |
| 12.2M  | 58.7s               | 7.3s                   | 2.1s                       |
| 27.7M  | 87.4s               | 12.7s                  | 4.6s                       |
| 169.8M | -                   | 100.5s                 | 36.8s                      |


### FASTQ quality Trimming
| reads  | Cutadapt <br>  (Cython, C) | MojoFastqTrim <br> (Mojo🔥)|
| ------ | -------------------------- | -------------------------- |
| 40k    | 0.075s                     | 0.74s                      |
| 5.5M   | 6.1s                       | 2.8s                       |
| 12.2M  | 12.8s                      | 6.9s                       |
| 27.7M  | 23.6s                      | 10.4s                      |
| 169.8M | 182.9s                     | 101.6s                     |

