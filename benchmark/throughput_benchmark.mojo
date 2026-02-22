"""Benchmark: GB/s throughput for batched, records, and ref_records parsing modes.

Generates ~2GB synthetic FASTQ per mode, times only the parse loop, and reports
elapsed seconds and GB/s for each of: parser.batched(), parser.records(), parser.ref_records().
"""

from blazeseq.CONSTS import GB, KB
from blazeseq.utils import generate_synthetic_fastq_buffer, compute_num_reads_for_size
from blazeseq.io.readers import MemoryReader
from blazeseq.parser import FastqParser, ParserConfig
from time import perf_counter_ns

fn main() raises:
    comptime config = ParserConfig(
        check_ascii=False,
        check_quality=False,
        buffer_capacity=64 * KB,
        buffer_growth_enabled=False,
        batch_size=4096,
    )

    var target_size = 3 * GB
    var num_reads = compute_num_reads_for_size(target_size, 100, 100)

    # --- batched ---
    print("Generating ", num_reads, " reads (~", target_size / GB, "GB) for batched...")
    var data_batched = generate_synthetic_fastq_buffer(
        num_reads, 100, 100, 33, 73, "generic"
    )
    var reader_batched = MemoryReader(data_batched^)
    var parser_batched = FastqParser[MemoryReader, config](reader_batched^)
    var total_reads_batched: Int = 0
    var start_ns = perf_counter_ns()
    for batch in parser_batched.batched():
        total_reads_batched += batch.num_records()
    var end_ns = perf_counter_ns()
    var elapsed_batched = Float64(end_ns - start_ns) / 1e9
    var gb_per_s_batched = Float64(target_size) / elapsed_batched / 1e9
    print("batched:    ", elapsed_batched, " s, ", total_reads_batched, " records, ", gb_per_s_batched, " GB/s")

    # --- records ---
    print("Generating ", num_reads, " reads (~", target_size / GB, "GB) for records...")
    var data_records = generate_synthetic_fastq_buffer(
        num_reads, 100, 100, 33, 73, "generic"
    )
    var reader_records = MemoryReader(data_records^)
    var parser_records = FastqParser[MemoryReader, config](reader_records^)
    var total_reads_records: Int = 0
    var total_base_pairs_records: Int = 0
    start_ns = perf_counter_ns()
    for record in parser_records.records():
        total_reads_records += 1
        total_base_pairs_records += len(record)
    end_ns = perf_counter_ns()
    var elapsed_records = Float64(end_ns - start_ns) / 1e9
    var gb_per_s_records = Float64(target_size) / elapsed_records / 1e9
    print("records:    ", elapsed_records, " s, ", total_reads_records, " records, ", gb_per_s_records, " GB/s")

    # --- ref_records ---
    print("Generating ", num_reads, " reads (~", target_size / GB, "GB) for ref_records...")
    var data_ref = generate_synthetic_fastq_buffer(
        num_reads, 100, 100, 33, 73, "generic"
    )
    var reader_ref = MemoryReader(data_ref^)
    var parser_ref = FastqParser[MemoryReader, config](reader_ref^)
    var total_reads_ref: Int = 0
    var total_base_pairs_ref: Int = 0
    start_ns = perf_counter_ns()
    for ref_ in parser_ref.ref_records():
        total_reads_ref += 1
        total_base_pairs_ref += len(ref_)
    end_ns = perf_counter_ns()
    var elapsed_ref = Float64(end_ns - start_ns) / 1e9
    var gb_per_s_ref = Float64(target_size) / elapsed_ref / 1e9
    print("ref_records:", elapsed_ref, " s, ", total_reads_ref, " records, ", gb_per_s_ref, " GB/s")

    # Sanity: all modes should see the same record count
    print("")
    print("Expected records: ", num_reads)
    if total_reads_batched != num_reads or total_reads_records != num_reads or total_reads_ref != num_reads:
        print("WARNING: record count mismatch")
