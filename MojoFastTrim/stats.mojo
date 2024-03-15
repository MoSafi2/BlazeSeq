"""This module should hold aggregate statistics about all the record which have been queried by the Parser, regardless of the caller function. """

from collections.vector import DynamicVector
from . import FastqRecord
from .helpers import write_to_buff
from tensor import TensorShape
from collections import Dict, KeyElement
from math import round
import time


alias MAX_LENGTH = 10_000
alias WIDTH = 5
alias MAX_READS = 100_000
alias MAX_QUALITY = 100
alias OFFSET = 33
alias MAX_COUNTS = 1_000_000


trait Analyser(CollectionElement):
    fn tally_read(inout self, record: FastqRecord):
        ...

    fn report(self) -> Tensor[DType.int64]:
        ...


@value
struct Stats(Stringable):
    var num_reads: Int64
    var total_bases: Int64
    var bp_dist: BasepairDistribution
    var len_dist: LengthDistribution
    var qu_dist: QualityDistribution
    var cg_content: CGContent

    fn __init__(inout self):
        self.num_reads = 0
        self.total_bases = 0
        self.len_dist = LengthDistribution()
        self.bp_dist = BasepairDistribution()
        self.qu_dist = QualityDistribution()
        self.cg_content = CGContent()

    # Consider using Internal function for each type to get this, there is no need to know the impelemtnation of each type, this can get Ugly if you want to Add BAM, SAM .. etc.
    @always_inline
    fn tally(inout self, record: FastqRecord):
        self.num_reads += 1
        self.total_bases += record.SeqStr.num_elements()
        self.bp_dist.tally_read(record)
        self.len_dist.tally_read(record)
        self.qu_dist.tally_read(record)
        self.cg_content.tally_read(record)  # Almost Free

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
            + self.cg_content
        )


@value
struct BasepairDistribution(Analyser, Stringable):
    var bp_dist: Tensor[DType.int64]
    # var bp_dist: Dict[StringKey, Tensor[DType.int64]]
    var max_length: Int

    fn __init__(inout self):
        # Hack untill finding a away to grown a multidim tensor in place.
        var shape = TensorShape(WIDTH, MAX_LENGTH)
        self.bp_dist = Tensor[DType.int64](shape)
        self.max_length = 0

    fn tally_read(inout self, record: FastqRecord):
        if record.SeqStr.num_elements() > self.max_length:
            # BUG: Copying multi-dim tensor is not working
            # var t = grow_matrix(self.bp_dist, record.SeqStr.num_elements())
            self.max_length = record.SeqStr.num_elements()

        for i in range(record.SeqStr.num_elements()):
            var index = VariadicList[Int]((record.SeqStr[i] % WIDTH).to_int(), i)
            self.bp_dist[index] += 1

    fn report(self) -> Tensor[DType.int64]:
        # return self.bp_dist

        var final_shape = TensorShape(WIDTH, self.max_length)
        var final_t = Tensor[DType.int64](WIDTH, self.max_length)

        for i in range(WIDTH):
            for j in range(self.max_length):
                var index = VariadicList[Int](i, j)
                final_t[index] = self.bp_dist[index]
        return final_t

    fn __str__(self) -> String:
        return String("\nBase_pair_dist_matrix: ") + self.report()


fn grow_matrix[T: DType](old_tensor: Tensor[T], num_ele: Int) -> Tensor[T]:
    var new_tensor = Tensor[T](WIDTH * num_ele)
    var reshape_e = TensorShape(old_tensor.num_elements())
    var old_reshaped = old_tensor
    try:
        old_reshaped.ireshape(reshape_e)
    except Error:
        print("Error", Error)

    for i in range(old_reshaped.num_elements()):
        new_tensor[i] = old_reshaped[i]

    var new_shape = TensorShape(WIDTH, num_ele)
    try:
        new_tensor.ireshape(new_shape)
    except Error:
        print("Error", Error)

    return new_tensor


"""
Module to Find CpGs in The read:
Algorithm: 
ord("C") + ord("G") = 138
From left to right, check the sum of every to consecutive numbers, if the number == 138
accumate one to CpG counter
at the end, divide the number by the read length, accumulate 1 to the CpG Tensor at the end of the rounded number.
"""


