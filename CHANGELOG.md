# Changelog

All notable changes to BlazeSeq are documented here.

## [Unreleased]

### Breaking

- **BufferedReader**: `as_span()` renamed to `view()`. Single view API; `peek(size)` removed—use `view()` and slice. `consume(size)` no longer auto-compacts; callers must call `compact_from(from_pos)` when a line or batch spans the buffer boundary. Buffer never compacts itself (including in `_fill_buffer()`).
- **Parsers**: `RecordParser`, `BatchedParser`, and `RefParser` are removed. A single **`FastqParser`** replaces them. Use `next_ref()`, `next_record()`, or `next_batch()` for direct parsing, and `ref_records()`, `records()`, or `batched()` for iteration (e.g. `for ref in parser.ref_records()`, `for rec in parser.records()`, `for batch in parser.batched()`).

### Added

- **LineIterator**: New `LineIterator[R, check_ascii]` over a `BufferedReader`: `position()`, `next_line()`, `has_more()`, `next_n_lines[n]()`. Line bytes exclude newline; optional trailing `\r` trimmed. Exported from `blazeseq`.
- **LineIterator** now implements the Mojo Iterator protocol; `for line in line_iter` is supported (each `line` is a `Span[Byte, MutExternalOrigin]`, invalidated by the next iteration).

## [0.1.0]

- **Parsing**: `RecordParser` with compile-time ASCII and quality-schema validation; `BufferedReader`, `FileReader`.
- **Records**: `FastqRecord`, `RecordCoord`; quality schemas (Sanger, Solexa, Illumina, generic).
- **GPU**: `FastqBatch`, `DeviceFastqBatch`; device upload helpers (`upload_batch_to_device`, `fill_subbatch_host_buffers`, `upload_subbatch_from_host_buffers`); quality prefix-sum kernel in `blazeseq.kernels.prefix_sum`.
- **Build**: Mojo package layout; conda/rattler recipe; pixi build and test tasks.
