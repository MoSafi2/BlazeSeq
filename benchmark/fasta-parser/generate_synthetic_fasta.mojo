"""Generate synthetic FASTA to a file for benchmarking.

Writes a 1 GB (default) synthetic FASTA file with multiline sequences,
average ~2000 bases per record, and a wide length distribution (200–3800 bp).
Used by run_benchmarks.sh so the file can be placed on a tmpfs/ramfs mount.

Usage:
    pixi run mojo run -I . benchmark/fasta-parser/generate_synthetic_fasta.mojo <output_path> [size_gb]
    size_gb defaults to 1.
"""

from std.sys import argv
from std.pathlib import Path
from blazeseq.CONSTS import GB
from blazeseq.utils import (
    generate_synthetic_fasta_buffer,
    compute_num_fasta_reads_for_size,
)
from blazeseq.io.buffered import buffered_writer_for_file


fn main() raises:
    var args = argv()
    if len(args) < 2:
        print("Usage: generate_synthetic_fasta.mojo <output_path> [size_gb]")
        return

    var output_path = args[1]
    var size_gb: Int = 1
    if len(args) >= 3:
        size_gb = atol(args[2])
    if size_gb <= 0:
        print("size_gb must be positive")
        return

    # avg 2000 bp/record, wide distribution (19x range: 200–3800)
    comptime MIN_LEN = 200
    comptime MAX_LEN = 3800
    comptime LINE_WIDTH = 60

    var target_size = size_gb * GB
    var num_reads = compute_num_fasta_reads_for_size(
        target_size, MIN_LEN, MAX_LEN, LINE_WIDTH
    )
    print(
        "Generating",
        num_reads,
        "records (~",
        size_gb,
        "GB, avg 2000 bp, line_width=60)...",
    )
    var data = generate_synthetic_fasta_buffer(
        num_reads, MIN_LEN, MAX_LEN, LINE_WIDTH
    )
    print("Buffer size:", len(data), "bytes")

    var writer = buffered_writer_for_file(
        Path(output_path), capacity=4 * 1024 * 1024
    )
    writer.write_bytes(data)
    writer.flush()
    print("Wrote", output_path)
