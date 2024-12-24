"""This module should hold aggregate statistics about all the record which have been queried by the Parser, regardless of the caller function. """

# TODO: Check if you can convert large matrcies to a list of tensors and wether this will result in a better performance. Especially for for Quality Distribution, Tile

from tensor import TensorShape
from collections import Dict, KeyElement, Optional
from collections.dict import DictEntry
from utils import StringSlice, Index
from memory import Span
import time
from tensor import Tensor
from python import Python, PythonObject
from algorithm import sum
from blazeseq.record import FastqRecord, RecordCoord
from blazeseq.helpers import write_to_buff, cpy_tensor, QualitySchema
from blazeseq.CONSTS import (
    illumina_1_5_schema,
    illumina_1_3_schema,
    illumina_1_8_schema,
    generic_schema,
)

alias py_lib: String = "./.pixi/envs/default/lib/python3.12/site-packages/"


fn hash_list() -> List[UInt64]:
    var li: List[UInt64] = List[UInt64](
        _seq_to_hash("AGATCGGAAGAG"),
        _seq_to_hash("TGGAATTCTCGG"),
        _seq_to_hash("GATCGTCGGACT"),
        _seq_to_hash("CTGTCTCTTATA"),
        _seq_to_hash("AAAAAAAAAAAA"),
        _seq_to_hash("GGGGGGGGGGGG"),
    )
    return li


# TODO: Check how to unpack this variadic
def hash_names() -> (
    ListLiteral[
        StringLiteral,
        StringLiteral,
        StringLiteral,
        StringLiteral,
        StringLiteral,
        StringLiteral,
    ]
):
    var names = [
        "Illumina Universal Adapter",
        "Illumina Small RNA 3' Adapter",
        "Illumina Small RNA 5' Adapter",
        "Nextera Transposase Sequence",
        "PolyA",
        "PolyG",
    ]

    return names


alias WIDTH = 5
alias MAX_READS = 100_000
alias MAX_QUALITY = 93


trait Analyser(CollectionElement, Stringable):
    fn tally_read(inout self, record: FastqRecord):
        ...

    fn report(self) -> Tensor[DType.int64]:
        ...

    fn __str__(self) -> String:
        ...


