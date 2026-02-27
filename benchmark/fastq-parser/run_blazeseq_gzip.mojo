"""BlazeSeq gzip parser runner for benchmarking.

Reads a gzip-compressed FASTQ file (.fastq.gz) from the given path using
RapidgzipReader, counts records and base pairs, and prints exactly
"records base_pairs" on one line for verification against other parsers.

Usage:
    pixi run mojo run -I . benchmark/fastq-parser/run_blazeseq_gzip.mojo <path.fastq.gz>
"""

from sys import argv
from pathlib import Path
from blazeseq.io.readers import RapidgzipReader
from blazeseq.parser import FastqParser, ParserConfig

fn main() raises:
    var args = argv()
    if len(args) < 2:
        print("Usage: run_blazeseq_gzip.mojo <path.fastq.gz> [parallelism]")
        print("  parallelism: 0 = auto (default), 1 = single-threaded decompression.")
        return

    var file_path = args[1]
    var parallelism: UInt32 = 0
    if len(args) >= 3:
        parallelism = UInt32(atol(args[2]) )

    comptime config = ParserConfig(
        check_ascii=False,
        check_quality=False,
        buffer_capacity= 1024 * 1024,
        buffer_growth_enabled=False,
    )

    var parser = FastqParser[RapidgzipReader, config](RapidgzipReader(file_path, parallelism=parallelism))
    var total_reads: Int = 0
    var total_base_pairs: Int = 0
    for record in parser.ref_records():
        total_reads += 1
        total_base_pairs += len(record)


    print(total_reads, total_base_pairs)
