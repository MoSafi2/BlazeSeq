from blazeseq.iostream import FileReader, BufferedReader
from blazeseq.readers import GZFile
from blazeseq.parser import RecordParser


def main():
    file = GZFile("data/SRR16012060.fastq.gz", "rb")
    file2 = FileReader("data/SRR16012060.fastq")
    parser = RecordParser(file2^)
    parser.parse_all()
