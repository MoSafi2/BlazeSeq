import math
import time
from algorithm import vectorize_unroll, vectorize
from MojoFastTrim.CONSTS import *


######################### Character find functions ###################################


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
    The function assumes that the tensor is always in-bounds. any bound checks should be in the calling function.
    """
    let len = in_tensor.num_elements() - start
    let aligned = start + math.align_down(len, simd_width)

    for s in range(start, aligned, simd_width):
        let v = in_tensor.simd_load[simd_width](s)
        let mask = v == chr
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


@always_inline
fn find_chr_all_occurances[
    T: DType
](in_tensor: Tensor[T], chr: Int) -> DynamicVector[Int]:
    var holder = DynamicVector[Int]()

    @parameter
    fn inner[simd_width: Int](size: Int):
        let simd_vec = in_tensor.simd_load[simd_width](size)
        let bool_vec = simd_vec == chr
        if bool_vec.reduce_or():
            for i in range(len(bool_vec)):
                if bool_vec[i]:
                    holder.push_back(size + i)

    vectorize[simd_width, inner](in_tensor.num_elements())
    return holder


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
fn slice_tensor_simd[T: DType](in_tensor: Tensor[T], start: Int, end: Int) -> Tensor[T]:
    """
    Generic Function that returns a python-style tensor slice from start till end (not inclusive).
    """

    var out_tensor: Tensor[T] = Tensor[T](end - start)

    @parameter
    fn inner[simd_width: Int](size: Int):
        let transfer = in_tensor.simd_load[simd_width](start + size)
        out_tensor.simd_store[simd_width](size, transfer)

    vectorize[simd_width, inner](out_tensor.num_elements())

    return out_tensor


@always_inline
fn slice_tensor_iter[T: DType](in_tensor: Tensor[T], start: Int, end: Int) -> Tensor[T]:
    var out_tensor = Tensor[T](end - start)
    for i in range(start, end):
        out_tensor[i - start] = in_tensor[i]
    return out_tensor


@always_inline
fn write_to_buff[T: DType](src: Tensor[T], inout dest: Tensor[T], start: Int):
    """
    Copy a small tensor into a larger tensor given an index at the large tensor.
    Implemented iteratively due to small gain from copying less then 1MB tensor using SIMD.
    Assumes copying is always in bounds. Bound checking is th responsbility of the caller.
    """
    for i in range(src.num_elements()):
        dest[start + i] = src[i]


################################ Next line Ops ##############################

# The next line OPs is dependent on find_chr_next_occurance and slice_tensor


# BUG: If there is no new line sperator, the function results in segmentation-fault
# Desired behaviour? could be either returning the whole tensor or returning an empty Tensor.


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
        var next_line_pos = find_chr_next_occurance_simd(in_tensor, new_line, in_start)
        if next_line_pos == -1:
            next_line_pos = (
                in_tensor.num_elements()
            )  # If no line separator found, return the reminder of the string, behaviour subject to change
        return slice_tensor_simd(in_tensor, in_start, next_line_pos)
    else:
        var next_line_pos = find_chr_next_occurance_iter(in_tensor, new_line, in_start)
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
    while in_tensor[in_start] == new_line:  # Skip leadin \n
        print("skipping \n")
        in_start += 1
        if in_start >= in_tensor.num_elements():
            return -1

    @parameter
    if USE_SIMD:
        let next_line_pos = find_chr_next_occurance_simd(in_tensor, new_line, in_start)
        if next_line_pos == -1:
            return (
                in_tensor.num_elements()
            )  # If no line separator found, return the reminder of the string, behaviour subject to change
        return next_line_pos
    else:
        let next_line_pos = find_chr_next_occurance_iter(in_tensor, new_line, in_start)
        if next_line_pos == -1:
            return in_tensor.num_elements()
        return next_line_pos


############################# Fastq recod-related Ops ################################


fn find_last_read_header(
    in_tensor: Tensor[DType.int8], start: Int = 0, end: Int = -1
) -> Int:
    var end_inner: Int
    if end == -1:
        end_inner = in_tensor.num_elements()
    else:
        end_inner = end

    var last_chr = find_chr_last_occurance(in_tensor, start, end_inner, read_header)
    if in_tensor[last_chr - 1] == new_line:
        return last_chr
    else:
        end_inner = last_chr
        if (end_inner - start) < 4:
            return -1
        last_chr = find_last_read_header(in_tensor, start, end_inner)
    return last_chr


################################### File read ops #############################################


@always_inline
fn read_bytes(
    handle: FileHandle, beginning: UInt64, length: Int64
) raises -> Tensor[DType.int8]:
    """Function to read a file chunk given an offset to seek.
    Returns empty tensor or under-sized tensor if reached EOF.
    """
    _ = handle.seek(beginning)
    return handle.read_bytes(length)
