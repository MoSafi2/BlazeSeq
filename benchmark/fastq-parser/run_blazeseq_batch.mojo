"""BlazeSeq FASTQ batch runner for benchmarking.

Iterates over `FastqParser.batches(batch_size)` and computes:
- total_reads: total number of FASTQ records
- total_base_pairs: sum of sequence lengths (bases) across all records

Prints exactly: `records base_pairs`

Usage:
    pixi run mojo run -I . benchmark/fastq-parser/run_blazeseq_batch.mojo <path.fastq> [batch_size]
"""

from std.sys import argv
from std.pathlib import Path

from blazeseq.io.readers import FileReader
from blazeseq.fastq.parser import FastqParser, ParserConfig
from blazeseq.CONSTS import KB


def main() raises:
    var args = argv()
    if len(args) < 2:
        print("Usage: run_blazeseq_batch.mojo <path.fastq> [batch_size]")
        return

    var file_path = args[1]
    var batch_size: Int = 4096
    if len(args) >= 3:
        batch_size = atol(args[2])
        if batch_size <= 0:
            print("batch_size must be positive")
            return

    comptime config = ParserConfig(
        check_ascii=False,
        check_quality=False,
        buffer_capacity=64 * KB,
        buffer_growth_enabled=False,
    )

    var parser = FastqParser[FileReader, config](FileReader(Path(file_path)))

    var total_reads: Int = 0
    var total_base_pairs: Int = 0
    for batch in parser.batches(batch_size):
        total_reads += batch.num_records()
        total_base_pairs += batch.seq_len()

    print(total_reads, total_base_pairs)

