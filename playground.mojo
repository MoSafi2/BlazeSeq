from fastq_record import FastqRecord_Tensor, FastqRecord
from time import now
from tensor import TensorSpec, TensorShape
from algorithm import parallelize, vectorize
from memory.buffer import Buffer
from sys.intrinsics import PrefetchOptions
from sys.info import simdwidthof
from autotune import cost_of
import benchmark

fn main() raises:
    
    alias simd_width = simdwidthof[DType.int8]()
    let width: Int = 2 * 1024 * 1024 * 1024
    let handle = open("data/SRR4381933_1.fastq", "r")

    var x: FastqRecord_Tensor
    let t1 = now()
    var previous: Int = 0
    
    while True:
        let chunk = read_bytes(handle, previous, width)
        if chunk.num_elements() == 0:
            break

        var temp = 0
        var last_valid_pos: Int = 0
        # let x = chunk.split("\n") #58s for 50GB
        while True:

            let line1 = next_line_iter_tesnor(chunk, temp)  #42s for 50 GB
            temp = temp + line1.num_elements() + 1 

            let line2 = next_line_iter_tesnor(chunk, temp)
            temp = temp + line2.num_elements() + 1 

            let line3 = next_line_iter_tesnor(chunk, temp)
            temp = temp + line3.num_elements() + 1 

            let line4 = next_line_iter_tesnor(chunk, temp)
            temp = temp + line4.num_elements() + 1 

            if line4.num_elements() == 0:
                break

            x  = FastqRecord_Tensor(line1, line2, line3, line4)
            last_valid_pos = last_valid_pos + line1.num_elements() + line2.num_elements() + line3.num_elements() + line4.num_elements() + 4
        previous = previous + last_valid_pos

    let t2 = now()
    print((t2 - t1) / 1e9)


@always_inline
fn next_line_iter(borrowed s: String, start: Int = -1) -> String: #String: Slice 4mb, 75 µs
    for i in range(start, len(s)):
        if s[i] == "\n":
            return(s[start:i])
    return String("")


@always_inline
fn next_line_iter_tesnor(borrowed s: Tensor[DType.int8], start: Int = -1) -> Tensor[DType.int8]:  #Tensor: Slice 4mb, 4 µs
    for i in range(start, s.num_elements()):
        if s[i] == 10:
            return(slice_tensor(s, start, i))
    return Tensor[DType.int8](0)





@parameter
@always_inline
fn next_line_simd(borrowed s: Tensor[DType.int8], start: Int = 0) -> Tensor[DType.int8]:

    alias simd_width: Int = simdwidthof[DType.int8]()
    
    for nv in range(start, s.num_elements(), simd_width):
        let simd_vec = s.simd_load[simd_width](nv)
        let bool_vec = simd_vec == 10
        if bool_vec.reduce_or():
            for i in range(len(bool_vec)):
                if bool_vec[i]:
                    return slice_tensor(s, start, i)

    for n in range(simd_width*(s.num_elements()//simd_width), s.num_elements()):
        let simd_vec = s.simd_load[simd_width](n)
        let bool_vec = simd_vec == 10
        if bool_vec.reduce_or():
            for i in range(len(bool_vec)):
                if bool_vec[i]:
                    return slice_tensor(s, start, i)
                
    return Tensor[DType.int8](0)


@always_inline
fn slice_tensor[T: DType](borrowed t: Tensor[T], start: Int, end: Int) -> Tensor[T]:
    var x = Tensor[T](end - start)
    for i in range(start, end):
        x[i - start] = t[i]
    return x



    


@always_inline
fn read_text(
    borrowed handle: FileHandle, beginning: UInt64, length: Int64
) raises -> String:
    _ = handle.seek(beginning)
    return handle.read(length)


@always_inline
fn read_bytes(
    borrowed handle: FileHandle, beginning: UInt64, length: Int64
) raises -> Tensor[DType.int8]:
    _ = handle.seek(beginning)
    return handle.read_bytes(length)

