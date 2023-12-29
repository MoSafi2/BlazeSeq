def main():
    from fastq_record import FastqRecord_Tensor

    let f = open("data/M_abscessus_HiSeq.fq", "r")

    import time
    let t1 = time.now()
    let  T = f.read_bytes()
    let t2 = time.now()
    print((t2-t1)/1e6)

    let t3 = time.now()
    var temp_vec = DynamicVector[Tensor[DType.int8]](4)
    pos = 0
    var count = 0

    for i in range(T.num_elements()):
        if T[i] == 10:
            x = slice_tensor(T, pos, i)
            temp_vec.push_back(x)
            pos = i+1
            count += 1

        if count == 4:
            read = FastqRecord_Tensor(temp_vec[0], temp_vec[1], temp_vec[2], temp_vec[3])
            temp_vec.clear()
            count = 0

    let t4 = time.now()
    print((t4-t3)/1e6)


fn slice_tensor[T:DType](borrowed t: Tensor[T], start: Int, end: Int) -> Tensor[T]:
    var x = Tensor[T](end-start)
    for i in range(start, end):
        x[i - start] = t[i]
    return x 
