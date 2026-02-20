# BlazeSeq — Documentation & project TODOs

## Features

- [ ] Add paired-end reads support
- [ ] Add Fasta parser based on the existing infrastructure.
- [ ] Add more usage example for GPU Ops, QC, Kmer finding
- [ ] Add more backends for compressed files reading and writing (blocked zip; multi-threaded decompression using rapid-gzip).

## Testing & CI

- [ ] Add a CI job to build and optionally deploy the docs site (e.g. on push to `main`).
- [ ] Document how to run benchmarks and add results to `data/performance.md` (or link from README).

## Documentation

- [ ] Add a short "User guide" or "Tutorial" section to the docs site (beyond Quick Start).
- [ ] Enhance readme.md to be more sharp and engaging.
- [ ] Document multi-line FASTQ as unsupported in the main docs (README mentions it; docs site should too).
- [ ] Add a "Troubleshooting" or FAQ page (common errors, validation vs speed, GPU requirements).
- [ ] Cross-link README examples to the corresponding API docs (e.g. `FastqParser`, `ParserConfig`).
- [ ] Enhance generate docs.
- [ ] Maintain good versioning
