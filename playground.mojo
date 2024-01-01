from fastq_record import FastqRecord_Tensor, FastqRecord

def main_old():

    for size in range(0, 1024*1024*150, 1024*1024*5):
        with open("data/M_abscessus_HiSeq.fq", "r") as handle:
            time_bytes = read_bytes(handle, size)
            time_text = read_text2(handle, size)
            print(size/(1024*1024), time_bytes / time_text)
            print("time/MB", time_text / size/(1024*1024))
            

def main():
    with open("data/M_abscessus_HiSeq.fq", "r") as handle:
        time_text = read_text2(handle, 1024*1024)
        print(1024*1024/(1024*1024), time_text)

fn read_bytes(handle:FileHandle, size: Int) raises -> FloatLiteral:

    import time
    let t1 = time.now()
    let  T = handle.read_bytes(size)
    let t2 = time.now()

    var temp_vec = DynamicVector[Tensor[DType.int8]](4)
    var pos = 0
    var count = 0

    for i in range(T.num_elements()):
        if T[i] == 10:
            let x = slice_tensor(T, pos, i)
            temp_vec.push_back(x)
            pos = i+1
            count += 1

        if count == 4:
            let read = FastqRecord_Tensor(temp_vec[0], temp_vec[1], temp_vec[2], temp_vec[3])
            temp_vec.clear()
            count = 0

    let t4 = time.now()
    return((t4-t1)/1e3)




fn read_text(handle: FileHandle, size: Int) raises -> FloatLiteral:
    import time

    let t1 = time.now()
    let T = handle.read(size)
    let t2 = time.now()
    let vec = T.split("\n")
    let t4 = time.now()
    return (t4-t1)/1e3





fn read_text2(handle: FileHandle, size: Int) raises -> FloatLiteral:
    
    import time

    let t1 = time.now()
    let  T = handle.read(size)
    let t2 = time.now()

    var temp_vec = DynamicVector[String](4)
    var pos = 0
    var count = 0

    for i in range(len(T)):
        if T[i] == "\n":
            let x = T[pos:i]
            temp_vec.push_back(x)
            pos = i+1
            count += 1

        if count == 4:
            print(temp_vec[0], temp_vec[1], temp_vec[2], temp_vec[3])
            let read = FastqRecord(temp_vec[0], temp_vec[1], temp_vec[2], temp_vec[3])
            print(read)
            temp_vec.clear()
            count = 0
        break

    let t4 = time.now()
    return((t4-t1)/1e3)






fn slice_tensor[T:DType](borrowed t: Tensor[T], start: Int, end: Int) -> Tensor[T]:
    var x = Tensor[T](end-start)
    for i in range(start, end):
        x[i - start] = t[i]
    return x 
