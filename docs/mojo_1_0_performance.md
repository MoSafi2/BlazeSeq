# Mojo 1.0 performance report

This report records the migration benchmark run on 2026-08-20. No performance
optimizations were made in response to these results.

## Environment and method

- Mojo 1.0.0 (`ed45d567`), Linux x86-64, Intel Core i7-13700K (24 logical CPUs).
- Each task used its documented default size, warmups, and repetitions. File
  benchmarks used `/dev/shm` after an unprivileged `ramfs`/`tmpfs` mount failed.
- CPU governor and turbo controls could not be changed without privileged
  access. Results therefore include normal host-frequency variation.
- Every runner was built and its output was checked before timing. FASTQ runs
  agreed on 14,708,792 records and 1,470,879,200 bases; FASTA runs agreed on
  524,544 records and 1,049,039,843 bases.
- Historical JSON is used where available. Values marked approximate were read
  from the latest matching checked-in plot. Gzip plot comparisons normalize
  the historical 1 GB workload against the current 3 GB workload.

## Results

| Workload | Mojo 1.0 mean | Historical mean | Delta | Notes |
|---|---:|---:|---:|---|
| Plain FASTQ, optimized | 0.496 s | ~0.590 s | -16.0% | 3 GB, 3 warmups, 15 runs; plot baseline |
| FASTQ batches | 0.673 s | 0.843 s | -20.1% | 3 GB, 3 warmups, 15 runs; JSON baseline |
| Gzip FASTQ, requested 4 threads | 11.665 s | ~2.38 s per 1 GB | +63.4% normalized | Current `RapidgzipReader` delegates to `GZFile`; thread count is accepted but ignored |
| Gzip FASTQ, 1 thread | 11.726 s | ~6.45 s per 1 GB | -39.4% normalized | 3 GB current versus 1 GB plot baseline |
| File batches | 0.837 s | ~0.740 s | **+13.0%** | 3 GB, 3 warmups, 15 runs |
| File records | 1.478 s | ~1.390 s | **+6.3%** | 3 GB, 3 warmups, 15 runs |
| File views / historical ref records | 0.616 s | ~0.580 s | **+6.3%** | Public mode name changed |
| Memory batches | 0.778 s | 0.703 s | **+10.6%** | 3 GB, 5 runs; JSON baseline |
| Memory records | 1.376 s | 1.889 s | -27.2% | 3 GB, 5 runs; JSON baseline |
| Memory views / historical ref records | 0.551 s | 0.533 s | +3.4% | 3 GB, 5 runs |
| FASTA | 0.362 s | ~0.510 s | -29.1% | 1 GB, 3 warmups, 15 runs; plot baseline |

Current relative parser ratios were 1.21x versus needletail, 1.14x versus
`seq_io`, and 1.60x versus kseq for plain FASTQ. In the batch comparison,
BlazeSeq was 0.93x as fast as paraseq and 0.97x as fast as the `seq_io`
record-set runner. For FASTA, BlazeSeq was 1.82x slower than needletail and
1.26x faster than noodles.

## Validation matrix

All validation-matrix values are for 3 GB with 3 warmups and 15 repetitions.
The historical values are approximate readings from the checked-in plot.

| Mode | None | ASCII | ASCII + quality |
|---|---:|---:|---:|
| Batches, current | 0.855 s | 0.897 s | 0.962 s |
| Batches, historical | ~0.733 s | ~0.826 s | ~0.853 s |
| Delta | **+16.6%** | **+8.6%** | **+12.8%** |
| Records, current | 1.557 s | 1.699 s | 1.738 s |
| Records, historical | ~1.360 s | ~1.530 s | ~1.560 s |
| Delta | **+14.5%** | **+11.0%** | **+11.4%** |
| Views, current | 0.658 s | 0.753 s | 0.793 s |
| Historical ref records | ~0.595 s | ~0.675 s | ~0.699 s |
| Delta | **+10.7%** | **+11.7%** | **+13.5%** |

## Interpretation and limitations

Every observed slowdown is listed above, with deltas over 5% emphasized. The
large 4-thread gzip regression is not a like-for-like decompressor comparison:
the historical plot used parallel rapidgzip, while the current compatibility
reader uses `GZFile`. The remaining deltas may include Mojo/compiler changes,
host-frequency variation, and the unavailable CPU tuning controls. GPU code was
compiled for NVIDIA `sm_89`, but the NVIDIA driver was unavailable, so no GPU
runtime performance or correctness claim is made.
