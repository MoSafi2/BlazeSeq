"""This module should hold aggregate statistics about all the record which have been queried by the Parser, regardless of the caller function. """

from MojoFastTrim import FastqRecord, RecordCoord
from collections import Dict
from tensor import Tensor, TensorShape
from MojoFastTrim.helpers import write_to_buff
from math import max
from MojoFastTrim.analyzers import *

alias MAX_COUNTS = 1_000_000


trait Analyser:
    fn tally_read(inout self, record: FastqRecord):
        ...

    fn report(self) -> Tensor[DType.int64]:
        ...


struct Stats(Stringable):
    var num_reads: Int64
    var total_bases: Int64
    var bp_dist: BasepairDistribution
    var len_dist: LengthDistribution
    var qu_dist: QualityDistribution
    var dup_reads: DupReader
    var cg_content: CGContent

    fn __init__(inout self):
        self.num_reads = 0
        self.total_bases = 0

        self.len_dist = LengthDistribution()
        self.bp_dist = BasepairDistribution()
        self.qu_dist = QualityDistribution()
        self.dup_reads = DupReader()
        self.cg_content = CGContent()

    # Consider using Internal function for each type to get this, there is no need to know the impelemtnation of each type, this can get Ugly if you want to Add BAM, SAM .. etc.
    @always_inline
    fn tally(inout self, record: FastqRecord):
        self.num_reads += 1
        self.total_bases += record.SeqStr.num_elements()
        self.bp_dist.tally_read(record)
        self.len_dist.tally_read(record)
        self.qu_dist.tally_read(record)
        self.dup_reads.tally_read(record) #Most expensive 3.5s for 5.5 M reads
        self.cg_content.tally_read(record) #Almost Free

    fn __str__(self) -> String:
        return (
            String("Number of Reads: ")
            + self.num_reads
            + ". \n"
            + "Number of bases: "
            + self.total_bases
            + self.bp_dist
            + self.len_dist
            + self.qu_dist
            + self.dup_reads
            + self.cg_content
        )