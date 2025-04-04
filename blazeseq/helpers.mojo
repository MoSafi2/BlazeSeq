import math
from algorithm import vectorize
from blazeseq.CONSTS import *
from tensor import Tensor
from tensor import Tensor, TensorShape
from collections import List
from memory import memcpy, UnsafePointer
from python import PythonObject, Python

######################### Character find functions ###################################


@always_inline
fn arg_true[simd_width: Int](v: SIMD[DType.bool, simd_width]) -> Int:
    for i in range(simd_width):
        if v[i]:
            return i
    return -1


@always_inline
fn find_chr_next_occurance[
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


fn find_chr_last_occurance[
    T: DType
](in_tensor: Tensor[T], start: Int, end: Int, chr: Int) -> Int:
    for i in range(end - 1, start - 1, -1):
        if in_tensor[i] == chr:
            return i
    return -1


@always_inline
fn _align_down(value: Int, alignment: Int) -> Int:
    return value._positive_div(alignment) * alignment


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


################################ Next line Ops ##############################

# The next line OPs is dependent on find_chr_next_occurance and slice_tensor


@always_inline
fn get_next_line[T: DType](in_tensor: Tensor[T], start: Int) -> Tensor[T]:
    """Function to get the next line using either SIMD instruction (default) or iterativly.
    """

    var in_start = start
    while in_tensor[in_start] == new_line:  # Skip leadin \n
        print("skipping \n")
        in_start += 1
        if in_start >= in_tensor.num_elements():
            return Tensor[T](0)

    var next_line_pos = find_chr_next_occurance(in_tensor, new_line, in_start)
    if next_line_pos == -1:
        next_line_pos = (
            in_tensor.num_elements()
        )  # If no line separator found, return the reminder of the string, behaviour subject to change
    return slice_tensor_simd(in_tensor, in_start, next_line_pos)


@always_inline
fn get_next_line_index[T: DType](in_tensor: Tensor[T], start: Int) -> Int:
    var in_start = start

    var next_line_pos = find_chr_next_occurance(in_tensor, new_line, in_start)
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


@value
struct QualitySchema(CollectionElement, Writable):
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

    fn write_to[w: Writer](self, mut writer: w) -> None:
        writer.write(self.__str__())

    fn __str__(self) -> String:
        return (
            String("Quality schema: ")
            + self.SCHEMA
            + "\nLower: "
            + String(self.LOWER)
            + "\nUpper: "
            + String(self.UPPER)
            + "\nOffset: "
            + String(self.OFFSET)
        )
