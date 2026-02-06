# Changelog

All notable changes to BlazeSeq are documented here.

## [0.1.0]

- **Parsing**: `RecordParser` with compile-time ASCII and quality-schema validation; `BufferedReader`, `FileReader`.
- **Records**: `FastqRecord`, `RecordCoord`; quality schemas (Sanger, Solexa, Illumina, generic).
- **GPU**: `FastqBatch`, `DeviceFastqBatch`; device upload helpers (`upload_batch_to_device`, `fill_subbatch_host_buffers`, `upload_subbatch_from_host_buffers`); quality prefix-sum kernel in `blazeseq.kernels.prefix_sum`.
- **Build**: Mojo package layout; conda/rattler recipe; pixi build and test tasks.
