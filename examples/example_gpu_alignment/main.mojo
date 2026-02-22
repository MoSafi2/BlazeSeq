"""Entry point: GPU vs CPU Needleman-Wunsch on whole file with timing.

Processes the whole input file (or 1M synthetic reads if no file). Reference is 20 bp.
Reports GPU time, CPU time, and acceleration ratio.

Usage (from repo root):
    pixi run mojo run -I . examples/device_nw/main.mojo [path/to/file.fastq]

Without a file path, generates 1 million 20 bp reads and processes them.
Requires a compatible GPU.
"""

from sys import has_accelerator, argv, exit
from pathlib import Path
from blazeseq import FastqBatch
from gpu.host import DeviceContext

from execution import (
    load_batches_from_file,
    load_batches_synthetic,
    setup_reference,
    run_gpu_nw,
    run_cpu_nw,
    total_record_count,
    REF_20BP,
)


fn main() raises:
    @parameter
    if not has_accelerator():
        print("No GPU detected. This example requires a compatible GPU.")
        exit(1)

    var args = argv()
    var batches: List[FastqBatch]
    var ref_str = REF_20BP

    if len(args) >= 2:
        var file_path = args[1]
        var path = Path(file_path)
        if not path.exists():
            print("File not found: ", file_path)
            exit(1)
        batches = load_batches_from_file(path)
        print("Read file: ", file_path)
    else:
        print("No file provided; generating 1 million 20 bp reads...")
        batches = load_batches_synthetic(1_000_000, 20)
        print("Generated 1M reads (20 bp each).")

    var total = total_record_count(batches)
    print("Total records: ", total)
    print("Reference (20 bp): ", ref_str)

    var ctx = DeviceContext()
    var (ref_tensor, ref_len) = setup_reference(ctx, ref_str)

    var gpu_sec = run_gpu_nw(batches, ref_tensor, ref_len, ctx)
    var cpu_sec = run_cpu_nw(batches, ref_str)

    print("")
    print("GPU time:  ", gpu_sec, " s")
    print("CPU time:  ", cpu_sec, " s")
    print("Acceleration ratio (CPU/GPU): ", cpu_sec / gpu_sec, "x")
