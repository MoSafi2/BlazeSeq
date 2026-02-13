from blazeseq.iostream import BufferedReader
from blazeseq.readers import GZFile, FileReader
from blazeseq import RecordParser


def main():
    var count = 0
    var total_base_pairs = 0

    file = GZFile("data/SRR16012060.fastq.gz", "rb")
    file2 = FileReader("data/SRR16012060.fastq")
    parser = RecordParser(file^)
    for record in parser:
        count += 1
        total_base_pairs += len(record)
    print(count, total_base_pairs)