@value
struct FullStats(CollectionElement):
    var num_reads: Int64
    var total_bases: Int64
    var bp_dist: BasepairDistribution
    var len_dist: LengthDistribution
    var qu_dist: QualityDistribution
    var cg_content: CGContent
    var dup_reads: DupReads
    var tile_qual: PerTileQuality
    var adpt_cont: AdapterContent

    fn __init__(inout self):
        self.num_reads = 0
        self.total_bases = 0
        self.len_dist = LengthDistribution()
        self.bp_dist = BasepairDistribution()
        self.qu_dist = QualityDistribution()
        self.cg_content = CGContent()
        self.dup_reads = DupReads()
        self.tile_qual = PerTileQuality()
        self.adpt_cont = AdapterContent(hash_list(), 12)

    @always_inline
    fn tally(inout self, record: FastqRecord):
        self.num_reads += 1
        self.total_bases += record.len_record()
        self.bp_dist.tally_read(record)
        self.len_dist.tally_read(record)
        self.cg_content.tally_read(record)  # Almost Free
        self.dup_reads.tally_read(record)
        self.qu_dist.tally_read(record)
        self.tile_qual.tally_read(record)
        self.adpt_cont.tally_read(record, self.num_reads)

    @always_inline
    fn tally(inout self, record: RecordCoord):
        self.num_reads += 1
        self.total_bases += int(record.seq_len())
        self.bp_dist.tally_read(record)
        self.len_dist.tally_read(record)
        self.cg_content.tally_read(record)
        self.qu_dist.tally_read(record)
        pass

    @always_inline
    fn plot(inout self) raises:
        self.bp_dist.plot(self.num_reads)
        self.cg_content.plot()
        self.len_dist.plot()
        self.dup_reads.plot()
        self.qu_dist.plot()
        self.tile_qual.plot()
        self.adpt_cont.plot(self.num_reads)
        pass


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

    fn tally_read(inout self, record: RecordCoord):
        if record.seq_len() > self.max_length:
            self.max_length = int(record.seq_len())
            var new_tensor = grow_matrix(
                self.bp_dist, TensorShape(self.max_length, WIDTH)
            )
            swap(self.bp_dist, new_tensor)

        for i in range(int(record.seq_len())):
            # Remineder of first 5 bits seperates N from T
            var base_val = int((record.SeqStr[i] & 0b11111) % WIDTH)
            var index = VariadicList[Int](i, base_val)
            self.bp_dist[index] += 1

    fn report(self) -> Tensor[DType.int64]:
        return self.bp_dist

    # Should Plot BP distrubution  line plot & Per base N content
    # DONE!
    fn plot(self, total_reads: Int64) raises:
        Python.add_to_path(py_lib)
        var plt = Python.import_module("matplotlib.pyplot")
        var arr = matrix_to_numpy(self.bp_dist)
        arr = (arr / total_reads) * 100
        var arr1 = arr[:, 0:4]
        var arr2 = arr[:, 4:5]
        var x = plt.subplots()  # Create a figure
        var fig = x[0]
        var ax = x[1]
        ax.plot(arr1)
        ax.set_ylim(0, 100)
        plt.legend(["%T", "%A", "%G", "%C"])
        fig.savefig("BasepairDistribution.png")

        var y = plt.subplots()  # Create a figure
        var fig2 = y[0]
        var ax2 = y[1]
        ax2.plot(arr2)
        ax2.set_ylim(0, 100)
        plt.legend(["%N"])
        fig2.savefig("NContent.png")

    fn __str__(self) -> String:
        return String("\nBase_pair_dist_matrix: ") + str(self.report())


# Done!
@value
struct CGContent(Analyser):
    var cg_content: Tensor[DType.int64]
    var theoritical_distribution: Tensor[DType.int64]

    fn __init__(inout self):
        self.cg_content = Tensor[DType.int64](101)
        self.theoritical_distribution = Tensor[DType.int64](101)

    fn tally_read(inout self, record: FastqRecord):
        if record.len_record() == 0:
            return

        var cg_num = 0

        for index in range(0, record.len_record()):
            if (
                record.SeqStr[index] & 0b111 == 3
                or record.SeqStr[index] & 0b111 == 7
            ):
                cg_num += 1

        var read_cg_content = int(
            round(cg_num * 100 / int(record.len_record()))
        )
        self.cg_content[read_cg_content] += 1

    fn tally_read(inout self, record: RecordCoord):
        if record.seq_len() == 0:
            return
        var cg_num = 0

        for index in range(0, record.seq_len()):
            if (
                record.SeqStr[index] & 0b111 == 3
                or record.SeqStr[index] & 0b111 == 7
            ):
                cg_num += 1

        var read_cg_content = int(round(cg_num * 100 / int(record.seq_len())))
        self.cg_content[read_cg_content] += 1

    fn calculate_theoritical_distribution(self) raises -> PythonObject:
        np = Python.import_module("numpy")
        sc = Python.import_module("scipy")
        var arr = tensor_to_numpy_1d(self.cg_content)
        var total_counts = np.sum(arr)
        var x_categories = np.arange(len(arr))
        var mode = np.argmax(arr)

        var stdev = np.sqrt(
            np.sum((x_categories - mode) ** 2 * arr) / (total_counts - 1)
        )
        var nd = sc.stats.norm(loc=mode, scale=stdev)
        var theoritical_distribution = nd.pdf(x_categories) * total_counts
        return theoritical_distribution

    fn report(self) -> Tensor[DType.int64]:
        return self.cg_content

    fn plot(self) raises:
        Python.add_to_path(py_lib)
        var plt = Python.import_module("matplotlib.pyplot")
        var arr = tensor_to_numpy_1d(self.cg_content)
        var theoritical_distribution = self.calculate_theoritical_distribution()
        var x = plt.subplots()
        var fig = x[0]
        var ax = x[1]
        ax.plot(arr)
        ax.plot(theoritical_distribution)
        fig.savefig("CGContent.png")

    fn __str__(self) -> String:
        return String("\nThe CpG content tensor is: ") + str(self.cg_content)


