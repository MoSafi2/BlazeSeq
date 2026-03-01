# FASTQ Parser Benchmarking

Benchmarking documentation has been consolidated into the main benchmark README.

**See [../README.md](../README.md)** for:

- BlazeSeq-only throughput (file-based and in-memory)
- Parser comparison: plain FASTQ (BlazeSeq vs needletail, seq_io, kseq)
- Parser comparison: gzip FASTQ (single- and multi-threaded)
- Prerequisites, tmpfs/ramfs methodology, CPU environment (Linux), plotting, and interpreting results

Quick commands: `pixi run -e benchmark benchmark-plain`, `benchmark-gzip`, `benchmark-gzip-single`, `benchmark-throughput`, `benchmark-throughput-memory`, `benchmark-plot`.
