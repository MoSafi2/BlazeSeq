from sys import argv
from blazeseq.readers import FileReader
from blazeseq.parser import RecordParser, ParserConfig
from pathlib import Path


fn main() raises:
    file_name = argv()[1]
    comptime config = ParserConfig(check_ascii=False, check_quality=False)
    parser = RecordParser[FileReader, config](FileReader(Path(file_name)))
    var total_reads = 0
    var total_base_pairs = 0
    for record in parser:
        total_reads += 1
        total_base_pairs += len(record)
    print(total_reads, total_base_pairs)
