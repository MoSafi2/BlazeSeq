"""This module should hold aggregate statistics about all the record which have been queried by the Parser, regardless of the caller function. """

from blazeseq.record import FastqRecord
from blazeseq.helpers import write_to_buff
from blazeseq.helpers import cpy_tensor
from tensor import TensorShape
from collections import Dict, KeyElement
import time
from tensor import Tensor
from python import Python
from utils.static_tuple import StaticTuple

alias py_lib: String = "./.pixi/envs/default/lib/python3.12/site-packages/"

fn hash_list() -> List[UInt64]:
    var  li: List[UInt64] = List[UInt64](
            _seq_to_hash("AGATCGGAAGAG"),
            _seq_to_hash("TGGAATTCTCGG"),
            _seq_to_hash("GATCGTCGGACT"),
            _seq_to_hash("CTGTCTCTTATA"),
            _seq_to_hash("AAAAAAAAAAAA"),
            _seq_to_hash("GGGGGGGGGGGG")
            )
    return li


alias WIDTH = 5
alias MAX_READS = 1_000_000
alias MAX_QUALITY = 93


trait Analyser(CollectionElement, Stringable):
    fn tally_read(inout self, record: FastqRecord):
        ...

    fn report(self) -> Tensor[DType.int64]:
        ...
    fn __str__(self) -> String:
        ...

@value
struct FullStats(Stringable, CollectionElement):
    var num_reads: Int64
    var total_bases: Int64
    var bp_dist: BasepairDistribution
    var len_dist: LengthDistribution
    var qu_dist: QualityDistribution
    var cg_content: CGContent
    var dup_reads: DupReads
    var kmer_content: KmerContent

    fn __init__(inout self):
        self.num_reads = 0
        self.total_bases = 0
        self.len_dist = LengthDistribution()
        self.bp_dist = BasepairDistribution()
        self.qu_dist = QualityDistribution()
        self.cg_content = CGContent()
        self.dup_reads = DupReads()
        self.kmer_content = KmerContent(hash_list(), 12)

    @always_inline
    fn tally(inout self, record: FastqRecord):
        self.num_reads += 1
        self.total_bases += record.len_record()
        self.bp_dist.tally_read(record)
        self.len_dist.tally_read(record)
        self.cg_content.tally_read(record)  # Almost Free
        self.dup_reads.tally_read(record)
        self.kmer_content.tally_read(record)
        
        # BUG: There is a bug here which causes core dumped
        self.qu_dist.tally_read(record) #Expensive operation, a lot of memory access


    @always_inline
    fn plot(self) raises:
        self.bp_dist.plot()
        self.cg_content.plot()
        self.len_dist.plot()
        self.qu_dist.plot()
        self.dup_reads.plot()

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
            + self.kmer_content
            + self.dup_reads
        )


@value
struct BasepairDistribution(Analyser):
    var bp_dist: Tensor[DType.int64]
    var max_length: Int

    fn __init__(inout self):
        var shape = TensorShape(VariadicList[Int](1, WIDTH))
        self.bp_dist = Tensor[DType.int64](shape)
        self.max_length = 0

    fn tally_read(inout self, record: FastqRecord):
        if record.len_record() > self.max_length:
            self.max_length = record.len_record()
            var new_tensor = grow_matrix(
                self.bp_dist, TensorShape(self.max_length, WIDTH)
            )
            swap(self.bp_dist, new_tensor)

        for i in range(record.len_record()):
            # Remineder of first 5 bits seperates N from T
            var base_val = int((record.SeqStr[i] & 0b11111) % WIDTH)
            var index = VariadicList[Int](i, base_val)
            self.bp_dist[index] += 1

    fn report(self) -> Tensor[DType.int64]:
        return self.bp_dist

    fn plot(self) raises:
        Python.add_to_path(py_lib)
        var plt = Python.import_module("matplotlib.pyplot")
        var arr = matrix_to_numpy(self.bp_dist)
        var x = plt.subplots()  # Create a figure
        var fig = x[0]
        var ax = x[1]
        ax.plot(arr)
        fig.savefig("BasepairDistribution.png")

    fn __str__(self) -> String:
        return String("\nBase_pair_dist_matrix: ") + self.report()


