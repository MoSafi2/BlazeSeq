import time
from math import math
from sys import argv
from algorithm import unroll
from fastq_parser import FastqParser
from fastq_record import FastqRecord
from fastq_writer import FastqWriter
from math.math import round


alias KB = 1024
alias MB = 1024 * KB
alias GB = 1024 * MB


fn main() raises:
    let vars = argv()
    var parser = FastqParser(vars[1], 1 * MB)
    var writer = FastqWriter(String("data/out.fq"), 1 * MB)
    var num: Int = 0
    var total_bases: Int = 0

    # num, total_bases = parser.parse_all_records()

    let t1 = time.now()

    while True:
        try:
            var record = parser.next()
            num += 1
            total_bases += len(record)

            # Going to town with the record applying all kinds of transformations
            # Transformation could be applied through a seperate entity which can read, organise, and schedule transformations
            record.trim_record(quality_threshold=20, direction="end")

            writer.ingest_read(record)

            if num % 1_000_000 == 0:
                let t = time.now()
                let reads_p_min: Float64 = (num / ((t - t1) / 1e9)) * 60
                let rounded = int(round(reads_p_min))
                print("\33[H")
                print("\033[J")
                print("Number of reads processed is :", num)
                print("Speed:", rounded, " reads/min")

        except:
            writer.flush_buffer()
            break

    let t2 = time.now()

    let t_sec = ((t2 - t1) / 1e9)
    let s_per_r = t_sec / num
    print(
        String(t_sec)
        + "S spend in parsing: "
        + num
        + " records. \neuqaling "
        + String((s_per_r) * 1e6)
        + " microseconds/read or "
        + int(round[DType.float32, 1](1 / s_per_r) * 60)
        + " reads/min\n"
        + "total base count is:"
        + total_bases
    )
