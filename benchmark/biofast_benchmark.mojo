from sys import argv
from blazeseq import FileReader, GZFile
from blazeseq import FastqParser, ParserConfig
from pathlib import Path
from utils import Variant


fn main() raises:
    file_name: String = argv()[1]
    comptime config = ParserConfig(
        check_ascii=False,
        check_quality=False,
        buffer_capacity=64 * 1024,
        buffer_growth_enabled=False,
    )

    var parser = FastqParser[FileReader, config](FileReader(Path(file_name)))
    var total_reads = 0
    var total_base_pairs = 0

    for record in parser.ref_records():
        total_reads += 1
        total_base_pairs += len(record)

    print(total_reads, total_base_pairs)
