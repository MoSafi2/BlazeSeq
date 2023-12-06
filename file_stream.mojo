@value
struct intable_string(Intable, Stringable):

    var data: String

    fn __str__(self) -> String:
        return self.data
    
    fn __int__(self) -> Int:
        let data_n = len(self.data)
        var n: Int = 0
        for i in range(0, data_n):
            let chr: Int = ord(self.data[i]) -48
            n = n + chr * (10**(data_n-(i+1)))
        return n



fn read_linkes_chunk(borrowed file_handle: FileHandle, chunk_size: Int = -1,  current_pos: UInt64 = 0) raises -> DynamicVector[String]:
    
    let s = file_handle.read(chunk_size)
    var vec = s.split("\n")
    let vec_n = len(vec)

    if vec_n < 4:
        let pos = file_handle.seek(current_pos)
        vec.push_back(pos)
        return vec

    var rem = vec_n % 4
    var retreat = 0    

    if rem == 0: # The whole last record is untrustworthy remove the last 4 elements.
        rem = 4

    if rem == 1: #Go back only one step 
        retreat = len(vec[vec_n - 1])
        _ = vec.pop_back()
    else:
        for i in range(rem):
            retreat = retreat + len(vec[vec_n - (i+1)])
        for i in range(rem):
            _ = vec.pop_back()

    let pos = file_handle.seek((current_pos+chunk_size)-retreat)
    vec.push_back(pos)
    return vec


fn main() raises:

    import time

    let KB = 1024
    let MB = 1024 * KB
    let GB = 1024 * MB
    let CHUNK = 30*MB

    let f =  open("M_abscessus_HiSeq.fq", "r")
    let pos: String
    var pos_int: Int = 0
    var vec: DynamicVector[String]
    var n_reads = 0

    let t1 = time.now()
    for i in range(100):
        vec = read_linkes_chunk(f, CHUNK, pos_int)
        pos = vec.pop_back()
        pos_int = int(intable_string(pos))
        if len(vec) == 1:
            break
        n_reads = n_reads + len(vec)
    let t2 = time.now()

    print((n_reads/4) == 5682010.0)
    print(n_reads/4)
    print((t2-t1)/1e9)
