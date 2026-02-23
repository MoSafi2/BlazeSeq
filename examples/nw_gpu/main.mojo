"""Entry point: GPU vs CPU Needleman-Wunsch with synthetic data.

This module is the main script for the needlemann-wunsh_gpu_alignment example.
It generates synthetic FASTQ reads (no input file), runs Needleman-Wunsch
global alignment on both GPU and CPU with the same reference, and reports
timing and acceleration ratio.

Flow:
  1. Check that a GPU is available; exit otherwise.
  2. Generate 1M synthetic 20 bp reads and parse them into FastqBatches.
  3. Upload the fixed 20 bp reference to the device.
  4. Run GPU NW on all batches (one kernel block per read), then CPU NW.
  5. Print GPU time, CPU time, and CPU/GPU ratio.

Usage (from repo root):
    pixi run mojo run -I . examples/needlemann-wunsh_gpu_alignment/main.mojo

Requires a compatible GPU.
"""

from sys import has_accelerator, exit
from blazeseq import FastqBatch
from gpu.host import DeviceContext

from examples.nw_gpu.execution import (
    load_batches_synthetic,
    setup_reference,
    run_gpu_nw,
    run_cpu_nw,
    scores_match,
    total_record_count,
    REF_40BP,
)


fn main() raises:
    # Require an accelerator; this example is for GPU benchmarking.
    @parameter
    if not has_accelerator():
        print("No GPU detected. This example requires a compatible GPU.")
        exit(1)

    # Generate synthetic data only (no file I/O). 1M reads, 20 bp each.
    print("Generating 1 million 40 bp synthetic reads...")
    var batches = load_batches_synthetic(1_000_000, 40)
    print("Generated 1M reads (40 bp each).")

    var total = total_record_count(batches)
    print("Total records: ", total)
    print("Reference (40 bp): ", REF_40BP)

    # Upload reference to device and get tensor + length for kernel calls.
    var ctx = DeviceContext()
    var (ref_tensor, ref_len) = setup_reference(ctx, REF_40BP)

    # Run both backends and measure wall-clock time; collect scores for validation.
    var gpu_result = run_gpu_nw(batches, ref_tensor, ref_len, ctx)
    var gpu_sec = gpu_result[0]
    var gpu_scores = gpu_result[1].copy()

    var cpu_result = run_cpu_nw(batches, REF_40BP)
    var cpu_sec = cpu_result[0]
    var cpu_scores = cpu_result[1].copy()

    print("GPU scores: ", gpu_scores[1:10].__str__())
    print("CPU scores: ", cpu_scores[1:10].__str__())
    print("")
    print("GPU time:  ", gpu_sec, " s")
    print("CPU time:  ", cpu_sec, " s")
    print("Acceleration ratio (CPU/GPU): ", cpu_sec / gpu_sec, "x")

    # Validate that GPU and CPU produce the same alignment scores.
    var match_result = scores_match(gpu_scores, cpu_scores)
    var match_result_bool: Bool = match_result[0]
    var mismatch_idx = match_result[1]
    if match_result_bool:
        print("Validation: GPU and CPU results match (", len(gpu_scores), " scores).")
    else:
        if mismatch_idx == -1:
            print("Validation FAILED: length mismatch (GPU: ", len(gpu_scores), ", CPU: ", len(cpu_scores), ")")
        else:
            print("Validation FAILED: first mismatch at record index ", mismatch_idx)
            print("  GPU score: ", gpu_scores[mismatch_idx], ", CPU score: ", cpu_scores[mismatch_idx])
        exit(1)
