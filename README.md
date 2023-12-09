# MojoFastqTrim 🔥
## Experimental 'FASTQ' parser and quality trimmer written in mojo.


**This is a 'proof-of-principle' FASTQ file format parser and quality trimmer.** <br>

FASTQ parsing and pre-processing is one of the basic steps in bioinformatics. Established tools like 'cutadapt' and 'fastp' are highly optimized and use low-level languages like C, C++, and Cython for performance. <br>

'MojoFastTrim' achieves 4x performance in FASTQ parsing mojo compared to 'SeqIO' imeplentation and for quality trimming it is with in 50% of 'cutadpt' impelmentation for small read counts and achieves similair performance in large files.

'MojoFastTrim' This is written similair to normal python code but using 'struct' instead of 'class' and using variable types. There is a lot of room form improvement using mojo including optimized I/O, using SIMD quality windows instead of rolling sums, and multi-core parallerism to eke-out everybit of performance. <br>

## Fastq parsing
| File  | SeqIO | Needletail (Rust)  | MojoFastqTrim |
|-------|-------|--------------------|---------------|
| 40k   | 0.57s || 0.099s|
| 5.5M  | 27.1s || 3.3s |
| 12.2M | 58.7s || 7.7s |
| 27.7M | 87.4s || 10.4s |
| 169.8M|   -   || 123.4s |


## Fastq quality Trimming
| no_reads | Cutadapt  | MojoFastqTrim|
|----------|-----------|--------------|
|    40k   |    0.075s |     0.65s    |
|   5.5M   |    4.4s   |     5.9s     |
|  12.2M   |    10s    |     15.1s    |
|  27.7M   |    20.7s  |     20.5s    |
| 169.8M   |    144.5s |     218.5s   |

```
This is cutadapt 4.6 with Python 3.10.13
Command line parameters: ./data/SRR16012060.fastq -q 28,28 -j 1 --report full
Processing single-end reads on 1 core ...
Done           00:00:09    12,280,830 reads @   0.8 µs/read;  74.14 M reads/minute
Finished in 9.939 s (0.809 µs/read; 74.13 M reads/minute).

=== Summary ===

Total reads processed:              12,280,830
Reads written (passing filters):    12,280,830 (100.0%)

Total basepairs processed: 1,240,363,830 bp
Quality-trimmed:              43,679,326 bp (3.5%)
Total written (filtered):  1,196,684,504 bp (96.5%)
```


Mojo
```
15.028657S spend in parsing 12,280,830 records. 
euqaling 1.223749 microseconds/read or 49,026,660 reads/second
```