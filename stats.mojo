from collections import Dict
from tensor import Tensor

struct Stats(Stringable):
    var num_reads: Int64
    var total_bases: Int64

    fn __init__(inout self):
        self.num_reads = 0
        self.total_bases = 0

    @always_inline
    fn tally(inout self, record: FastqRecord):
        self.num_reads += 1
        self.total_bases += record.SeqStr.num_elements()


    @always_inline
    fn tally(inout self, record: RecordCoord):
        self.num_reads += 1
        self.total_bases += record.seq_len().to_int()

    fn __str__(self) -> String:
        return (
            String("Number of Reads: ")
            + self.num_reads
            + ". \n"
            + "Number of bases: "
            + self.total_bases
            + ".\n"
            + "Number of Unique reads: "
        )
