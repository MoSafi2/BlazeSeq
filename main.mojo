import time
from math import math
from sys import argv
from fast_parser import FastParser
from math.math import round


alias KB = 1024
alias MB = 1024 * KB
alias GB = 1024 * MB


fn main() raises:
    let vars = argv()
    var parser = FastParser(vars[1], 64 * KB)
    var num: Int = 0
    var total_bases: Int = 0
    var total_qu: Int = 0
    let t1 = time.now()

    while True:
        try:
            let record = parser.next()
            num += 1
            total_bases += record.seq_len().to_int()
            total_qu += record.qu_len().to_int()
        except:
            break

    let t2 = time.now()
    let t_sec = ((t2 - t1) / 1e9)
    let s_per_r = t_sec / num
    print(
        String(t_sec)
        + "S spend in parsing: "
        + (num - 1)
        + " records. \neuqaling "
        + String((s_per_r) * 1e6)
        + " microseconds/read or "
        + int(round[DType.float32, 1](1 / s_per_r) * 60)
        + " reads/min\n"
        + "total base count is:"
        + (total_bases + 1)
    )
