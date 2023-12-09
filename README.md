# MojoFastqTrim🔥
## Experimental 'FASTQ' parser and quality trimmer written in mojo.


**This is a 'proof-of-principle' FASTQ file format parser and quality trimmer.** <br>

 **MojoFastTrim🔥** is ***8x*** faster than **SeqIO** and achieves similair performance to  rust's **Needletail** in FASTQ parsing. 
 <br> it is on overage within 70% of industry-standard **cutadpt** performancefor FASTQ quality trimming prior to any optimization.

**MojoFastTrim🔥**  is similair to average python code but using ***struct*** instead of ***class*** and using variable types. <br> There is a lot of room form improvement offered by mojo modern featues including optimized I/O, using SIMD quality windows instead of rolling sums, and  parallerism for record trimming to achieve everybit of performance. <br>

# Benchmarking

**MojoFastTrim🔥** was benchmarked in two tasks:
* FASTQ record parsing 
* FASTQ quality trimming of both 3´ and 5´ ends.


FASTQ parsing was done according to [Biofast benchmark](https://github.com/lh3/biofast/tree/) for **SeqIO** (Biopython), the rust parser **Needletail** and **MojoFastTrim🔥**
FASTQ trimming 

## Datasets




## FASTQ parsing
| reads   | SeqIO <br> (python) | Needletail <br> (Rust)| MojoFastqTrim <br> (mojo🔥)   |
|-------|---------------------|-------------------------|-------------------------------|
| 40k   |      0.57s          |          0.043s         |          0.099s               |
| 5.5M  |      27.1s          |          3.24s          |            3.3s               |
| 12.2M |      58.7s          |          7.3s           |            7.7s               |
| 27.7M |      87.4s          |          12.7s          |           10.4s               | 
| 169.8M|        -            |          100.5s         |           116.8s              |


## FASTQ quality Trimming
|   reads  | Cutadapt <br>  (cython)  | MojoFastqTrim <br> (mojo🔥)|
|----------|--------------------------|----------------------------|
|    40k   |          0.075s          |           0.65s            |
|   5.5M   |          4.4s            |           5.9s             |
|  12.2M   |          10s             |           15.1s            |
|  27.7M   |          20.7s           |           20.5s            |
| 169.8M   |          144.5s          |           218.5s           |