# TODO: You should extraplolate from the number of reads in the unique reads to how it would look like for everything.
@value
struct DupReads(Analyser):
    var unique_dict: Dict[String, Int]
    var unique_reads: Int
    var count_at_max: Int
    var n: Int
    var corrected_counts: Dict[Int, Float64]

    fn __init__(inout self):
        self.unique_dict = Dict[String, Int]()
        self.unique_reads = 0
        self.count_at_max = 0
        self.n = 0
        self.corrected_counts = Dict[Int, Float64]()

    fn tally_read(inout self, record: FastqRecord):
        self.n += 1
        read_len = min(record.len_record(), 50)
        var s = String(record.get_seq().as_bytes()[0:read_len])
        if s in self.unique_dict:
            try:
                self.unique_dict[s] += 1
                return
            except error:
                print(error._message())
                pass

        if self.unique_reads <= MAX_READS:
            self.unique_dict[s] = 1
            self.unique_reads += 1

            if self.unique_reads == MAX_READS:
                self.count_at_max = self.n
        else:
            return

    fn predict_reads(inout self):
        # Construct Duplication levels dict
        var dup_dict = Dict[Int, Int]()
        for entry in self.unique_dict.items():
            if int(entry[].value) in dup_dict:
                try:
                    dup_dict[int(entry[].value)] += 1
                except error:
                    print(error._message())
            else:
                dup_dict[int(entry[].value)] = 1

        # Correct reads levels
        var corrected_reads = Dict[Int, Float64]()
        for entry in dup_dict:
            try:
                var count = dup_dict[entry[]]
                var level = entry[]
                var corrected_count = self.correct_values(
                    level, count, self.count_at_max, self.n
                )
                corrected_reads[level] = corrected_count
            except:
                print("Error")

        self.corrected_counts = corrected_reads

    @staticmethod
    fn correct_values(
        dup_level: Int, count_at_level: Int, count_at_max: Int, total_count: Int
    ) -> Float64:
        if count_at_max == total_count:
            return count_at_level

        if total_count - count_at_level < count_at_max:
            return count_at_level

        var pNotSeeingAtLimit: Float64 = 1
        var limitOfCaring = Float64(1) - (
            count_at_level / (count_at_level + 0.01)
        )

        for i in range(count_at_max):
            pNotSeeingAtLimit *= ((total_count - i) - dup_level) / (
                total_count - i
            )

            if pNotSeeingAtLimit < limitOfCaring:
                pNotSeeingAtLimit = 0
                break

        var pSeeingAtLimit: Float64 = 1 - pNotSeeingAtLimit
        var trueCount = count_at_level / pSeeingAtLimit

        return trueCount

    fn report(self) -> Tensor[DType.int64]:
        var report = Tensor[DType.int64](1)
        report[0] = len(self.unique_dict)
        return report

    fn __str__(self) -> String:
        return String("\nNumber of duplicated reads is") + str(self.report())

    fn plot(inout self) raises:
        ###################################################################
        ###                     Duplicate Reads                         ###
        ###################################################################

        self.predict_reads()
        total_percentages = List[Float64](capacity=16)
        for i in range(16):
            total_percentages.append(0)

        var dedup_total: Float64 = 0
        var raw_total: Float64 = 0
        for entry in self.corrected_counts.items():
            var count = entry[].value
            var dup_level = entry[].key
            dedup_total += count
            raw_total += count * dup_level

            dup_slot = min(max(dup_level - 1, 0), 15)

            # Handle edge cases for duplication levels
            if dup_slot > 9999 or dup_slot < 0:
                dup_slot = 15
            elif dup_slot > 4999:
                dup_slot = 14
            elif dup_slot > 999:
                dup_slot = 13
            elif dup_slot > 499:
                dup_slot = 12
            elif dup_slot > 99:
                dup_slot = 11
            elif dup_slot > 49:
                dup_slot = 10
            elif dup_slot > 9:
                dup_slot = 9

            total_percentages[dup_slot] += count * dup_level

        var plt = Python.import_module("matplotlib.pyplot")
        var arr = Tensor[DType.float64](total_percentages)
        final_arr = tensor_to_numpy_1d(arr)
        # np.save("arr_DupReads.npy", arr2)
        f = plt.subplots(figsize=(10, 6))
        fig = f[0]
        ax = f[1]
        ax.plot(final_arr)
        ax.set_xticks([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])
        ax.set_xticklabels(
            [
                "1",
                "2",
                "3",
                "4",
                "5",
                "6",
                "7",
                "8",
                "9",
                ">10",
                ">50",
                ">100",
                ">500",
                ">1k",
                ">5k",
                ">10k+",
            ]
        )
        ax.set_xlabel("Sequence Duplication Level")
        ax.set_ylim(0, 100)
        fig.savefig("DuplicateLevels.png")

        ################################################################
        ####               Over-Represented Sequences                ###
        ################################################################

        # # TODO: Check also those over-representing stuff against the contaimination list.
        overrepresented_seqs = List[Tuple[String, Float64]]()
        for key in self.unique_dict.items():
            seq_precent = key[].value / self.n
            if seq_precent > 0.1:
                overrepresented_seqs.append((key[].key, seq_precent))


