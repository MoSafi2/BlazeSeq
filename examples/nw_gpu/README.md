# GPU-Accelerated Needleman–Wunsch GPU Alignment

This example benchmarks a simple **Needleman–Wunsch** global sequence alignment on GPU vs CPU using synthetic FASTQ reads and a fixed reference. It uses only short reference(20bp) and does (multiple vs one) alignment. Also GPU kernels are not optimized to amortize data movement overhead. However, this is a good example of how `BlazeSeq` can simplify the data preperation, movement, and enjoy the GPU-friendly access patterns.

## What it does

- **Synthetic data**: Generates 1 million 20 bp reads in FASTQ format.
- **Reference**: Uses a fixed 20 bp reference sequence (`ACGTACGTACGTACGTACGT`).
- **GPU path**: Uploads batches to the device one at a time, runs one Needleman–Wunsch kernel **per read** (one block per record), writes alignment score per read.
- **CPU path**: Runs the same scoring logic on the host for every record (reference implementation).

## Algorithm (brief)

Needleman–Wunsch performs **global** alignment with dynamic programming:

- **State**: Two rows of length `(ref_len + 1)` (current and previous row).
- **Scores**: Match +1, mismatch -1, gap -1.
- **Result**: Optimal alignment score for each (reference, query) pair.

The GPU kernel assigns one block per read; each block fills its two-row DP table and writes the final score to a per-read output buffer.

## Requirements

- A **compatible Nvidia, AMD, or Apple silicon GPU** Check mojo [list of compatbile GPUs](https://docs.modular.com/max/packages/#gpu-compatibility).

## How to run

From the BlazeSeq repo root:

```bash
pixi run mojo run examples/nw_gpu/main.mojo
```

## Files

| File            | Role |
|-----------------|------|
| `main.mojo`     | Entry point: GPU check, synthetic batch generation, reference setup, GPU/CPU runs, timing and ratio. |
| `execution.mojo`| Batch loading (synthetic), reference upload to device, `run_gpu_nw` / `run_cpu_nw` and timing. |
| `kernels.mojo`  | GPU kernel (`nw_kernel`) and CPU reference (`needleman_wunsch_cpu`), shared constants and layout. |

## Constants

- **Batch size**: 65,536 records per batch.
- **Reference length**: 20 bp (fits in kernel’s `MAX_REF_LEN` / `MAX_QUERY_LEN` of 256).
- **DP scratch**: Two rows of `(MAX_REF_LEN + 1)` `Int32` per record (`ROW_STRIDE`).
