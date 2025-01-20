"""This module should hold aggregate statistics about all the record which have been queried by the Parser, regardless of the caller function. """

# TODO: Check if you can convert large matrcies to a list of tensors and wether this will result in a better performance. Especially for for Quality Distribution, Tile

from tensor import TensorShape, Tensor
from collections.dict import DictEntry, Dict
from utils import Index
from memory import Span
from python import Python, PythonObject
from blazeseq.record import FastqRecord, RecordCoord
from blazeseq.helpers import (
    cpy_tensor,
    QualitySchema,
    base2int,
    _seq_to_hash,
    tensor_to_numpy_1d,
    matrix_to_numpy,
    grow_tensor,
    grow_matrix,
    sum_tensor,
    encode_img_b64,
    get_bins,
    bin_array,
)
from blazeseq.html_maker import result_panel, insert_result_panel, html_template
from blazeseq.CONSTS import (
    illumina_1_5_schema,
    illumina_1_3_schema,
    illumina_1_8_schema,
    generic_schema,
)
from blazeseq.config import hash_list, hash_names

# TODO: Make this dynamic
alias py_lib: String = ".pixi/envs/default/lib/python3.12/site-packages/"
alias plt_figure = PythonObject


trait Analyser(CollectionElement):
    fn tally_read(mut self, record: FastqRecord):
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

    fn __init__(out self):
        self.num_reads = 0
        self.total_bases = 0
        self.len_dist = LengthDistribution()
        self.bp_dist = BasepairDistribution()
        self.cg_content = CGContent()
        self.qu_dist = QualityDistribution()
        self.dup_reads = DupReads()
        self.tile_qual = PerTileQuality()
        self.adpt_cont = AdapterContent(hash_list(), 12)

    @always_inline
    fn tally(mut self, record: FastqRecord):
        self.num_reads += 1
        self.total_bases += record.len_record()
        self.bp_dist.tally_read(record)
        self.len_dist.tally_read(record)
        self.cg_content.tally_read(record)  # Almost Free
        self.dup_reads.tally_read(record)
        self.qu_dist.tally_read(record)
        self.adpt_cont.tally_read(record, self.num_reads)
        self.tile_qual.tally_read(record)

    @always_inline
    fn tally(mut self, record: RecordCoord):
        self.num_reads += 1
        self.total_bases += int(record.seq_len())
        self.bp_dist.tally_read(record)
        self.len_dist.tally_read(record)
        self.cg_content.tally_read(record)
        self.qu_dist.tally_read(record)
        pass

    @always_inline
    fn plot(mut self) raises -> List[PythonObject]:
        plots = List[PythonObject]()

        img1, img2 = self.bp_dist.plot(self.num_reads)
        plots.append(img1)
        plots.append(img2)
        plots.append(self.cg_content.plot())
        plots.append(self.len_dist.plot())
        img, _ = self.dup_reads.plot()
        plots.append(img)
        img1, img2 = self.qu_dist.plot()
        plots.append(img1)
        plots.append(img2)
        plots.append(self.tile_qual.plot())
        plots.append(self.adpt_cont.plot(self.num_reads))

        return plots

    fn make_html(mut self, file_name: String) raises:
        var results = List[result_panel]()
        res1, res2 = self.bp_dist.make_html(self.num_reads)

        results.append(res1)
        results.append(res2)
        results.append(self.cg_content.make_html())
        results.append(self.len_dist.make_html())
        results.append(self.dup_reads.make_html())

        res1, res2 = self.qu_dist.make_html()
        results.append(res1)
        results.append(res2)
        results.append(self.tile_qual.make_html())
        results.append(self.adpt_cont.make_html(self.num_reads))

        var html: String = html_template
        while html.find("<<filename>>") > -1:
            html = html.replace("<<filename>>", file_name)

        for entry in results:
            html = insert_result_panel(html, entry[])

        with open("{}_blazeseq.html".format(file_name), "w") as f:
            f.write(html)


