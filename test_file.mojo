from blazeseq.iostream import FileReader, BufferedReader
from blazeseq.readers import GZFile
from blazeseq.parser import RecordParser


def main():
    reader = RecordParser(
        FileReader("./data/M_abscessus_HiSeq.fq"),
    )
    reader.parse_all()