@value
struct CGContent(Analyser):
    var cg_content: Tensor[DType.int64]

    fn __init__(inout self):
        self.cg_content = Tensor[DType.int64](100)

    fn tally_read(inout self, record: FastqRecord):
        var cg_num = 0
        for index in range(0, record.len_record()):
            if (
                record.SeqStr[index] & 0b111 == 3
                or record.SeqStr[index] & 0b111 == 7
            ):
                cg_num += 1

        var read_cg_content = int(
            round(cg_num * 100 / record.len_record())
        )
        self.cg_content[read_cg_content] += 1

    fn report(self) -> Tensor[DType.int64]:
        return self.cg_content

    fn plot(self) raises:
        Python.add_to_path(py_lib)
        var plt = Python.import_module("matplotlib.pyplot")
        var arr = tensor_to_numpy_1d(self.cg_content)
        var x = plt.subplots()  # Create a figure
        var fig = x[0]
        var ax = x[1]
        ax.plot(arr)
        fig.savefig("CGContent.png")

    fn __str__(self) -> String:
        return String("\nThe CpG content tensor is: ") + self.cg_content


#TODO: You should extraplolate from the number of reads in the unique reads to how it would look like for everything.
@value
struct DupReads(Analyser):
    var unique_dict: Dict[FastqRecord, Int64]
    var unique_reads: Int

    fn __init__(inout self):
        self.unique_dict = Dict[FastqRecord, Int64]()
        self.unique_reads = 0

    fn tally_read(inout self, record: FastqRecord):
        if record in self.unique_dict:
            try:
                self.unique_dict[record] += 1
                return
            except:
                print("error")
                pass

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


    fn plot(self) raises:
        var x = self.unique_dict.values()
        var temp_tensor = Tensor[DType.int64](len(x))
        for i in range(len(x)):
            temp_tensor[i] = x.__next__()[]

        var np = Python.import_module("numpy")
        var arr = tensor_to_numpy_1d(temp_tensor)
        np.save("arr_DupReads.npy", arr)
        

@value
struct LengthDistribution(Analyser):
    var length_vector: Tensor[DType.int64]

    fn __init__(inout self):
        self.length_vector = Tensor[DType.int64](0)

    fn tally_read(inout self, record: FastqRecord):
        if record.len_record() > self.length_vector.num_elements():
            var new_tensor = grow_tensor(
                self.length_vector, record.len_record()
            )
            swap(self.length_vector, new_tensor)
        self.length_vector[record.len_record() - 1] += 1

    @always_inline
    fn length_average(self, num_reads: Int) -> Float64:
        var cum: Int64 = 0
        for i in range(self.length_vector.num_elements()):
            cum += self.length_vector[i] * (i + 1)
        return int(cum) / num_reads

    fn report(self) -> Tensor[DType.int64]:
        return self.length_vector

    fn plot(self) raises:
        Python.add_to_path(py_lib)
        var plt = Python.import_module("matplotlib.pyplot")
        var np = Python.import_module("numpy")
        var mtp = Python.import_module("matplotlib")

        var arr = tensor_to_numpy_1d(self.length_vector)

        var x = plt.subplots()  # Create a figure
        var fig = x[0]
        var ax = x[1]

        var arr2 = np.insert(arr, 0, 0)
        var arr3 = np.append(arr2, 0)
        ax.plot(arr3)
        ax.xaxis.set_major_locator(mtp.ticker.MaxNLocator(integer=True))
        ax.set_xlim(np.argmax(arr3 > 0) - 1, len(arr3) - 1)
        ax.set_ylim(0)
        fig.savefig("LengthDistribution.png")

    fn __str__(self) -> String:
        return String("\nLength Distribution: ") + self.length_vector