@value
struct BasepairDistribution(Analyser):
    var bp_dist: Tensor[DType.int64]
    var max_length: Int
    alias WIDTH = 5

    fn __init__(out self):
        var shape = TensorShape(VariadicList[Int](1, self.WIDTH))
        self.bp_dist = Tensor[DType.int64](shape)
        self.max_length = 0

    fn tally_read(mut self, record: FastqRecord):
        if record.len_record() > self.max_length:
            self.max_length = record.len_record()
            var new_tensor = grow_matrix(
                self.bp_dist, TensorShape(self.max_length, self.WIDTH)
            )
            swap(self.bp_dist, new_tensor)

        for i in range(record.len_record()):
            # Remineder of first 5 bits seperates N from T
            var base_val = int((record.SeqStr[i] & 0b11111) % self.WIDTH)
            var index = VariadicList[Int](i, base_val)
            self.bp_dist[index] += 1

    fn tally_read(mut self, record: RecordCoord):
        if record.seq_len() > self.max_length:
            self.max_length = int(record.seq_len())
            var new_tensor = grow_matrix(
                self.bp_dist, TensorShape(self.max_length, self.WIDTH)
            )
            swap(self.bp_dist, new_tensor)

        for i in range(int(record.seq_len())):
            # Remineder of first 5 bits seperates N from T
            var base_val = int((record.SeqStr[i] & 0b11111) % self.WIDTH)
            var index = VariadicList[Int](i, base_val)
            self.bp_dist[index] += 1

    # TODO: Also bind this array
    # TODO: Fix erros in this plot after binning
    fn plot(
        self, total_reads: Int64
    ) raises -> Tuple[PythonObject, PythonObject]:
        Python.add_to_path(py_lib.as_string_slice())
        var plt = Python.import_module("matplotlib.pyplot")
        var arr = matrix_to_numpy(self.bp_dist)
        # bins = get_bins(self.max_length)
        # arr, py_bins = bin_array(arr, bins, func="mean")

        arr = (arr / total_reads) * 100
        var arr1 = arr[:, 0:4]  # C,G,T,A pairs
        var arr2 = arr[:, 4:5]  # N content
        var x = plt.subplots()
        var fig = x[0]
        var ax = x[1]
        ax.plot(arr1)
        ax.set_ylim(0, 100)
        ax.set_label(["%T", "%A", "%G", "%C"])
        ax.set_xlabel("Position in read (bp)")
        ax.set_title("Base Distribution")
        # ax.set_xticklabels(py_bins, rotation=45)

        var y = plt.subplots()
        var fig2 = y[0]
        var ax2 = y[1]
        ax2.plot(arr2)
        ax2.set_ylim(0, 100)
        ax2.set_label(["%N"])
        ax2.set_xlabel("Position in read (bp)")
        ax2.set_title("N percentage")
        # ax2.set_xticklabels(py_bins, rotation=45)
        return fig, fig2

    @always_inline
    fn make_grade(self, grades: Dict[String, Int]):
        pass

    fn make_html(
        self, total_reads: Int64
    ) raises -> Tuple[result_panel, result_panel]:
        fig1, fig2 = self.plot(total_reads)
        var encoded_fig1 = encode_img_b64(fig1)
        var encoded_fig2 = encode_img_b64(fig2)
        var result_1 = result_panel(
            "base_pair_distribution",
            "pass",
            "Base Pair Distribtion",
            encoded_fig1,
        )
        var result_2 = result_panel(
            "n_percentage",
            "pass",
            "N Percentage (%)",
            encoded_fig2,
        )

        return result_1, result_2


# Done!
@value
struct CGContent(Analyser):
    var cg_content: Tensor[DType.int64]
    var theoritical_distribution: Tensor[DType.int64]

    fn __init__(out self):
        self.cg_content = Tensor[DType.int64](101)
        self.theoritical_distribution = Tensor[DType.int64](101)

    fn tally_read(mut self, record: FastqRecord):
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

    fn tally_read(mut self, record: RecordCoord):
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

    # TODO: Convert as much as possible away from numpy
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

    fn plot(self) raises -> PythonObject:
        Python.add_to_path(py_lib.as_string_slice())
        var plt = Python.import_module("matplotlib.pyplot")
        var arr = tensor_to_numpy_1d(self.cg_content)
        var theoritical_distribution = self.calculate_theoritical_distribution()
        var x = plt.subplots()
        var fig = x[0]
        var ax = x[1]
        ax.plot(arr, label="GC count per read")
        ax.plot(theoritical_distribution, label="Theoritical Distribution")
        ax.set_title("Per sequence GC content")
        ax.set_xlabel("Mean GC content (%)")

        return fig

    fn make_html(
        self,
    ) raises -> result_panel:
        fig = self.plot()
        var encoded_fig1 = encode_img_b64(fig)
        var result_1 = result_panel(
            "cg_content",
            "pass",
            "Per sequence GC content",
            encoded_fig1,
        )

        return result_1


