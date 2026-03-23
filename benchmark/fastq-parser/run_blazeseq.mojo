"""BlazeSeq parser runner for benchmarking.

Reads a FASTQ file from the given path, counts records and base pairs,
and prints exactly "records base_pairs" on one line for verification
against other parsers.

Usage:
    pixi run mojo run -I . benchmark/fastq-parser/run_blazeseq.mojo <path.fastq> [scan_mode]

scan_mode:
    fused       (default) - fused inline scanner (_scan_record)
    memchr-seq            - sequential memchr scanner (_scan_record_memchr_seq)
"""

from std.sys import argv
from std.pathlib import Path
from blazeseq.CONSTS import EOF
from blazeseq.io.readers import FileReader
from blazeseq.fastq.parser import FastqParser, ParserConfig

fn main() raises:
    var args = argv()
    if len(args) < 2:
        print("Usage: run_blazeseq.mojo <path.fastq> [scan_mode]")
        return

    var file_path = args[1]
    var scan_mode = String("fused")
    if len(args) >= 3:
        scan_mode = args[2]
    comptime config = ParserConfig(
        check_ascii=False,
        check_quality=False,
        buffer_capacity= 1024 * 64,
        buffer_growth_enabled=False,
    )

    var parser = FastqParser[FileReader, config](FileReader(Path(file_path)))
    var total_reads: Int = 0
    var total_base_pairs: Int = 0
    if scan_mode == "fused":
        for record in parser.views():
            total_reads += 1
            total_base_pairs += len(record)
    elif scan_mode == "memchr-seq":
        while True:
            try:
                var record = parser.next_view_memchr_seq()
                total_reads += 1
                total_base_pairs += len(record)
            except Error:
                var err_str = String(Error)
                if err_str == EOF or err_str.startswith(EOF):
                    break
                raise
    else:
        print("Invalid scan_mode. Expected 'fused' or 'memchr-seq'.")
        return


    print(total_reads, total_base_pairs)
