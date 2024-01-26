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
    var parser = FastqParser(vars[1], 64 * KB)

    # Parse all records in one pass, Fastest
    parser.parse_all()
    print(parser.parsing_stats)
    
    ## Parse all records iterativly.
    # let t1 = time.now()
    # while True:
    #     try:
    #         let record = parser.next()

    #         if parser.parsing_stats.num_reads % 1_000_000 == 0:
    #             let num = parser.parsing_stats.num_reads
    #             let t = time.now()
    #             let reads_p_min: Float64 = num.to_int() / ((t - t1) / 1e9) * 60
    #             let rounded = int(round(reads_p_min))
    #             print("\33[H")
    #             print("\033[J")
    #             print("Number of reads processed is :", num)
    #             print("Speed:", rounded, " reads/min")
    #     except:
    #         print(parser.parsing_stats)
    #         parser._file_handle.close()
    #         break
