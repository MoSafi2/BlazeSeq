import math
from algorithm import vectorize
from blazeseq.CONSTS import *
from tensor import Tensor
from collections.vector import *
from tensor import Tensor, TensorShape
from collections.list import List
from memory import memcpy
from python import PythonObject, Python

######################### Character find functions ###################################


alias py_lib: String = "./.pixi/envs/default/lib/python3.12/site-packages/"


@always_inline
fn arg_true[simd_width: Int](v: SIMD[DType.bool, simd_width]) -> Int:
    for i in range(simd_width):
        if v[i]:
            return i
    return -1


@always_inline
fn find_chr_next_occurance_simd[
    T: DType
](in_tensor: Tensor[T], chr: Int, start: Int = 0) -> Int:
    """
    Function to find the next occurance of character using SIMD instruction.
    Checks are in-bound. no-risk of overflowing the tensor.
    """
    var len = in_tensor.num_elements() - start
    var aligned = start + math.align_down(len, simd_width)

    for s in range(start, aligned, simd_width):
        var v = in_tensor.load[width=simd_width](s)
        x = v.cast[DType.uint8]()
        var mask = x == chr
        if mask.reduce_or():
            return s + arg_true(mask)

    for i in range(aligned, in_tensor.num_elements()):
        if in_tensor[i] == chr:
            return i
    return -1


@always_inline
fn find_chr_next_occurance_iter[
    T: DType
](in_tensor: Tensor[T], chr: Int, start: Int = 0) -> Int:
    """
    Generic Function to find the next occurance of character Iterativly.
    No overhead for tensors < 1,000 items while being easier to debug.
    """
    for i in range(start, in_tensor.num_elements()):
        if in_tensor[i] == chr:
            return i
    return -1


fn find_chr_last_occurance[
    T: DType
](in_tensor: Tensor[T], start: Int, end: Int, chr: Int) -> Int:
    for i in range(end - 1, start - 1, -1):
        if in_tensor[i] == chr:
            return i
    return -1


# @always_inline
# fn find_chr_all_occurances[T: DType](in_tensor: Tensor[T], chr: Int) -> List[Int]:
#     var holder = List[Int]()

#     @parameter
#     fn inner[simd_width: Int](size: Int):
#         var simd_vec = in_tensor.load[simd_width](size)
#         var bool_vec = simd_vec == chr
#         if bool_vec.reduce_or():
#             for i in range(len(bool_vec)):
#                 if bool_vec[i]:
#                     holder.append(size + i)

#     vectorize[inner, simd_width](in_tensor.num_elements())
#     return holder


################################ Tensor slicing ################################################


@always_inline
fn slice_tensor[
    T: DType, USE_SIMD: Bool = True
](in_tensor: Tensor[T], start: Int, end: Int) -> Tensor[T]:
    if start >= end:
        return Tensor[T](0)

    @parameter
    if USE_SIMD:
        return slice_tensor_simd(in_tensor, start, end)
    else:
        return slice_tensor_iter(in_tensor, start, end)


@always_inline
fn slice_tensor_simd[
    T: DType
](in_tensor: Tensor[T], start: Int, end: Int) -> Tensor[T]:
    """
    Generic Function that returns a python-style tensor slice from start till end (not inclusive).
    """

    var out_tensor: Tensor[T] = Tensor[T](end - start)

    @parameter
    fn inner[simd_width: Int](size: Int):
        var transfer = in_tensor.load[width=simd_width](start + size)
        out_tensor.store[width=simd_width](size, transfer)

    vectorize[inner, simd_width](out_tensor.num_elements())

    return out_tensor


@always_inline
fn slice_tensor_iter[
    T: DType
](in_tensor: Tensor[T], start: Int, end: Int) -> Tensor[T]:
    var out_tensor = Tensor[T](end - start)
    for i in range(start, end):
        out_tensor[i - start] = in_tensor[i]
    return out_tensor


@always_inline
fn write_to_buff[T: DType](src: Tensor[T], mut dest: Tensor[T], start: Int):
    """
    Copy a small tensor into a larger tensor given an index at the large tensor.
    Implemented iteratively due to small gain from copying less then 1MB tensor using SIMD.
    Assumes copying is always in bounds. Bound checking is the responsbility of the caller.
    """
    for i in range(src.num_elements()):
        dest[start + i] = src[i]


# The Function does not provide bounds checks on purpose, the bounds checks is the callers responsibility
@always_inline
fn cpy_tensor[
    T: DType
    # simd_width: Int
](
    mut dest: Tensor[T],
    src: Tensor[T],
    num_elements: Int,
    dest_strt: Int = 0,
    src_strt: Int = 0,
):
    var dest_ptr: UnsafePointer[Scalar[T]] = dest._ptr + dest_strt
    var src_ptr: UnsafePointer[Scalar[T]] = src._ptr + src_strt
    memcpy(dest_ptr, src_ptr, num_elements)

    ## Alternative method
    # @parameter
    # fn inner[simd_width: Int](size: Int):
    #     var transfer = src.load[width=simd_width](src_strt + size)
    #     dest.store[width=simd_width](dest_strt + size, transfer)

    # vectorize[inner, simd_width](num_elements)