# Sequence Length Distribution.
# DONE!
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

    fn tally_read(inout self, record: RecordCoord):
        if record.seq_len() > self.length_vector.num_elements():
            var new_tensor = grow_tensor(
                self.length_vector, int(record.seq_len())
            )
            swap(self.length_vector, new_tensor)
        self.length_vector[int(record.seq_len() - 1)] += 1

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
        return String("\nLength Distribution: ") + str(self.length_vector)


# TODO: FIX this struct to reflect FastQC
@value
struct QualityDistribution(Analyser):
    var qu_dist: Tensor[DType.int64]
    var qu_dist_seq: Tensor[DType.int64]
    var max_length: Int
    var max_qu: UInt8
    var min_qu: UInt8

    fn __init__(out self):
        shape = TensorShape(1, 128)
        shape2 = TensorShape(128)
        self.qu_dist = Tensor[DType.int64](shape)
        self.qu_dist_seq = Tensor[DType.int64](shape2)
        self.max_length = 0
        self.max_qu = 0
        self.min_qu = 128

    fn tally_read(inout self, record: FastqRecord):
        if record.len_quality() > self.max_length:
            self.max_length = record.len_record()
            new_shape = TensorShape(self.max_length, 128)
            new_qu_dist = grow_matrix(self.qu_dist, new_shape)
            swap(self.qu_dist, new_qu_dist)

        for i in range(record.len_quality()):
            base_qu = record.QuStr[i]
            index = VariadicList[Int](i, int(base_qu))
            self.qu_dist[index] += 1
            if base_qu > self.max_qu:
                self.max_qu = base_qu
            if base_qu < self.min_qu:
                self.min_qu = base_qu

        average = int(sum_tensor(record.QuStr) / record.len_quality())
        self.qu_dist_seq[average] += 1

    fn tally_read(inout self, record: RecordCoord):
        if record.qu_len() > self.max_length:
            self.max_length = int(record.seq_len())
            new_shape = TensorShape(self.max_length, 128)
            new_qu_dist = grow_matrix(self.qu_dist, new_shape)
            swap(self.qu_dist, new_qu_dist)

        for i in range(int(record.qu_len())):
            base_qu = record.QuStr[i]
            index = VariadicList[Int](i, int(base_qu))
            self.qu_dist[index] += 1
            if base_qu > self.max_qu:
                self.max_qu = base_qu
            if base_qu < self.min_qu:
                self.min_qu = base_qu
        var sum: Int = 0
        for i in range(int(record.qu_len())):
            sum += int(record.QuStr[i])
        average = int(sum / record.qu_len())
        self.qu_dist_seq[average] += 1

    # Use this answer for plotting: https://stackoverflow.com/questions/58053594/how-to-create-a-boxplot-from-data-with-weights
    # TODO: Make an abbreviator of the plot to get always between 50-60 bars per plot
    fn slice_array(
        self, arr: PythonObject, min_index: Int, max_index: Int
    ) raises -> PythonObject:
        np = Python.import_module("numpy")
        indices = np.arange(min_index, max_index)
        return np.take(arr, indices, axis=1)

    fn plot(self) raises:
        Python.add_to_path(py_lib)
        np = Python.import_module("numpy")
        plt = Python.import_module("matplotlib.pyplot")
        py_builtin = Python.import_module("builtins")

        schema = self._guess_schema()
        arr = matrix_to_numpy(self.qu_dist)
        min_index = schema.OFFSET
        max_index = max(40, self.max_qu)
        arr = self.slice_array(arr, int(min_index), int(max_index))

        ################ Quality Boxplot ##################

        mean_line = np.sum(
            arr * np.arange(1, arr.shape[1] + 1), axis=1
        ) / np.sum(arr, axis=1)
        cum_sum = np.cumsum(arr, axis=1)
        total_counts = np.reshape(np.sum(arr, axis=1), (len(arr), 1))
        median = np.argmax(cum_sum > total_counts / 2, axis=1)
        Q75 = np.argmax(cum_sum > total_counts * 0.75, axis=1)
        Q25 = np.argmax(cum_sum > total_counts * 0.25, axis=1)
        IQR = Q75 - Q25

        whislo = np.full(len(IQR), None)
        whishi = np.full(len(IQR), None)

        x = plt.subplots()
        fig = x[0]
        ax = x[1]
        l = py_builtin.list()
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

        ###############################################################
        ####                Average quality /seq                   ####
        ###############################################################

        # Finding the last non-zero index
        index = 0
        for i in range(self.qu_dist_seq.num_elements() - 1, -1, -1):
            if self.qu_dist_seq[i] != 0:
                index = i
                break

        arr2 = tensor_to_numpy_1d(self.qu_dist_seq)
        arr2 = arr2[int(schema.OFFSET) : index + 2]
        z = plt.subplots()
        fig3 = z[0]
        ax3 = z[1]
        ax3.plot(arr2)
        fig3.savefig("Average_quality_sequence.png")

    fn report(self) -> Tensor[DType.int64]:
        var final_shape = TensorShape(int(self.max_qu), self.max_length)
        var final_t = Tensor[DType.int64](final_shape)

        for i in range(self.max_qu):
            for j in range(self.max_length):
                var index = VariadicList[Int](int(i), j)
                final_t[index] = self.qu_dist[index]
        return final_t

    fn __str__(self) -> String:
        return String("\nQuality_dist_matrix: ") + str(self.report())

    fn _guess_schema(self) -> QualitySchema:
        alias SANGER_ENCODING_OFFSET = 33
        alias ILLUMINA_1_3_ENCODING_OFFSET = 64

        if self.min_qu < 64:
            return illumina_1_8_schema
        elif self.min_qu == ILLUMINA_1_3_ENCODING_OFFSET + 1:
            return illumina_1_3_schema
        elif self.min_qu <= 126:
            return illumina_1_5_schema
        else:
            print("Unable to parse Quality Schema, returning generic schema")
            return generic_schema