@value
struct CGContent(Analyser, Stringable):
    var cg_content: Tensor[DType.int64]

    fn __init__(inout self):
        self.cg_content = Tensor[DType.int64](100)

    fn tally_read(inout self, record: FastqRecord):
        var previous_base: Int8 = 0
        var current_base: Int8 = 0
        var cg_num = 0

        for index in range(1, record.SeqStr.num_elements()):
            previous_base = record.SeqStr[index - 1]
            current_base = record.SeqStr[index]
            if previous_base + current_base == 138:
                cg_num += 1

        var read_cg_content = round(
            cg_num * 100 / record.SeqStr.num_elements()
        ).to_int()
        self.cg_content[read_cg_content] += 1

    fn report(self) -> Tensor[DType.int64]:
        return self.cg_content

    fn __str__(self) -> String:
        return String("\nThe CpG content tensor is: ") + self.cg_content


@value
struct DupReader(Analyser, Stringable):
    var unique_dict: Dict[FastqRecord, Int64]
    var unique_reads: Int

    fn __init__(inout self):
        self.unique_dict = Dict[FastqRecord, Int64]()
        self.unique_reads = 0

    fn tally_read(inout self, record: FastqRecord):
        if self.unique_dict.__contains__(record):
            try:
                self.unique_dict[record] += 1
                return
            except:
                return

        if self.unique_reads < MAX_READS:
            self.unique_dict[record] = 1
            self.unique_reads += 1
        else:
            pass

    fn report(self) -> Tensor[DType.int64]:
        var report = Tensor[DType.int64](1)
        report[0] = len(self.unique_dict)
        return report

    fn __str__(self) -> String:
        return String("\nNumber of duplicated reads is") + self.report()


@value
struct LengthDistribution(Analyser, Stringable):
    var length_vector: Tensor[DType.int64]

    fn __init__(inout self):
        self.length_vector = Tensor[DType.int64](0)

    fn tally_read(inout self, record: FastqRecord):
        if record.SeqStr.num_elements() > self.length_vector.num_elements():
            self.length_vector = grow_tensor(
                self.length_vector, record.SeqStr.num_elements()
            )
        self.length_vector[record.SeqStr.num_elements() - 1] += 1

    @always_inline
    fn length_average(self, num_reads: Int) -> Float64:
        var cum: Int64 = 0
        for i in range(self.length_vector.num_elements()):
            cum += self.length_vector[i] * (i + 1)
        return cum.to_int() / num_reads

    fn report(self) -> Tensor[DType.int64]:
        return self.length_vector

    fn __str__(self) -> String:
        return String("\nLength Distribution: ") + self.length_vector


fn grow_tensor[
    T: DType,
](old_tensor: Tensor[T], num_ele: Int) -> Tensor[T]:
    var new_tensor = Tensor[T](num_ele)
    write_to_buff(old_tensor, new_tensor, 0)

    return new_tensor


# TODO: The encoding of the Fastq file should be predicted and used
# FROM: https://www.biostars.org/p/90845/
# RANGES = {
#     'Sanger': (33, 73),
#     'Solexa': (59, 104),
#     'Illumina-1.3': (64, 104),
#     'Illumina-1.5': (66, 104),
#     'Illumina-1.8': (33, 94)
# }


@value
struct QualityDistribution(Analyser, Stringable):
    var qu_dist: Tensor[DType.int64]
    var max_length: Int
    var max_qu: Int

    fn __init__(inout self):
        # Hack untill finding a away to grown a tensor in place.
        var shape = TensorShape(MAX_QUALITY, MAX_LENGTH)
        self.qu_dist = Tensor[DType.int64](shape)
        self.max_length = 0
        self.max_qu = 0

    fn tally_read(inout self, record: FastqRecord):
        if record.QuStr.num_elements() > self.max_length:
            self.max_length = record.QuStr.num_elements()

        for i in range(record.QuStr.num_elements()):
            var index = VariadicList[Int]((record.QuStr[i] - OFFSET).to_int(), i)
            if record.QuStr[i].to_int() - OFFSET > self.max_qu:
                self.max_qu = record.QuStr[i].to_int() - OFFSET
            self.qu_dist[index] += 1

    fn report(self) -> Tensor[DType.int64]:
        print(self.max_length)
        var final_shape = TensorShape(self.max_qu, self.max_length)
        var final_t = Tensor[DType.int64](final_shape)

        for i in range(self.max_qu):
            for j in range(self.max_length):
                var index = VariadicList[Int](i, j)
                final_t[index] = self.qu_dist[index]
        return final_t

    fn __str__(self) -> String:
        return String("\nQuality_dist_matrix: ") + self.report()


fn main():
    var x = 500545425586454578
    var y = 500545425586454578
    var t1 = time.now()
    var z = x == y
    var t2 = time.now()
    print(z, t2 - t1)
