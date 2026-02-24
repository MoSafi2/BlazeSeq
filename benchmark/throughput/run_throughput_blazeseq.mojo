"""BlazeSeq throughput runner: one of batched / records / ref_records on a FASTQ file.

Reads a FASTQ file from the given path, runs the chosen iteration mode,
and prints "records base_pairs" on one line for verification. Used by
run_throughput_benchmarks.sh with hyperfine.

Usage:
    pixi run mojo run -I . benchmark/run_throughput_blazeseq.mojo <path.fastq> <mode>
    mode: batched | records | ref_records
"""

from sys import argv
from pathlib import Path
from blazeseq.CONSTS import KB
from blazeseq.io.readers import FileReader
from blazeseq.parser import FastqParser, ParserConfig

fn main() raises:
    var args = argv()
    if len(args) < 3:
        print("Usage: run_throughput_blazeseq.mojo <path.fastq> <mode>")
        print("  mode: batched | records | ref_records")
        return

    var file_path = args[1]
    var mode = args[2]

    comptime config = ParserConfig(
        check_ascii=False,
        check_quality=False,
        buffer_capacity=64 * KB,
        buffer_growth_enabled=False,
    )

    var parser = FastqParser[FileReader, config](FileReader(Path(file_path)))
    var total_reads: Int = 0
    var total_base_pairs: Int = 0

    if mode == "batched":
        for batch in parser.batched(4096):
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
        print("Unknown mode: ", mode, ". Use batched | records | ref_records")
        return

    print(total_reads, total_base_pairs)