#TODO: FIX this struct to reflect FastQC
@value
struct QualityDistribution(Analyser):
    var qu_dist: Tensor[DType.int64]
    var max_length: Int
    var max_qu: Int

    fn __init__(inout self):
        var shape = TensorShape(1, 40)
        self.qu_dist = Tensor[DType.int64](shape)
        self.max_length = 0
        self.max_qu = 0

    fn tally_read(inout self, record: FastqRecord):
        if record.len_quality() > self.max_length:
            self.max_length = record.len_record()
            var new_shape = TensorShape(self.max_length, 40)
            var new_tensor = grow_matrix(self.qu_dist, new_shape)
            swap(self.qu_dist, new_tensor)

        for i in range(record.len_quality()):
            var base_qu = int(record.QuStr[i] - record.quality_schema.OFFSET)
            var index = VariadicList[Int](i, base_qu)
            self.qu_dist[index] += 1
            if base_qu > self.max_qu:
                self.max_qu = base_qu

    # Use this answer for plotting: https://stackoverflow.com/questions/58053594/how-to-create-a-boxplot-from-data-with-weights
    #TODO: Make an abbreviator of the plot to get always between 50-60 bars per plot
    #TODO: Stylize the plot
    fn plot(self) raises:
        var arr = matrix_to_numpy(self.qu_dist)
        
        Python.add_to_path(py_lib)
        var np = Python.import_module("numpy")
        var plt = Python.import_module("matplotlib.pyplot")
        var sns = Python.import_module("seaborn")
        var py_builtin = Python.import_module("builtins")
        np.save("arr_qu.npy", arr)


        ################# Quality Histogram ##################

        var mean_line = np.sum(arr * np.arange(1, 41), axis=1) / np.sum(
            arr, axis=1
        )
        var cum_sum = np.cumsum(arr, axis=1)
        var total_counts = np.reshape(np.sum(arr, axis=1), (100, 1))
        var median = np.argmax(cum_sum > total_counts / 2, axis=1)
        var Q75 = np.argmax(cum_sum > total_counts * 0.75, axis=1)
        var Q25 = np.argmax(cum_sum > total_counts * 0.25, axis=1)
        var IQR = Q75 - Q25

        var whislo = np.full(len(IQR), None)
        var whishi = np.full(len(IQR), None)

        var x = plt.subplots()
        var fig = x[0]
        var ax = x[1]
        var l = py_builtin.list()
        for i in range(len(IQR)):
            var stat: PythonObject = py_builtin.dict()
            stat["med"] = median[i]
            stat["q1"] = Q25[i]
            stat["q3"] = Q75[i]
            stat["whislo"] = whislo[i]
            stat["whishi"] = whishi[i]
            l.append(stat)

        ax.bxp(l, showfliers=False)
        ax.plot(mean_line)
        fig.savefig("QualityDistribution.png")

        #################### Quality  Heatmap #########################

        var y = plt.subplots()
        var fig2 = y[0]
        var ax2 = y[1]
        sns.heatmap(np.flipud(arr).T, cmap="Blues", robust= True, ax = ax2)
        fig2.savefig("QualityDistributionHeatMap.png")

    fn report(self) -> Tensor[DType.int64]:
        var final_shape = TensorShape(self.max_qu, self.max_length)
        var final_t = Tensor[DType.int64](final_shape)

        for i in range(self.max_qu):
            for j in range(self.max_length):
                var index = VariadicList[Int](i, j)
                final_t[index] = self.qu_dist[index]
        return final_t

    fn __str__(self) -> String:
        return String("\nQuality_dist_matrix: ") + self.report()


