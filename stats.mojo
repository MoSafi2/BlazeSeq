"""This module should hold aggregate statistics about all the record which have been queried by the Parser, regardless of the caller function. """

from MojoFastTrim import FastqRecord, RecordCoord
from collections import Dict
from tensor import Tensor


alias MAX_COUNTS = 1_000_000


struct Stats(Stringable):
    var num_reads: Int64
    var total_bases: Int64
    var sequences: Dict[FastqRecord, Int]
    var unique_counts: Int
    var length_vector: DynamicVector[Int]

    fn __init__(inout self):
        self.num_reads = 0
        self.total_bases = 0
        self.sequences = Dict[FastqRecord, Int]()
        self.unique_counts = 0
        self.length_vector = DynamicVector[Int]()

    @always_inline
    fn tally(inout self, record: FastqRecord):
        self.num_reads += 1
        self.total_bases += record.SeqStr.num_elements()

        #self.length_vector.push_back(record.SeqStr.num_elements())

        if self.num_reads > MAX_COUNTS:
            return

        if self.sequences.find(record):
            try:
                self.sequences[record] += 1
            except:
                pass
        else:
            self.sequences[record] = 1
            self.unique_counts += 1

    @always_inline
    fn tally(inout self, record: RecordCoord):
        self.num_reads += 1
        self.total_bases += record.seq_len().to_int()

    # fn length_average(self) -> Float64:
    #     var cum = 0
    #     for i in range(len(self.length_vector)):
    #         cum += self.length_vector[i]
    #     return cum / len(self.length_vector)

    fn __str__(self) -> String:
        return (
            String("Number of Reads: ")
            + self.num_reads
            + ". \n"
            + "Number of bases: "
            + self.total_bases
            + ".\n"
            + "Number of Unique reads: "
            + len(self.sequences)
            + "\nAverage Sequence length:"
            #+ self.length_average()
        )
