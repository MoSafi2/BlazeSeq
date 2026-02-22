"""BlazeSeq parser runner for benchmarking.

Reads a FASTQ file from the given path, counts records and base pairs,
and prints exactly "records base_pairs" on one line for verification
against other parsers.

Usage:
    pixi run mojo run -I . benchmark/fastq-parser/run_blazeseq.mojo <path.fastq>
"""

from sys import argv
from pathlib import Path
from blazeseq.io.readers import FileReader
from blazeseq.parser import FastqParser, ParserConfig

fn main() raises:
    var args = argv()
    if len(args) < 2:
        print("Usage: run_blazeseq.mojo <path.fastq>")
        return

    var file_path = args[1]
    comptime config = ParserConfig(
        check_ascii=False,
        check_quality=False,
        buffer_capacity= 64 * 1024,
        buffer_growth_enabled=False,
    )

    var parser = FastqParser[FileReader, config](FileReader(Path(file_path)))
    var total_reads: Int = 0
    var total_base_pairs: Int = 0
    for record in parser.ref_records():
        total_reads += 1
        total_base_pairs += len(record)


    print(total_reads, total_base_pairs)
