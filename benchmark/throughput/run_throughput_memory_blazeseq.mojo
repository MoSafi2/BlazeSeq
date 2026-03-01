"""BlazeSeq in-memory throughput runner: generate ~3 GB FASTQ, keep in process, parse via MemoryReader.

Generates synthetic FASTQ in memory (no disk I/O), wraps the buffer in MemoryReader,
runs the chosen iteration mode (batches / records / ref_records), and prints
"records base_pairs" on one line for verification. Used with hyperfine for
throughput benchmarking without file I/O.

Usage:
    pixi run mojo run -I . benchmark/throughput/run_throughput_memory_blazeseq.mojo [size_gb] <mode>
    size_gb: optional, default 3 (target size in GB).
    mode: batches | records | ref_records
"""

from sys import argv
from time import perf_counter_ns
from blazeseq.CONSTS import KB, GB
from blazeseq.io.readers import MemoryReader
from blazeseq.parser import FastqParser, ParserConfig
from blazeseq.utils import generate_synthetic_fastq_buffer, compute_num_reads_for_size

fn main() raises:
    var args = argv()
    if len(args) < 2:
        print("Usage: run_throughput_memory_blazeseq.mojo [size_gb] <mode>")
        print("  size_gb: optional (default 3), target FASTQ size in GB")
        print("  mode: batches | records | ref_records")
        return

    var size_gb: Int = 3
    var mode: String
    if len(args) == 2:
        mode = args[1]
    else:
        size_gb = atol(args[1])
        mode = args[2]
        if size_gb <= 0:
            print("size_gb must be positive")
            return

    var target_size = size_gb * GB
    var num_reads = compute_num_reads_for_size(target_size, 100, 100)
    var data = generate_synthetic_fastq_buffer(
        num_reads, 100, 100, 33, 73, "generic"
    )

    comptime config = ParserConfig(
        check_ascii=False,
        check_quality=False,
        buffer_capacity=64 * KB,
        buffer_growth_enabled=False,
    )

    var buffer_bytes = len(data)
    var reader = MemoryReader(data^)
    var parser = FastqParser[MemoryReader, config](reader^)
    var total_reads: Int = 0
    var total_base_pairs: Int = 0

    var start_ns = perf_counter_ns()
    if mode == "batches":
        for batch in parser.batches(4096):
            total_reads += batch.num_records()
            total_base_pairs += batch.seq_len()
    elif mode == "records":
        for record in parser.records():
            total_reads += 1
            total_base_pairs += len(record)
    elif mode == "ref_records":
        for ref_ in parser.ref_records():
            total_reads += 1
            total_base_pairs += len(ref_)
    else:
        print("Unknown mode: ", mode, ". Use batches | records | ref_records")
        return
    var end_ns = perf_counter_ns()

    var elapsed_ns = end_ns - start_ns
    var elapsed_s = Float64(elapsed_ns) / 1e9
    var gbps = Float64(buffer_bytes) / (1024 * 1024 * 1024) / elapsed_s

    print(total_reads, total_base_pairs)
    print("parse_seconds:", elapsed_s)
    print("throughput_gbps:", gbps)
