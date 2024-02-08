import time
from math import math
from sys import argv
from MojoFastTrim import FastParser, FastqParser
from math.math import round

alias KB = 1024
alias MB = 1024 * KB
alias GB = 1024 * MB


fn main() raises:
    let vars = argv()
    var parser = FastParser(vars[1], 64 * KB)

    # Parse all records in one pass, Fastest
    # parser.parse_all()

    let t1 = time.now()
    var reads = 0
    while True:
        try:
            let record = parser.next()
            reads += 1
            if reads % 1_000_000 == 0:
                let t = time.now()
                let reads_p_min: Float64 = reads / ((t - t1) / 1e9) * 60
                let rounded = int(round(reads_p_min))
                print("\33[H")
                print("\033[J")
                print("Number of reads processed is :", reads)
                print("Speed:", rounded, " reads/min")
        except:
            print(reads)
            parser._file_handle.close()
            break
