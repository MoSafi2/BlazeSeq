"""BlazeSeq throughput runner with validation regimes.

Reads a FASTQ file from the given path, runs the chosen iteration mode and
validation regime, then prints "records base_pairs" on one line for
verification. Used by run_throughput_validation_benchmarks.sh with hyperfine.

Usage:
    pixi run mojo run -I . benchmark/throughput/run_throughput_validation_blazeseq.mojo <path.fastq> <mode> <validation>
    mode: batches | records | views
    validation: none | ascii | ascii_quality
"""

from std.sys import argv
from std.pathlib import Path
from blazeseq.CONSTS import KB
from blazeseq.io.readers import FileReader
from blazeseq.fastq.parser import FastqParser, ParserConfig


def run_mode_none(path: String, mode: String) raises -> Tuple[Int, Int]:
    comptime config = ParserConfig(
        check_ascii=False,
        check_quality=False,
        buffer_capacity=64 * KB,
        buffer_growth_enabled=False,
    )
    var parser = FastqParser[FileReader, config](FileReader(Path(path)))
    var total_reads: Int = 0
    var total_base_pairs: Int = 0

    if mode == "batches":
        for batch in parser.batches(4096):
            total_reads += batch.num_records()
            total_base_pairs += batch.seq_len()
    elif mode == "records":
        for record in parser.records():
            total_reads += 1
            total_base_pairs += len(record)
    elif mode == "views":
        for view in parser.views():
            total_reads += 1
            total_base_pairs += len(view)
    else:
        raise Error("Unknown mode: " + mode + ". Use batches | records | views")
    return (total_reads, total_base_pairs)


def run_mode_ascii(path: String, mode: String) raises -> Tuple[Int, Int]:
    comptime config = ParserConfig(
        check_ascii=True,
        check_quality=False,
        buffer_capacity=64 * KB,
        buffer_growth_enabled=False,
    )
    var parser = FastqParser[FileReader, config](FileReader(Path(path)))
    var total_reads: Int = 0
    var total_base_pairs: Int = 0

    if mode == "batches":
        for batch in parser.batches(4096):
            total_reads += batch.num_records()
            total_base_pairs += batch.seq_len()
    elif mode == "records":
        for record in parser.records():
            total_reads += 1
            total_base_pairs += len(record)
    elif mode == "views":
        for view in parser.views():
            total_reads += 1
            total_base_pairs += len(view)
    else:
        raise Error("Unknown mode: " + mode + ". Use batches | records | views")
    return (total_reads, total_base_pairs)


def run_mode_ascii_quality(path: String, mode: String) raises -> Tuple[Int, Int]:
    comptime config = ParserConfig(
        check_ascii=True,
        check_quality=True,
        quality_schema="generic",
        buffer_capacity=64 * KB,
        buffer_growth_enabled=False,
    )
    var parser = FastqParser[FileReader, config](FileReader(Path(path)))
    var total_reads: Int = 0
    var total_base_pairs: Int = 0

    if mode == "batches":
        for batch in parser.batches(4096):
            total_reads += batch.num_records()
            total_base_pairs += batch.seq_len()
    elif mode == "records":
        for record in parser.records():
            total_reads += 1
            total_base_pairs += len(record)
    elif mode == "views":
        for view in parser.views():
            total_reads += 1
            total_base_pairs += len(view)
    else:
        raise Error("Unknown mode: " + mode + ". Use batches | records | views")
    return (total_reads, total_base_pairs)


def main() raises:
    var args = argv()
    if len(args) < 4:
        print(
            "Usage: run_throughput_validation_blazeseq.mojo <path.fastq> <mode> <validation>"
        )
        print("  mode: batches | records | views")
        print("  validation: none | ascii | ascii_quality")
        return

    var file_path = args[1]
    var mode = args[2]
    var validation = args[3]
    var total_reads: Int
    var total_base_pairs: Int

    if validation == "none":
        total_reads, total_base_pairs = run_mode_none(file_path, mode)
    elif validation == "ascii":
        total_reads, total_base_pairs = run_mode_ascii(file_path, mode)
    elif validation == "ascii_quality":
        total_reads, total_base_pairs = run_mode_ascii_quality(file_path, mode)
    else:
        print("Unknown validation: ", validation, ". Use none | ascii | ascii_quality")
        return

    print(total_reads, total_base_pairs)
