import time
from math import math
from sys import argv
from blazeseq import CoordParser, RecordParser
from blazeseq.iostream import FileReader
from blazeseq import FullStats
from math.math import round
from utils.variant import Variant

alias KB = 1024
alias MB = 1024 * KB
alias GB = 1024 * MB


fn main() raises:
    var vars = argv()
    var t1 = time.now()
    var parser = CoordParser("data/M_abscessus_HiSeq.fq")

    var num_reads = 0
    var num_bases = 0
    var num_qu = 0
    while True:
        try:
            var record = parser.next()
            print(record)
            num_reads += 1
            num_bases += record.seq_len().to_int()
            num_qu += record.qu_len().to_int()
        except Error:
            print(num_reads, num_bases, num_qu)
            break
