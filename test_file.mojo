from blazeseq.iostream import FileReader, BufferedReader
from blazeseq.readers import GZFile
from blazeseq.parser import RecordParser


def main():
    reader = RecordParser[check_quality=True, check_ascii=True](
        FileReader("./data/SRR4381933_1.fastq"),
    )
    reader.parse_all()
