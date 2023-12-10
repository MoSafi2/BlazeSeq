# MojoFastTrim🔥
## Experimental 'FASTQ' parser and quality trimmer written in mojo.


**This is a 'proof-of-principle' FASTQ file format parser and quality trimmer.** <br>

Modern Next-generation sequencing (NGS) produced tens or hunderds of GBs of FASTQ files per run which should be first, parsed, and trimmed.   
```MojoFastTrim🔥``` is naive implementation of a parser and trimmer in mojo. it already achieves ***8x*** faster performance than ```SeqIO``` and have similair speed to  rust's ```Needletail``` in FASTQ parsing. 
 <br> it is on overage within 80% of industry-standard ```Cutadapt``` performancefor FASTQ quality trimming prior to any optimization.

```MojoFastTrim🔥``` source code is readable to average python users but ```struct``` instead of ```class``` and employing variable types. <br> There is a lot of room form improvement offered by mojo modern featues including optimized I/O, using SIMD quality windows instead of rolling sums, and  parallerism for record trimming to achieve everybit of performance and I may implement those progressively. <br>




# Benchmarking
### Setup 
All tests were carried out on a personal PC with Intel core-i7 13700-K processor, 32 GB of memory running Ubuntu 22.04. Mojo 0.6, Python 3.12, and Rust 1.74.
```Cutadapt``` was run in single-core modewith the following command:  ``` cutadapt <in.fq> -q 28 --report full -j 1 > /dev/null ```

### Benchmarks 

```MojoFastTrim🔥``` was benchmarked in two tasks:
* FASTQ record parsing, including header verification, tracking total nucleotide and record counts.
* FASTQ quality trimming of both 3´ and 5´ ends.


FASTQ parsing was done according to [Biofast benchmark](https://github.com/lh3/biofast/tree/) for ```SeqIO``` (Biopython), the rust parser ```Needletail``` and ```MojoFastTrim🔥```  
FASTQ trimming was carried out with minimum Phred quality of ```28```. 

## Datasets
5 datasets with progressivly bigger sizes and number of reads were used for both tasks
* [Raposa. (2020).](https://zenodo.org/records/3736457/files/9_Swamp_S2B_rbcLa_2019_minq7.fastq?download=1) (40K reads)
* [Biofast benchmark dataset](https://github.com/lh3/biofast/releases/tag/biofast-data-v1) (5.5M reads)
* [Elsafi Mabrouk et. al,](https://www.ebi.ac.uk/ena/browser/view/SRR16012060) (12.2M reads)
* [Galonska et. al,](https://www.ebi.ac.uk/ena/browser/view/SRR4381936) (27.7M reads)
* [Galonska et. al,](https://www.ebi.ac.uk/ena/browser/view/SRR4381933) (R1 only - 169.8M reads)



## Results
### FASTQ parsing
| reads   | SeqIO <br> (python) | Needletail <br> (Rust)| MojoFastqTrim <br> (Mojo🔥)   |
|-------|---------------------|-------------------------|-------------------------------|
| 40k   |      0.57s          |          0.043s         |          0.083s               |
| 5.5M  |      27.1s          |          3.24s          |            3.3s               |
| 12.2M |      58.7s          |          7.3s           |            7.3s               |
| 27.7M |      87.4s          |          12.7s          |           10.1s               | 
| 169.8M|        -            |          100.5s         |           111.8s              |


### FASTQ quality Trimming
|   reads  | Cutadapt <br>  (cython)  | MojoFastqTrim <br> (Mojo🔥)|
|----------|--------------------------|----------------------------|
|    40k   |          0.075s          |           0.65s            |
|   5.5M   |          4.4s            |           5.7s             |
|  12.2M   |          10.1s           |           13.5s            |
|  27.7M   |          20.7s           |           18.6s            |
| 169.8M   |          144.5s          |           192.7s           |



## Personal experience
For me, this was a test of the productivity of Mojo🔥 and its ergnomics at this young age. I was absolutly surprised by how easy it was to write in a few hours a high-performance parser and to implement quality trimming in less 200 lines of code (with some workarounds needed). This can be achieved by an average bioinformatician working with python with minimal needs to change his/her way of thinking, problem approach and with minimal changes to the syntax. I think Mojo🔥 will have a bright future ahead.