@value
struct PerTileQuality(Analyser):
    var n: Int
    var count_map: Dict[Int, Int]
    var qual_map: Dict[Int, List[Int64]]
    var max_length: Int

    fn __init__(out self):
        # TODO: Swap the Dict with a Tensor as the Dict lookup is currently very expensive.
        self.count_map = Dict[Int, Int](power_of_two_initial_capacity=4096)
        self.qual_map = Dict[Int, List[Int64]]()
        self.n = 0
        self.max_length = 0

    # TODO: Add tracking for the number of items inside the hashmaps to limit it to 2_500 items.
    fn tally_read(mut self, record: FastqRecord):
        self.n += 1
        if self.n >= 10_000:
            if self.n % 10 != 0:
                return

        var x = self._find_tile_info(record)
        var val = self._find_tile_value(record, x)
        x = val % 8

        if val in self.count_map:
            try:
                self.count_map[val] += 1
            except:
                pass
        else:
            self.count_map[val] = 1

        # TODO: Make the length Adjustible via swap
        if val not in self.qual_map:
            self.qual_map[val] = List[Int64](capacity=record.len_record())

        try:
            if len(self.qual_map[val]) < record.len_record():
                new_tensor = List[Int64](capacity=record.len_record())
                for i in range(len(self.qual_map[val])):
                    new_tensor[i] = self.qual_map[val][i]
                self.qual_map[val] = new_tensor
        except:
            pass

        for i in range(record.len_record()):
            try:
                var temp = self.qual_map[val][i]
                self.qual_map[val].unsafe_set(i, temp + int(record.QuStr[i]))
            except error:
                print(error._message())

        if self.max_length < record.len_record():
            self.max_length = record.len_record()

    # TODO: Construct a n_keys*max_length array to hold all information.
    fn plot(self) raises:
        print("tile _plot")
        Python.add_to_path(py_lib)
        np = Python.import_module("numpy")
        sns = Python.import_module("seaborn")
        py_builtin = Python.import_module("builtins")
        plt = Python.import_module("matplotlib.pyplot")

        arr = np.zeros(self.max_length)
        for i in self.qual_map.keys():
            arr = np.vstack((arr, tensor_to_numpy_1d(self.qual_map[i[]])))

        var ks = py_builtin.list()
        for i in self.qual_map.keys():
            ks.append(i[])
        sns.heatmap(arr[1:,], cmap="Blues_r", yticklabels=ks)
        plt.savefig("TileQuality.png")

    fn report(self) -> Tensor[DType.int64]:
        return Tensor[DType.int64]()

    fn __str__(self) -> String:
        return ""

    # TODO: This function should return tile information
    @always_inline
    fn _find_tile_info(self, record: FastqRecord) -> Int:
        header = record.get_header().as_bytes()
        alias sep: UInt8 = ord(":")
        count = 0
        for i in range(len(header)):
            if header[i] == sep:
                count += 1
        var split_position: Int
        if count >= 6:
            split_position = 4
        elif count >= 4:
            split_position = 2
        else:
            return -1
        return split_position

    @always_inline
    fn _find_tile_value(self, record: FastqRecord, pos: Int) -> Int:
        alias sep: UInt8 = ord(":")
        var index_1 = 0
        var index_2 = 0
        var count = 0
        var header = record.get_header().as_bytes()
        var header_slice = record.get_header()
        # TODO: Add Error Handling
        for i in range(len(header)):
            if header[i] == sep:
                count += 1
                if count == pos:
                    index_1 = i + 1
                if count == pos + 1:
                    index_2 = i
                    break

        var s = str(header_slice)

        try:
            return atol(s[index_1:index_2])
        except:
            return 0


