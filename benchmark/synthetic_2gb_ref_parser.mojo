"""Benchmark: generate ~2GB of synthetic FASTQ in memory, parse with RefParser, report time."""

from blazeseq.CONSTS import GB
from blazeseq.utils import generate_synthetic_fastq_buffer, compute_num_reads_for_size
from blazeseq.readers import MemoryReader
from blazeseq.parser import RefParser, ParserConfig
from time import perf_counter_ns

# NOTE: The results of this benchmark does not make any sense, there is a lot of unexplained overhead compared to reading from disk.
fn main() raises:
    comptime config = ParserConfig(
        check_ascii=False,
        check_quality=False,
        buffer_capacity=64 * 1024,
        buffer_growth_enabled=False,
    )

    var target_size = 2 * GB
    var num_reads = compute_num_reads_for_size(target_size, 100, 100)
    print("Generating ", num_reads, " reads (~2GB)...")
    var data = generate_synthetic_fastq_buffer(
        num_reads, 100, 100, 33, 73, "generic"
    )
    print("Buffer size: ", len(data), " bytes")

    var reader = MemoryReader(data^)
    var parser = RefParser[MemoryReader, config](reader^)

    var total_reads: Int = 0
    var total_base_pairs: Int = 0

    var start_ns = perf_counter_ns()
    for record in parser:
        total_reads += 1
        total_base_pairs += len(record)
    var end_ns = perf_counter_ns()

    var elapsed_secs = Float64(end_ns - start_ns) / 1e9
    print("Parsing time: ", elapsed_secs, " s")
    print("Records: ", total_reads, " (expected ", num_reads, ")")
    print("Base pairs: ", total_base_pairs)
    print("GB/s: ", target_size / elapsed_secs / 1e9)
