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

    # Parse all records in one pass
    parser.parse_all()
    print(parser.parsing_stats)

    # Parse all records iterativly.
    # while True:
    #     try:
    #         let record = parser.next()
    #     except:
    #         print(parser.parsing_stats)
    #         parser._file_handle.close()
    #         break
