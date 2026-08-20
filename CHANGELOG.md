# Changelog

All notable changes to BlazeSeq are documented here.

## [Unreleased]

### Added

- **Optional GPU package**: Added the MAX-backed `blazeseq_gpu` package and `gpu` Pixi environment. Device/staged batches and upload/download helpers moved out of the MAX-free core.
- **Public BED/GTF/GFF exports**: Added stable `blazeseq.bed`, `blazeseq.gff`, and `blazeseq.gtf` package shims plus top-level re-exports so examples, docs, and tests can import the published parser and record types consistently.
- **Scanner benchmark modes**: Added explicit FASTQ scanner benchmark variants for the optimized grouped SIMD loop, the original fused SIMD loop, and sequential `memchr` scanning.

### Changed

- **Mojo 1.0 final upgrade**: Migrated source, tests, examples, benchmarks, and Python bindings to Mojo 1.0.0 APIs while keeping manifest compatibility at `>=1.0.0,<2`.
- **Precompiled packaging**: Replaced `.mojopkg`/`mojo package` with `.mojoc`/`mojo precompile`. Python's new `mojoc_path()` is preferred; `mojopkg_path()` remains a compatibility alias returning the same directory.
- **GPU API migration**: `FastqBatch.to_device()` and `.stage()` were removed. Import `upload_batch_to_device()` and related types from `blazeseq_gpu`.
- **Rapidgzip compatibility fallback**: Temporarily disabled the external `rapidgzip` dependency while preserving the `RapidgzipReader` API by delegating gzip reads through `GZFile`.
- **Docs and packaging**: Updated README, docs, Python wheel data, and recipes for Mojo 1.0 final and optional MAX installation.
- **Mojo 1.0 performance**: Recorded the complete migration benchmark matrix in `docs/mojo_1_0_performance.md`. Regressions over 5% include file batching/record/view modes, most validation combinations, in-memory batching, and the non-parallel gzip compatibility path.

### Fixed

- **Benchmark verification**: Plain and gzip benchmark runners now build and execute successfully against the bundled FASTQ fixtures, and the outer FASTQ benchmark harness validates all BlazeSeq scan modes.
- **Mojo 1.0 warnings**: Cleaned up the main package build warnings around `String.__len__()`, docstring summaries, and pointer lifecycle/nullability handling in the buffered and gzip I/O layers.
- **Mojo 1.0 syntax cleanup**: Updated remaining tests and examples to current `String`/byte APIs, fixed FASTQ batch code that relied on negative indexing, and removed reproducible compiler warnings from representative parser test targets.

## [0.3] - 2026-03-30

### Added

- **FASTA support**: `FastaRecord` and `FastaParser` in `blazeseq.fasta` with definition-line parsing, optional description, and `definition()` method. Strip leading/trailing spaces from definition lines.
- **FAI index parser**: `FaiRecord` and `FaiParser` in `blazeseq.fai` for streaming parsing of FASTA/FASTQ `.fai` index files (5-column FASTA and 6-column FASTQ formats), plus a `collect()` helper to load whole indexes into memory and tests based on the samtools `faidx` examples. Zero-copy access via `FaiView` and `views()` / `next_view()`.

- **Definition struct**: `Definition` in `blazeseq.fasta.definition` with `Id` and optional `Description`; `definition()` on `FastaRecord` and `FastqRef` for structured definition-line parsing.
- **FASTA validation**: Optional ASCII validation for id and sequence via `ParserConfig.check_ascii`.
- **FASTA writing**: Multi-line FASTA writing with configurable line breaks; round-trip testing for FASTA.
- **Correctness test suite**: 140 FASTQ tests from BioPython/BioJava/BioPerl test data in `tests/test_data/fastq_parser/`; coverage for `views()` and `records()` on valid/invalid files, including gzip/bgzip (example.fastq.gz, example_dos.fastq.bgz, etc.).
- **Error context**: Parse and validation errors now include record number, line number, file position, and a snippet of the failing record when using `next_record()` or iterators.
- **Throughput validation benchmark**: `run_throughput_validation_blazeseq.mojo` and scripts to measure effect of ASCII/quality validation on throughput.
- **FASTA benchmarks**: Benchmark harness for FASTA parser with Noodles and needletail runners; plotting script for benchmark results.
- **Delimited parser**: Streaming delimited-line parser in `blazeseq.io.delimited` with minimal allocation; stack-allocated `FieldOffsets`, zero-copy field access, and policy based parsing.
- **BED & GTF & GFF parsing**: Initial record types and streaming parser in `blazeseq._*`

### Changed

- **Mojo 26.2**: Upgrade to Mojo 0.26.2.
- **Record API**: `sequence()`, `id()`, and `quality()` on `FastqRecord` and `FastqView` now return `StringSlice` for zero-copy access.
- **ByteString → BString**: Renamed for brevity.
- **Benchmarks**: Use tmpfs by default (instead of ramfs); pixi benchmark tasks no longer pass `--ramfs`; fallback to `/dev/shm` when mount fails.
- **Test layout**: Test directory structure reorganized into `tests/io/` and `tests/fastq/`.
- **Error internals**: Methods used for error message creation (e.g. file position, line number) made private.

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
- **FastqParser** unified API with three iterators: `views()`, `records()`, `batches()`; zero-copy via `next_view()` / `views()`.
- **Writers**: `BufferWriter` and writer system; test cleanup helpers.
- **Benchmarking**: Benchmark subdir and tools (e.g. ref_reader, throughput).
- **Docs**: Astro-based docs and GitHub Actions deploy.
- **LineIterator** over `BufferedReader`; GZFile re-export from `blazeseq`.
- **Testing** Added unit-tests and round-trip integration for plain and gziped files.

### Changed

- **Records**: Removed `plus_line`. Renamed `header` → `id`, `header_slice()` → `id()`; validator `header_snippet()` → `id_snippet()`. Batch/device use `id_buffer` / `id_ends`.
- **ByteString** replaced by ASCII string type; string-like API, less vector-like.
- **BatchedParser**: Parse-then-copy FastqViews; parametric mutability and origin tracking for FastqView from FastqBatch.
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