# TODO: Test if rolling hash function with power of two modulu's would work.
@value
struct KmerContent[KMERSIZE: Int]:
    var kmers: List[Tensor[DType.int64]]
    var max_length: Int

    fn __init__(out self):
        self.kmers = List[Tensor[DType.int64]](capacity=pow(4, KMERSIZE))
        for i in range(pow(4, KMERSIZE)):
            self.kmers.append(Tensor[DType.int64](TensorShape(1)))
        self.max_length = 0

    @always_inline
    fn tally_read(mut self, record: FastqRecord, read_num: Int64):
        alias N_b = ord("N")
        alias n_b = ord("n")

        if read_num % 50 != 0:
            return

        if len(record) > self.max_length:
            self.max_length = len(record)
            var new_kmers = List[Tensor[DType.int64]](capacity=pow(4, KMERSIZE))
            for i in range(pow(4, KMERSIZE)):
                new_kmers.append(grow_tensor(self.kmers[i], self.max_length))

            self.kmers = new_kmers

        var s = record.get_seq().as_bytes()
        # INFO: As per FastQC: limit the Kmers to the first 500 BP for long reads
        for i in range(min(record.len_record(), 500) - KMERSIZE):
            var kmer = s[i : i + KMERSIZE]
            var contains_n = False
            # TODO: Check how this optimized in Cpp
            for l in kmer:
                if l[] == N_b or l[] == n_b:
                    contains_n = True
            if contains_n:
                continue
            self.kmers[self.kmer_to_index(kmer)][i] += 1

    # From: https://github.com/smithlabcode/falco/blob/f4f0e6ca35e262cbeffc81fdfc620b3413ecfe2c/src/smithlab_utils.hpp#L357
    @always_inline
    fn kmer_to_index(self, kmer: Span[T=Byte]) -> Int:
        var index: UInt = 0
        var multiplier = 1
        for i in range(len(kmer), -1, -1):
            index += int(base2int(kmer[i]))
            multiplier *= 4
        return index

    # TODO: Figure out how the enrichment calculation is carried out.
    # Check: https://github.com/smithlabcode/falco/blob/f4f0e6ca35e262cbeffc81fdfc620b3413ecfe2c/src/Module.cpp#L2068
    fn plot(self) raises:
        Python.add_to_path(py_lib)
        var np = Python.import_module("numpy")
        var agg_tensor = Tensor[DType.int64](
            TensorShape(pow(4, KMERSIZE), self.max_length)
        )
        for i in range(len(self.kmers)):
            for j in range(self.kmers[i].num_elements()):
                agg_tensor[Index(i, j)] = self.kmers[i][j]

        mat = matrix_to_numpy(agg_tensor)
        np.save("Kmers.npy", mat)

    # TODO: Sort the Kmers to report
    # Ported from Falco C++ implementation: https://github.com/smithlabcode/falco/blob/f4f0e6ca35e262cbeffc81fdfc620b3413ecfe2c/src/Module.cpp#L2057
    fn get_kmer_stats(
        self, kmer_count: PythonObject, num_kmers: Int
    ) raises -> PythonObject:
        Python.add_to_path(py_lib)
        var np = Python.import_module("numpy")

        min_obs_exp_to_report = 1e-2

        num_kmer_bases = min(self.max_length, 500)
        obs_exp_max = np.zeros(num_kmers, dtype=np.float64)
        where_obs_exp_is_max = np.zeros(num_kmers, dtype=np.int32)
        total_kmer_counts = np.zeros(num_kmers, dtype=np.int64)

        total_kmer_counts = kmer_count[:num_kmer_bases, :].sum(axis=0)
        num_seen_kmers = np.count_nonzero(total_kmer_counts)

        dividend = (
            float(num_seen_kmers) if num_seen_kmers
            > 0 else np.finfo(np.float64).eps
        )

        for pos in range(num_kmer_bases):
            observed_counts = kmer_count[pos : pos + 1, :]
            expected_counts = kmer_count[pos : pos + 1, :] / dividend
            obs_exp_ratios = np.divide(
                observed_counts,
                expected_counts,
                out=np.zeros_like(observed_counts, dtype=np.float64),
                where=expected_counts > 0,
            )

            # Update maximum obs/exp ratios and positions
            mask = obs_exp_ratios > obs_exp_max
            obs_exp_max = np.where(mask, obs_exp_ratios, obs_exp_max)
            where_obs_exp_is_max = np.where(
                mask, pos + 1 - 7, where_obs_exp_is_max
            )

        kmers_to_report = PythonObject([])

        # Filter and sort k-mers with significant obs/exp ratios
        significant_mask = obs_exp_max > min_obs_exp_to_report
        significant_kmers = np.where(significant_mask)[0]
        for kmer in significant_kmers:
            kmers_to_report.append((kmer, obs_exp_max[kmer]))

        return kmers_to_report