# TODO: You should extraplolate from the number of reads in the unique reads to how it would look like for everything.
@value
struct DupReads(Analyser):
    var unique_dict: Dict[String, Int]
    var unique_reads: Int
    var count_at_max: Int
    var n: Int
    var corrected_counts: Dict[Int, Float64]
    alias MAX_READS = 100_000

    fn __init__(out self):
        self.unique_dict = Dict[String, Int](
            power_of_two_initial_capacity=2**18
        )
        self.unique_reads = 0
        self.count_at_max = 0
        self.n = 0
        self.corrected_counts = Dict[Int, Float64]()

    fn tally_read(mut self, record: FastqRecord):
        self.n += 1
        read_len = min(record.len_record(), 50)
        s_ = List(record.get_seq().as_bytes()[0:read_len])
        s_.append(0)
        var s = String(s_)
        if s in self.unique_dict:
            try:
                self.unique_dict[s] += 1
                return
            except error:
                print(error._message())
                pass

        if self.unique_reads <= self.MAX_READS:
            self.unique_dict[s] = 1
            self.unique_reads += 1

            if self.unique_reads == self.MAX_READS:
                self.count_at_max = self.n
        else:
            return

    fn predict_reads(mut self):
        # Construct Duplication levels dict
        var dup_dict = Dict[Int, Int]()
        for entry in self.unique_dict.items():
            if Int(entry[].value) in dup_dict:
                try:
                    dup_dict[Int(entry[].value)] += 1
                except error:
                    print(error._message())
            else:
                dup_dict[Int(entry[].value)] = 1

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

    fn plot(
        mut self,
    ) raises -> Tuple[PythonObject, List[Tuple[String, Float64]]]:
        ###################################################################
        ###                     Duplicate Reads                         ###
        ###################################################################

        self.predict_reads()
        total_percentages = List[Float64](capacity=16)
        for _ in range(16):
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

        Python.add_to_path(py_lib.as_string_slice())
        var plt = Python.import_module("matplotlib.pyplot")
        var arr = Tensor[DType.float64](total_percentages)
        final_arr = tensor_to_numpy_1d(arr)
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
        ax.set_title("Sequences Duplication levels")
        ax.set_ylim(0, 100)

        ################################################################
        ####               Over-Represented Sequences                ###
        ################################################################

        # TODO: Check also those over-representing stuff against the contaimination list.
        overrepresented_seqs = List[Tuple[String, Float64]]()
        for key in self.unique_dict.items():
            seq_precent = key[].value / self.n
            if seq_precent > 0.1:
                overrepresented_seqs.append((key[].key, seq_precent))

        return fig, overrepresented_seqs

    # TODO: Add Table for Over-represted Seqs
    fn make_html(mut self) raises -> result_panel:
        fig, _ = self.plot()
        var encoded_fig1 = encode_img_b64(fig)
        var result_1 = result_panel(
            "dup_reads",
            "pass",
            "Sequence Duplication Levels",
            encoded_fig1,
        )

        return result_1


@value
struct LengthDistribution(Analyser):
    var length_vector: Tensor[DType.int64]

    fn __init__(out self):
        self.length_vector = Tensor[DType.int64](0)

    fn tally_read(mut self, record: FastqRecord):
        if record.len_record() > self.length_vector.num_elements():
            var new_tensor = grow_tensor(
                self.length_vector, record.len_record()
            )
            swap(self.length_vector, new_tensor)
        self.length_vector[record.len_record() - 1] += 1

    fn tally_read(mut self, record: RecordCoord):
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

    fn plot(self) raises -> PythonObject:
        Python.add_to_path(py_lib.as_string_slice())
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
        ax.set_title("Distribution of sequence lengths over all sequences")
        ax.set_xlabel("Sequence Length (bp)")

        # len_dis = result_panel("Length Distribution", (1024, 1024), fig)

        return fig

    fn make_html(self) raises -> result_panel:
        fig = self.plot()
        var encoded_fig1 = encode_img_b64(fig)
        var result_1 = result_panel(
            "seq_len_dis",
            "pass",
            "Sequence Duplication Levels",
            encoded_fig1,
        )

        return result_1


