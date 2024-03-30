from blazeseq import CoordParser
from sys import argv


fn main() raises:
    var vars = argv()
    var path = vars[1]
    var parser = CoordParser(path)
    var read_no = 0
    var base_number = 0
    var qu_numeber = 0
    while True:
        try:
            var read = parser.next()
            read_no += 1
            base_number += read.seq_len().to_int()
            qu_numeber += read.qu_len().to_int()
        except Error:
            break
    print(read_no, base_number, qu_numeber)
