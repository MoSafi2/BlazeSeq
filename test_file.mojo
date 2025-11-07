from blazeseq.iostream import FileReader, BufferedReader
from blazeseq.readers import GZFile
from blazeseq.parser import RecordParser


def main():
    reader = BufferedReader(FileReader("./data/9_Swamp_S2B_rbcLa_2019_minq7.fastq"), capacity = 4096)
    print(reader.get_next_line())
    print(reader.get_next_line())
    print(reader.get_next_line())
    print(reader.get_next_line())