# TODO: FIX this struct to reflect FastQC
# TODO: FIX this to get bands instead per base pair to avoid problems with long reads
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

    fn tally_read(mut self, record: FastqRecord):
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

    fn tally_read(mut self, record: RecordCoord):
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

    fn plot(self) raises -> Tuple[PythonObject, PythonObject]:
        Python.add_to_path(py_lib.as_string_slice())
        np = Python.import_module("numpy")
        plt = Python.import_module("matplotlib.pyplot")

        schema = self._guess_schema()
        arr = matrix_to_numpy(self.qu_dist)
        min_index = schema.OFFSET
        max_index = max(40, self.max_qu)
        arr = self.slice_array(arr, int(min_index), int(max_index))
        # Convert the raw array to binned array to account for very long seqs.
        var bins = get_bins(arr.shape[0])
        arr, py_bins = bin_array(arr, bins)

        ################ Quality Boxplot ##################

        # TODO: Convert as much as possible away from numpy
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
        l = Python.list()
        for i in range(len(IQR)):
            var stat: PythonObject = Python.dict()
            stat["med"] = median[i]
            stat["q1"] = Q25[i]
            stat["q3"] = Q75[i]
            stat["whislo"] = whislo[i]
            stat["whishi"] = whishi[i]
            l.append(stat)

        ax.bxp(l, showfliers=False)
        ax.plot(mean_line)
        ax.set_title("Quality Scores across all bases")
        ax.set_xlabel("Position in read (bp)")
        ax.set_xticklabels(py_bins, rotation=45)

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
        fig2 = z[0]
        ax2 = z[1]
        ax2.plot(arr2)
        ax2.set_xlabel("Mean Sequence Quality (Phred Score)")
        ax2.set_title("Quality score distribution over all sequences")

        return Tuple(fig, fig2)

    fn make_html(self) raises -> Tuple[result_panel, result_panel]:
        fig1, fig2 = self.plot()
        var encoded_fig1 = encode_img_b64(fig1)
        var encoded_fig2 = encode_img_b64(fig2)
        var result_1 = result_panel(
            "qu_score_dis",
            "pass",
            "Quality Scores Distribtion",
            encoded_fig1,
        )

        var result_2 = result_panel(
            "qu_score_dis",
            "pass",
            "Mean Quality distribution",
            encoded_fig2,
        )

        return result_1, result_2

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
struct TileQualityEntry:
    var tile: Int
    var count: Int
    var quality: Tensor[DType.int64]

    fn __init__(out self, tile: Int, count: Int, length: Int):
        self.tile = tile
        self.count = count
        self.quality = Tensor[DType.int64](TensorShape(length))

    fn __hash__(self) -> Int:
        return hash(self.tile)

    fn __add__(self, other: Int) -> Int:
        return self.count + other

    fn __iadd__(mut self, other: Int):
        self.count += other


