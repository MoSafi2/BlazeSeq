from std.sys import argv
from blazeseq import FileReader, GZFile
from blazeseq import FastqParser, ParserConfig
from std.pathlib import Path


def main() raises:
    var args = argv()
    if len(args) < 2:
        print("Usage: pixi run mojo run examples/biofast_example.mojo /path/to/file.fastq")
        return
    file_name: String = args[1]
    comptime config = ParserConfig(
        check_ascii=False,
        check_quality=False,
        buffer_capacity=64 * 1024,
        buffer_growth_enabled=False,
    )

    var parser = FastqParser[FileReader, config](FileReader(Path(file_name)))
    var total_reads = 0
    var total_base_pairs = 0

    for record in parser.records():
        total_reads += 1
        total_base_pairs += len(record)

    print(total_reads, total_base_pairs)
