from algorithm import vectorize
import time


alias simd_width: Int = simdwidthof[DType.int8]()


@always_inline
fn next_line_simd(borrowed s: Tensor[DType.int8], start: Int = 0) -> Tensor[DType.int8]:

    let rem = simd_width*(s.num_elements()//simd_width)

    for nv in range(start, s.num_elements(), simd_width):
        let simd_vec = s.simd_load[simd_width](nv)
        let bool_vec = simd_vec == 10
        if bool_vec.reduce_or():
            for i in range(len(bool_vec)):
                if bool_vec[i]:
                    return slice_tensor(s, start, nv + i)

    for n in range(rem, s.num_elements()):
        let simd_vec = s.simd_load[simd_width](n)
        if simd_vec == 10:
            return slice_tensor(s, start, n + (s.num_elements() - rem))

    return Tensor[DType.int8](0)


@always_inline
fn slice_tensor[T: DType](borrowed t: Tensor[T], start: Int, end: Int) -> Tensor[T]:
    var x = Tensor[T](end - start)
    for i in range(start, end):
        x[i - start] = t[i]
    return x


@always_inline
fn read_bytes(
    borrowed handle: FileHandle, beginning: UInt64, length: Int64
) raises -> Tensor[DType.int8]:
    _ = handle.seek(beginning)
    return handle.read_bytes(length)


@always_inline
fn read_text(
    borrowed handle: FileHandle, beginning: UInt64, length: Int64
) raises -> String:
    _ = handle.seek(beginning)
    return handle.read(length)




@always_inline
fn find_chr_first_occurance(borrowed in_tensor: Tensor[DType.int8], chr: String = "@", start: Int = 0) -> Int:
    
    let in_chr = ord(chr)

    alias simd_width: Int = simdwidthof[DType.int8]()
    for nv in range(start, in_tensor.num_elements(), simd_width):
        let simd_vec = in_tensor.simd_load[simd_width](nv)
        let bool_vec = simd_vec == in_chr
        if bool_vec.reduce_or():
            for i in range(len(bool_vec)):
                if bool_vec[i]:
                    return i

    for n in range(simd_width*(in_tensor.num_elements()//simd_width), in_tensor.num_elements()):
        let simd_vec = in_tensor.simd_load[1](n)
        if simd_vec == in_chr:
                return n
    return -1



fn find_last_read(in_tensor: Tensor[DType.int8]) -> Int:

    let last_chr = find_chr_last_occurance(in_tensor)
    if in_tensor[last_chr - 1] == 10:
        return last_chr
    else:
        let in_again = slice_tensor(in_tensor, 0, last_chr)
        
        if in_again.num_elements() < 3:
            return -1

        find_last_read(in_again)

    return -1


@always_inline
fn find_chr_last_occurance(in_tensor: Tensor[DType.int8], chr: String = "@") -> Int:
    let in_chr: SIMD[DType.int8, 1] = ord(chr)
    let tot_elements = in_tensor.num_elements() - 1

    for i in range(tot_elements - 1, -1, -simd_width):
        let simd_vec = in_tensor.simd_load[simd_width](i)
        let bool_vec = simd_vec == in_chr
        if bool_vec.reduce_or():
            for ele in range(len(bool_vec) - 1, 0, -1):
                if bool_vec[ele]:
                    return ele + i


    for n in range((in_tensor.num_elements() % simd_width) - 1, -1, -1):
        let simd_vec = in_tensor.simd_load[1](n)
        if simd_vec == in_chr:
                return n
    return -1

        


@always_inline
fn find_chr_all_occurances(t: Tensor[DType.int8], chr: String = "@") -> DynamicVector[Int]:
    var holder = DynamicVector[Int](capacity = (t.num_elements() / 200).to_int())
    let in_chr = ord(chr)

    @parameter
    fn inner[simd_width: Int](size: Int):
        let simd_vec = t.simd_load[simd_width](size)
        let bool_vec = simd_vec == in_chr
        if bool_vec.reduce_or():
            for i in range(len(bool_vec)):
                if bool_vec[i]:
                    holder.push_back(i)
                    
    vectorize[simd_width, inner](t.num_elements())
    return holder
    


@always_inline
fn write_to_buff[T: DType](src: Tensor[T], inout dest: Tensor[T], start: Int):
    """Copy a small tensor into a larger tensor given an index at the large tensor.
    #TODO: Add bound and sanity checks."""
    for i in range(src.num_elements()):
        dest[start + i] = src[i]