@value
struct KmerContent[bits: Int = 3](Analyser):
    var kmer_len: Int
    var hash_counts:Tensor[DType.int64]
    var hash_list: List[UInt64]

    fn __init__(inout self, hashes: List[UInt64], kmer_len: Int = 0):
        self.kmer_len = min(kmer_len, 64 // bits)
        self.hash_list = hashes
        self.hash_counts = Tensor[DType.int64](len(self.hash_list))

    fn report(self) -> Tensor[DType.int64]:
        return self.hash_counts

    # TODO: Check if it will be easier to use the bool_tuple and hashes as a list instead
    @always_inline
    fn tally_read(inout self, record: FastqRecord):

        var hash: UInt64 = 0
        var end = 0
        # Make a custom bit mask of 1s by certain length
        var mask: UInt64 = (0b1 << self.kmer_len * bits) - 1
        var neg_mask = mask >> bits
        var bit_shift = (0b1 << bits) -1

        # Check initial Kmer
        if len(self.hash_list) > 0:
            self._check_hashes(hash)

        for i in range(end, record.len_record()):
            # Remove the most signifcant 3 bits
            hash = hash & neg_mask

            # Mask for the least sig. three bits, add to hash
            var rem = record.SeqStr[i] & bit_shift  
            hash = (hash << bits) + int(rem)
            if len(self.hash_list) > 0:
                self._check_hashes(hash)

    @always_inline
    fn _check_hashes(inout self, hash: UInt64):
        for i in range(len(self.hash_list)):
            if hash == self.hash_list[i]:
                self.hash_counts[i] += 1

    fn __str__(self) -> String:
        return String("\nhash count table is ") + str(self.hash_counts)

        
# @value
# struct DuplicateReads(Analyser):
#     var dup_reads: Tensor[DType.int64]
#     var hashes: Tensor[DType.uint64]

#     fn __init__(inout self):
#         self.dup_reads = Tensor[DType.int64](TensorShape(100_000), 0)
#         self.hashes = Tensor[DType.uint64](TensorShape(100_000), 0)

#     @always_inline
#     fn tally_read(inout self, record: FastqRecord):
#         var index = int(record.hash() % 100_000)

#         #New hash
#         if self.hashes[index] == 0:
#             self.hashes[index] = record.hash()
#             self.dup_reads[index] += 1
#         else:
#             if self.hashes[index] == record.hash():
#                 self.dup_reads[index] += 1


#     fn plot(self) raises:
#         var np = Python.import_module("numpy")
#         var arr = tensor_to_numpy_1d(self.dup_reads)
#         np.save("arr_DupReads.npy", arr)
        
#     fn report(self) -> Tensor[DType.int64]:
#         return self.dup_reads

#     fn __str__(self) -> String:
#         return String("\nDuplicate reads is: ") + str(self.dup_reads)


# TODO: Make this also parametrized on the number of bits per bp
fn _seq_to_hash(seq: String) -> UInt64:
    var hash = 0
    for i in range(0, len(seq)):
        # Remove the most signifcant 3 bits
        hash = hash & 0x1FFFFFFFFFFFFFFF
        # Mask for the least sig. three bits, add to hash
        var rem = ord(seq[i]) & 0b111  
        hash = (hash << 3) + int(rem)
    return hash

#TODO: Make this also parametrized on the number of bits per bp, this now works only for 3bits
fn _hash_to_seq(hash: UInt64) -> String:
    var inner = hash
    var out: String = ""
    var sig2bit: UInt64

    for i in range(21, -1, -1):
        sig2bit = (inner >> (i * 3)) & 0b111
        if sig2bit == 1:
            out += "A"
        if sig2bit == 3:
            out += "C"
        if sig2bit == 7:
            out += "G"
        if sig2bit == 4:
            out += "T"
        if sig2bit == 6:
            out += "N"
    return out


def tensor_to_numpy_1d[T: DType](tensor: Tensor[T]) -> PythonObject:
    Python.add_to_path(py_lib)
    np = Python.import_module("numpy")
    ar = np.zeros(tensor.num_elements())
    for i in range(tensor.num_elements()):
        ar.itemset(i, tensor[i])
    return ar

def matrix_to_numpy[T: DType](tensor: Tensor[T]) -> PythonObject:
    np = Python.import_module("numpy")
    ar = np.zeros([tensor.shape()[0], tensor.shape()[1]])
    for i in range(tensor.shape()[0]):
        for j in range(tensor.shape()[1]):
            ar.itemset((i, j), tensor[i, j])
    return ar


fn grow_tensor[
    T: DType,
](old_tensor: Tensor[T], num_ele: Int) -> Tensor[T]:
    var new_tensor = Tensor[T](num_ele)
    cpy_tensor(new_tensor, old_tensor, old_tensor.num_elements(), 0, 0)
    return new_tensor


fn grow_matrix[
    T: DType
](old_tensor: Tensor[T], new_shape: TensorShape) -> Tensor[T]:
    var new_tensor = Tensor[T](new_shape)
    for i in range(old_tensor.shape()[0]):
        for j in range(old_tensor.shape()[1]):
            new_tensor[VariadicList(i, j)] = old_tensor[VariadicList(i, j)]
    return new_tensor



# TODO: Add module for adapter content
@value
struct AdapterContent(Analyser):

    fn tally_read(inout self, read: FastqRecord):
        pass

    fn report(self) -> Tensor[DType.int64]:
        return Tensor[DType.int64]()

    fn __str__(self) -> String:
        return ""
