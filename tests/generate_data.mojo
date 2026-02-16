from blazeseq.record import FastqRecord
import random
from collections.string import chr, String
from time import perf_counter_ns

comptime QUAL_LOWER: Int64 = 33
comptime QUAL_UPPER: Int64 = 126


fn generate_fastq_record(
    length: Int, quality_offset: Int8 = 33
) raises -> FastqRecord:
    var DNA_BASES = ["A", "T", "G", "C", "N"]
    var HEADER = "@"
    var QU_HEADER = "+"

    var seq = String(capacity=length)
    var qual = String(capacity=length)

    random.seed(Int(perf_counter_ns()) % (2**32))

    for _ in range(length):
        var index = random.random_si64(min=0, max=len(DNA_BASES) - 1)
        var letter = DNA_BASES[index]
        seq += letter
        var chr_ = Int(random.random_si64(min=QUAL_LOWER, max=QUAL_UPPER))
        qual += chr(chr_)
    return FastqRecord(HEADER, seq, QU_HEADER, qual, quality_offset)


fn main() raises:
    print(generate_fastq_record(50))
