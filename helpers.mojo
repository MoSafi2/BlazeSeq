import math
import time
from algorithm import vectorize_unroll

alias simd_width: Int = simdwidthof[DType.int8]()
alias new_line: Int = ord("\n")
alias read_header: Int = ord("@")
alias quality_header: Int = ord("+")


######################### Core functions ###################################

@always_inline
fn arg_true[simd_width: Int](v: SIMD[DType.bool, simd_width]) -> Int:
    for i in range(simd_width):
        if v[i]:
            return i
    return -1


# BUG with reaching out to garbage
@always_inline
fn find_chr_next_occurance_simd[
    T: DType
](in_tensor: Tensor[T], chr: Int, start: Int = 0) -> Int:
    """
    Generic Function to find the next occurance of character using SIMD instruction.
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
fn slice_tensor_simd[T: DType](in_tensor: Tensor[T], start: Int, end: Int) -> Tensor[T]:
    """
    Generic Function that returns a python-style tensor slice from start till end (not inclusive).
    """

    var out_tensor: Tensor[T] = Tensor[T](end - start)

    @parameter
    fn inner[simd_width: Int](size: Int):
        let transfer = in_tensor.simd_load[simd_width](start + size)
        out_tensor.simd_store[simd_width](size, transfer)

    vectorize_unroll[simd_width, 5, inner](out_tensor.num_elements())

    return out_tensor


# Done!
@always_inline
fn find_chr_next_occurance_iter[
    T: DType
](borrowed in_tensor: Tensor[T], chr: Int, start: Int = 0) -> Int:
    """
    Generic Function to find the next occurance of character Iterativly.
    No overhead for tensors < 1,000 items while being easier to debug.
    """
    for i in range(start, in_tensor.num_elements()):
        if in_tensor[i] == chr:
            return i
    return -1


@always_inline
fn find_chr_last_occurance(in_tensor: Tensor[DType.int8], chr: Int) -> Int:
    for n in range(in_tensor.num_elements() - 1, -1, -1):
        if in_tensor[n] == chr:
            return n
    return -1


# Done!
@always_inline
fn slice_tensor_iter[
    T: DType
](borrowed in_tensor: Tensor[T], start: Int, end: Int) -> Tensor[T]:
    var out_tensor = Tensor[T](end - start)
    for i in range(start, end):
        out_tensor[i - start] = in_tensor[i]
    return out_tensor


# Todo: Should signal EOF
@always_inline
fn read_bytes(
    borrowed handle: FileHandle, beginning: UInt64, length: Int64
) raises -> Tensor[DType.int8]:
    _ = handle.seek(beginning)
    return handle.read_bytes(length)


# Todo: Should signal EOF
@always_inline
fn read_text(
    borrowed handle: FileHandle, beginning: UInt64, length: Int64
) raises -> String:
    _ = handle.seek(beginning)
    return handle.read(length)


################################ Helpers ##############################


@always_inline
fn slice_tensor[
    T: DType, USE_SIMD: Bool = True
](in_tensor: Tensor[T], start: Int, end: Int) -> Tensor[T]:
    if start >= end:
        return Tensor[T](0)

    if USE_SIMD:
        return slice_tensor_simd(in_tensor, start, end)
    else:
        return slice_tensor_iter(in_tensor, start, end)


# TODO: Test
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
            return Tensor[T]()

    # Temporary Fix for the BUG in the fint_next_chr_SIMD
    if in_tensor.num_elements() - start < 1000:
        let next_line_pos = find_chr_next_occurance_iter(in_tensor, new_line, in_start)
        return slice_tensor_iter(in_tensor, in_start, next_line_pos)

    if USE_SIMD:
        let next_line_pos = find_chr_next_occurance_simd(in_tensor, new_line, in_start)
        return slice_tensor_simd(in_tensor, in_start, next_line_pos)
    else:
        let next_line_pos = find_chr_next_occurance_iter(in_tensor, new_line, in_start)
        return slice_tensor_iter(in_tensor, in_start, next_line_pos)


# TODO: Needs testing
@always_inline
fn find_last_read_header(in_tensor: Tensor[DType.int8]) -> Int:
    var last_chr = find_chr_last_occurance(in_tensor, read_header)
    if in_tensor[last_chr - 1] == new_line:
        return last_chr
    else:
        # print("in again")
        let in_again = slice_tensor(in_tensor, 0, last_chr - 1)
        if in_again.num_elements() < 3:
            return -1

        last_chr = find_last_read_header(in_again)

    return last_chr


# TODO: Re-write in terms of find_next_chr
@always_inline
fn find_chr_all_occurances(
    t: Tensor[DType.int8], chr: String = "@"
) -> DynamicVector[Int]:
    var holder = DynamicVector[Int](capacity=(t.num_elements() / 200).to_int())
    let in_chr = ord(chr)

    @parameter
    fn inner[simd_width: Int](size: Int):
        let simd_vec = t.simd_load[simd_width](size)
        let bool_vec = simd_vec == in_chr
        if bool_vec.reduce_or():
            for i in range(len(bool_vec)):
                if bool_vec[i]:
                    holder.push_back(i)

    vectorize_unroll[simd_width, 5, inner](t.num_elements())
    return holder


# TODO: Add bounds and sanity checks.
@always_inline
fn write_to_buff[T: DType](src: Tensor[T], inout dest: Tensor[T], start: Int):
    """
    Copy a small tensor into a larger tensor given an index at the large tensor.
    Implemented iteratively due to small gain from copying less then 1MB tensor using SIMD.
    """
    for i in range(src.num_elements()):
        dest[start + i] = src[i]