# TODO: Check how to add the analyzer Trait again
# TODO: Also plot the Over-represented sequences.
@value
struct AdapterContent[bits: Int = 3]():
    var kmer_len: Int
    var hash_counts: Tensor[DType.int64]
    var hash_list: List[UInt64]
    var max_length: Int

    fn __init__(inout self, hashes: List[UInt64], kmer_len: Int = 0):
        self.kmer_len = min(kmer_len, 64 // bits)
        self.hash_list = hashes
        shape = TensorShape(len(self.hash_list), 1)
        self.hash_counts = Tensor[DType.int64](shape)
        self.max_length = 0

    fn report(self) -> Tensor[DType.int64]:
        return self.hash_counts

    # TODO: Check if it will be easier to use the bool_tuple and hashes as a list instead
    @always_inline
    fn tally_read(mut self, record: FastqRecord, read_no: Int64):
        var hash: UInt64 = 0
        var end = 0
        # Make a custom bit mask of 1s by certain length
        var mask: UInt64 = (0b1 << self.kmer_len * bits) - 1
        var neg_mask = mask >> bits
        var bit_shift = (0b1 << bits) - 1

        if record.len_record() > self.max_length:
            self.max_length = record.len_record()
            new_shape = TensorShape(len(self.hash_list), self.max_length)
            self.hash_counts = grow_matrix(self.hash_counts, new_shape)

        # Check initial Kmer
        if len(self.hash_list) > 0:
            self._check_hashes(hash, 1)

        for i in range(end, record.len_record()):
            # Remove the most signifcant xx bits
            hash = hash & neg_mask

            # Mask for the least sig. three bits, add to hash
            var rem = record.SeqStr[i] & bit_shift
            hash = (hash << bits) + int(rem)
            if len(self.hash_list) > 0:
                self._check_hashes(hash, i + 1)

    @always_inline
    fn plot(self, total_reads: Int64) raises:
        plt = Python.import_module("matplotlib.pyplot")
        arr = matrix_to_numpy(self.hash_counts)
        arr = (arr / total_reads) * 100
        plt.plot(arr.T)
        plt.ylim(0, 100)
        plt.legend(
            [
                "Illumina Universal Adapter",
                "Illumina Small RNA 3' Adapter",
                "Illumina Small RNA 5' Adapter",
                "Nextera Transposase Sequence",
                "PolyA",
                "PolyG",
            ]
        )
        plt.xlabel("Position")
        plt.ylabel("Percentage of Reads")
        plt.title("Adapter Content")
        plt.savefig("AdapterContent.png")

    @always_inline
    fn _check_hashes(inout self, hash: UInt64, pos: Int):
        for i in range(len(self.hash_list)):
            if hash == self.hash_list[i]:
                self.hash_counts[Index(i, pos)] += 1

    fn __str__(self) -> String:
        return String("\nhash count table is ") + str(self.hash_counts)


@always_inline
fn base2int(byte: Byte) -> UInt8:
    alias A_b = 65
    alias a_b = 95
    alias C_b = 67
    alias c_b = 97
    alias G_b = 71
    alias g_b = 103
    alias T_b = 84
    alias t_b = 116
    if byte == A_b or byte == a_b:
        return 0
    if byte == C_b or byte == c_b:
        return 1
    if byte == G_b or byte == g_b:
        return 2
    if byte == T_b or byte == t_b:
        return 3
    return 4


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


# TODO: Make this also parametrized on the number of bits per bp, this now works only for 3bits
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


fn sum_tensor[T: DType](tensor: Tensor[T]) -> Int:
    acc = 0
    for i in range(tensor.num_elements()):
        acc += int(tensor[i])
    return acc
