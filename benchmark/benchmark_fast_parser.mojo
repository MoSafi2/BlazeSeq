from MojoFastTrim import FastParser
from sys import argv
import time

alias KB = 1024
alias MB = 1024 * KB
alias GB = 1024 * MB


fn main() raises:
    var vars = argv()
    var t1 = time.now()
    var parser = FastParser(vars[1], 64 * 1024)
    # try:
    #     _ = parser.next()
    # except Error:
    #     print(Error)
    #     print(parser.parsing_stats)
    # var t2 = time.now()
    # print((t2 - t1) / 1e9)

    var num_reads = 0
    var num_bases = 0
    var num_qu = 0
    while True:
        try:
            var record = parser.next()
            num_reads += 1
            num_bases += record.seq_len().to_int()
            num_qu += record.qu_len().to_int()
        except Error:
            print(num_reads, num_bases, num_qu)
            break
