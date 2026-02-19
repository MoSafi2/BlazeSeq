# Changelog

All notable changes to BlazeSeq are documented here.

## [Unreleased]

## [0.2.0] - 2025-02-19

### Added

- **FastqParser** Unified parser that either iterate of Fastq records, record references (zero copy parsing) or batches of records (for GPU-friendly data structure).
- **LineIterator**: New `LineIterator[R, check_ascii]` over a `BufferedReader`.
- **GZFile**: Re-exported from `blazeseq` (from `blazeseq.readers`) for reading gzip-compressed FASTQ. Use `from blazeseq import GZFile` or `from blazeseq.readers import GZFile`.

## [0.1.0]

- **Parsing**: `RecordParser` with compile-time ASCII and quality-schema validation; `BufferedReader`, `FileReader`.
- **Records**: `FastqRecord`, `RecordCoord`; quality schemas (Sanger, Solexa, Illumina, generic).
- **GPU**: `FastqBatch`, `DeviceFastqBatch`; device upload helpers (`upload_batch_to_device`, `fill_subbatch_host_buffers`, `upload_subbatch_from_host_buffers`); quality prefix-sum kernel in `blazeseq.kernels.prefix_sum`.
- **Build**: Mojo package layout; conda/rattler recipe; pixi build and test tasks.
