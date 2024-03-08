from MojoFastTrim import CoordParser
from sys import argv
import time


fn main() raises:
    var vars = argv()
    var t1 = time.now()
    var parser = CoordParser(vars[1])

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
