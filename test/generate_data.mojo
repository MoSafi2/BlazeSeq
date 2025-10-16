from blazeseq.record import FastqRecord
from blazeseq.quality_schema import (
    QualitySchema,
    generic_schema,
)
import random
from collections.string import chr, String
from time import perf_counter_ns


fn generate_fastq_record(
    length: Int, schema: QualitySchema
) raises -> FastqRecord:
    var DNA_BASES = ["A", "T", "G", "C", "N"]
    var HEADER = "@"
    var QU_HEADER = "+"

    seq = String(capacity=length)
    qual = String(capacity=length)
    low = Int64(schema.LOWER)
    high = Int64(schema.UPPER)

    random.seed(Int(perf_counter_ns() % (2**32)))

    for _ in range(length):
        index = random.random_si64(min=0, max=len(DNA_BASES) - 1)
        letter = DNA_BASES[index]
        seq += letter
        chr_ = Int(random.random_si64(min=low, max=high))
        qual += chr(chr_)
    return FastqRecord(
        SeqHeader=HEADER, SeqStr=seq, QuHeader=QU_HEADER, QuStr=qual
    )


fn main() raises:
    print(generate_fastq_record(2, generic_schema))
