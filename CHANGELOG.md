# Changelog

All notable changes to BlazeSeq are documented here.

## [Unreleased]

## [0.3] - 2026-03-06

### Added

- **FASTA support**: `FastaRecord` and `FastaParser` in `blazeseq.fasta` with definition-line parsing, optional description, and `definition()` method. Strip leading/trailing spaces from definition lines.
- **Correctness test suite**: 140 FASTQ tests from BioPython/BioJava/BioPerl test data in `tests/test_data/fastq_parser/`; coverage for `ref_records()` and `records()` on valid/invalid files, including gzip/bgzip (example.fastq.gz, example_dos.fastq.bgz, etc.).
- **Error context**: Parse and validation errors now include record number, line number, file position, and a snippet of the failing record when using `next_record()` or iterators.
- **Throughput validation benchmark**: `run_throughput_validation_blazeseq.mojo` and scripts to measure effect of ASCII/quality validation on throughput.
- **FASTA benchmarks**: Benchmark harness for FASTA parser with Noodles and needletail runners; plotting script for benchmark results.

## [0.2] - 2026-02-23

### Added

- **RapidgzipReader** integration with [Rapidgzip](https://github.com/mxmlnkn/rapidgzip) C++ library for parallelized gzip decompression. Results in up to 5x speedup in parsing of gzipped files compared to GZFile.

  ```mojo
  from blazeseq import RapidgzipReader, FastqParser
  var reader = RapidgzipReader("data.fastq.gz")
  var parser = FastqParser[RapidgzipReader](reader^, "generic")
  for record in parser.records():
      _ = record.id()
  ```
  
- **Compressed (gzip) FASTQ benchmark**  benchmark comparing BlazeSeq (RapidgzipReader) and needletail on a 3 GB synthetic FASTQ compressed to `.fastq.gz`. Run with `pixi run -e benchmark benchmark-gzip`.
- **FastqParser** unified API with three iterators: `ref_records()`, `records()`, `batches()`; zero-copy via `next_ref()` / `ref_records()`.
- **Writers**: `BufferWriter` and writer system; test cleanup helpers.
- **Benchmarking**: Benchmark subdir and tools (e.g. ref_reader, throughput).
- **Docs**: Astro-based docs and GitHub Actions deploy.
- **LineIterator** over `BufferedReader`; GZFile re-export from `blazeseq`.
- **Testing** Added unit-tests and round-trip integration for plain and gziped files.

### Changed

- **Records**: Removed `plus_line`. Renamed `header` → `id`, `header_slice()` → `id()`; validator `header_snippet()` → `id_snippet()`. Batch/device use `id_buffer` / `id_ends`.
- **ByteString** replaced by ASCII string type; string-like API, less vector-like.
- **BatchedParser**: Parse-then-copy RefRecords; parametric mutability and origin tracking for RefRecord from FastqBatch.
- **MemoryReader** performance improvements; `BufferedReader` `__del__` enabled.
- Custom error types; CI: restrict tests to main, disable GPU tests in GHA.

### Fixed

- EOF handling in batched parser; incomplete-line and buffer-growth paths.

---

## [0.1] - 2026-02-16

### Added

- **GPU path**: GPU-compatible record; `FastqBatch`, `DeviceFastqBatch`; device upload helpers; quality prefix-sum kernel; `quality_distribution` example.
- **Batched parser** and batched iterator; `GpuPayload` enum-like struct.
- **Iterator** for `RecordParser`; `FastqRecord` uses OFFSET for quality schema.
- **Validation**: ASCII validation moved from readers into FASTQ validator (compile-time toggles).
- **Build**: Mojo 0.26.1; pixi build/test; conda/rattler recipe.

### Changed

- **new_iostream** merged (PR #12); `BufferedReader` / reorganized I/O.
- **FastqRecord** uses `ByteString`; multi-line support; `ParserConfig`; validator hoisted to own struct.

### Fixed

- Tests and formatting for device record, get_record, validator.