@value
struct PerTileQuality(Analyser):
    var n: Int
    var map: Dict[Int, TileQualityEntry]
    var max_length: Int

    fn __init__(out self):
        self.map = Dict[Int, TileQualityEntry](
            power_of_two_initial_capacity=2**14
        )
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

        # Low-level access to the hashmap to avoid the overhead of calling `_find_index` multiple times.
        # Should be replcaed with a cleaner version once Mojo dict is more performant.

        index = self.map._find_index(val.__hash__(), val)

        if index[0]:
            pos = index[2]
            entry = self.map._entries[pos]
            deref_value = entry.unsafe_value().value
            deref_value.count += 1
            if deref_value.quality.num_elements() < record.len_record():
                new_tensor = Tensor[DType.int64](record.len_record())
                for i in range(deref_value.quality.num_elements()):
                    new_tensor[i] = deref_value.quality[i]
                deref_value.quality = new_tensor

            for i in range(record.len_record()):
                deref_value.quality[i] += int(record.QuStr[i])

            self.map._entries[pos] = DictEntry[Int, TileQualityEntry](
                entry.unsafe_take().key, deref_value
            )

        else:
            self.map[val] = TileQualityEntry(val, 1, record.len_record())

        if self.max_length < record.len_record():
            self.max_length = record.len_record()

    # TODO: Construct a n_keys*max_length array to hold all information.
    fn plot(self) raises -> PythonObject:
        Python.add_to_path(py_lib.as_string_slice())
        np = Python.import_module("numpy")
        sns = Python.import_module("seaborn")
        plt = Python.import_module("matplotlib.pyplot")

        z = plt.subplots()
        fig = z[0]
        ax = z[1]

        arr = np.zeros(self.max_length)
        for i in self.map.keys():
            temp_arr = tensor_to_numpy_1d(self.map[i[]].quality)
            arr = np.vstack((arr, temp_arr))

        var ks = Python.list()
        for i in self.map.keys():
            ks.append(i[])
        sns.heatmap(arr[1:,], cmap="Blues_r", yticklabels=ks, ax=ax)
        ax.set_title("Quality per tile")
        ax.set_xlabel("Position in read (bp)")

        return fig

    fn make_html(self) raises -> result_panel:
        fig1 = self.plot()
        var encoded_fig1 = encode_img_b64(fig1)
        var result_1 = result_panel(
            "tile_quality",
            "pass",
            "Quality per tile",
            encoded_fig1,
        )
        return result_1

    # TODO: This function should return tile information
    @always_inline
    fn _find_tile_info(self, record: FastqRecord) -> Int:
        header = record.get_header_string().as_bytes()
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
        var header = record.get_header_string().as_bytes()
        var header_slice = record.get_header_string()
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
        for _ in range(pow(4, KMERSIZE)):
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
    fn plot(self) raises -> PythonObject:
        Python.add_to_path(py_lib.as_string_slice())
        var agg_tensor = Tensor[DType.int64](
            TensorShape(pow(4, KMERSIZE), self.max_length)
        )
        for i in range(len(self.kmers)):
            for j in range(self.kmers[i].num_elements()):
                agg_tensor[Index(i, j)] = self.kmers[i][j]

        mat = matrix_to_numpy(agg_tensor)
        return mat

    # TODO: Sort the Kmers to report
    # Ported from Falco C++ implementation: https://github.com/smithlabcode/falco/blob/f4f0e6ca35e262cbeffc81fdfc620b3413ecfe2c/src/Module.cpp#L2057
    fn get_kmer_stats(
        self, kmer_count: PythonObject, num_kmers: Int
    ) raises -> PythonObject:
        Python.add_to_path(py_lib.as_string_slice())
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

    fn __init__(out self, hashes: List[UInt64], kmer_len: Int = 0):
        self.kmer_len = min(kmer_len, 64 // bits)
        self.hash_list = hashes
        shape = TensorShape(len(self.hash_list), 1)
        self.hash_counts = Tensor[DType.int64](shape)
        self.max_length = 0

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
    fn plot(self, total_reads: Int64) raises -> PythonObject:
        Python.add_to_path(py_lib.as_string_slice())
        plt = Python.import_module("matplotlib.pyplot")
        arr = matrix_to_numpy(self.hash_counts)
        arr = (arr / total_reads) * 100

        z = plt.subplots()
        fig = z[0]
        ax = z[1]

        ax.plot(arr.T)
        ax.set_ylim(0, 100)
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

        return fig

    fn make_html(self, total_reads: Int64) raises -> result_panel:
        fig1 = self.plot(total_reads)
        var encoded_fig1 = encode_img_b64(fig1)
        var result_1 = result_panel(
            "adapter_content",
            "pass",
            "Adapter Content",
            encoded_fig1,
        )
        return result_1

    @always_inline
    fn _check_hashes(mut self, hash: UInt64, pos: Int):
        for i in range(len(self.hash_list)):
            if hash == self.hash_list[i]:
                self.hash_counts[Index(i, pos)] += 1
