from MojoFastTrim import FastqParser, Stats
from sys import argv
import time


alias KB = 1024
alias MB = 1024 * KB
alias GB = 1024 * MB


fn main() raises:
    var vars = argv()
    var t1 = time.now()
    var parser = FastqParser(vars[1], Stats())
    var read_no = 0
    while True:
        try:
            var read = parser.next()
            read_no += 1
        except Error:
            print(read_no)
            break
    var t2 = time.now()
    print((t2 - t1) / 1e9)
