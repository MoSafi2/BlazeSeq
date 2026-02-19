from sys import argv
from blazeseq.readers import FileReader, GZFile
from blazeseq.parser import RecordParser, ParserConfig, RefParser
from pathlib import Path
from utils import Variant


fn main() raises:
    file_name: String = argv()[1]
    comptime config = ParserConfig(
        check_ascii=True,
        check_quality=True,
        buffer_capacity=64 * 1024,
        buffer_growth_enabled=False,
    )

    comptime parser_variant = Variant[
        RefParser[FileReader, config], RefParser[GZFile, config]
    ]

    var parser: parser_variant

    if file_name.endswith("fastq") or file_name.endswith("fq"):
        parser = RefParser[FileReader, config](FileReader(Path(file_name)))
    elif file_name.endswith("fastq.gz") or file_name.endswith("fq.gz"):
        parser = RefParser[GZFile, config](GZFile(file_name, mode="rb"))
    else:
        raise Error("unsupported format")

    var total_reads = 0
    var total_base_pairs = 0

    if parser.isa[RefParser[FileReader, config]]():
        for record in parser.take[RefParser[FileReader, config]]():
            total_reads += 1
            total_base_pairs += len(record)
    elif parser.isa[RefParser[GZFile, config]]():
        for record in parser.take[RefParser[GZFile, config]]():
            total_reads += 1
            total_base_pairs += len(record)
    else:
        raise Error("Invalid parser")

    print(total_reads, total_base_pairs)