################################ Next line Ops ##############################

# The next line OPs is dependent on find_chr_next_occurance and slice_tensor


@always_inline
fn get_next_line[
    T: DType, USE_SIMD: Bool = True
](in_tensor: Tensor[T], start: Int) -> Tensor[T]:
    """Function to get the next line using either SIMD instruction (default) or iterativly.
    """

    var in_start = start
    while in_tensor[in_start] == new_line:  # Skip leadin \n
        print("skipping \n")
        in_start += 1
        if in_start >= in_tensor.num_elements():
            return Tensor[T](0)

    @parameter
    if USE_SIMD:
        var next_line_pos = find_chr_next_occurance_simd(
            in_tensor, new_line, in_start
        )
        if next_line_pos == -1:
            next_line_pos = (
                in_tensor.num_elements()
            )  # If no line separator found, return the reminder of the string, behaviour subject to change
        return slice_tensor_simd(in_tensor, in_start, next_line_pos)
    else:
        var next_line_pos = find_chr_next_occurance_iter(
            in_tensor, new_line, in_start
        )
        if next_line_pos == -1:
            next_line_pos = (
                in_tensor.num_elements()
            )  # If no line separator found, return the reminder of the string, behaviour subject to change
        return slice_tensor_iter(in_tensor, in_start, next_line_pos)


@always_inline
fn get_next_line_index[
    T: DType, USE_SIMD: Bool = True
](in_tensor: Tensor[T], start: Int) -> Int:
    var in_start = start

    @parameter
    if USE_SIMD:
        var next_line_pos = find_chr_next_occurance_simd(
            in_tensor, new_line, in_start
        )
        if next_line_pos == -1:
            return -1
        return next_line_pos
    else:
        var next_line_pos = find_chr_next_occurance_iter(
            in_tensor, new_line, in_start
        )
        if next_line_pos == -1:
            return -1
        return next_line_pos


############################# Fastq recod-related Ops ################################


fn find_last_read_header(
    in_tensor: Tensor[U8], start: Int = 0, end: Int = -1
) -> Int:
    var end_inner: Int
    if end == -1:
        end_inner = in_tensor.num_elements()
    else:
        end_inner = end

    var last_chr = find_chr_last_occurance(
        in_tensor, start, end_inner, read_header
    )
    if in_tensor[last_chr - 1] == new_line:
        return last_chr
    else:
        end_inner = last_chr
        if (end_inner - start) < 4:
            return -1
        last_chr = find_last_read_header(in_tensor, start, end_inner)
    return last_chr


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
        hash = (hash << 3) + Int(rem)
    return hash


def tensor_to_numpy_1d[T: DType](tensor: Tensor[T]) -> PythonObject:
    Python.add_to_path(py_lib.as_string_slice())
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


fn encode_img_b64(fig: PythonObject) raises -> String:
    Python.add_to_path(py_lib.as_string_slice())
    py_io = Python.import_module("io")
    py_base64 = Python.import_module("base64")
    plt = Python.import_module("matplotlib.pyplot")

    buf = py_io.BytesIO()
    plt.savefig(buf, format="png", dpi=150)
    buf.seek(0)
    plt.close()
    base64_image = py_base64.b64encode(buf.read()).decode("utf-8")
    buf.close()

    return str(base64_image)




fn get_bins(max_len: Int) -> List[Int]:
    var pos: Int = 1
    var interval: Int = 1
    bins = List[Int]()
    while pos <= max_len:
        if pos > max_len:
            pos = max_len
        bins.append(pos)
        pos += interval
        if pos == 10 and max_len > 75:
            interval = 5
        if pos == 50 and max_len > 200:
            interval = 10
        if pos == 100 and max_len > 300:
            interval = 50
        if pos == 500 and max_len > 1000:
            interval = 100
        if pos == 1000 and max_len > 2000:
            interval = 500

    if bins[-1] < max_len:
        bins.append(max_len)

    return bins



@value
struct QualitySchema(Stringable, CollectionElement):
    var SCHEMA: StringLiteral
    var LOWER: UInt8
    var UPPER: UInt8
    var OFFSET: UInt8

    fn __init__(
        mut self, schema: StringLiteral, lower: Int, upper: Int, offset: Int
    ):
        self.SCHEMA = schema
        self.UPPER = upper
        self.LOWER = lower
        self.OFFSET = offset

    fn __str__(self) -> String:
        return (
            String("Quality schema: ")
            + self.SCHEMA
            + "\nLower: "
            + str(self.LOWER)
            + "\nUpper: "
            + str(self.UPPER)
            + "\nOffset: "
            + str(self.OFFSET)
        )
