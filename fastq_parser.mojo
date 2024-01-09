from fastq_record import FastqRecord
from helpers import slice_tensor, read_bytes, next_line_simd

#TODO: Make FastQ Parser an Iterator that can return Fastq Records endlessly 
struct FastqParser:
    var _file_handle: FileHandle
    var _out_path: String
    var _BUF_SIZE: Int

    fn __init__(
        inout self, path: String, BUF_SIZE: Int = 4 * 1024 * 1024
    ) raises -> None:


        # if not BUF_SIZE & (BUF_SIZE - 1):
        #     raise Error("The batch size should have a power of two.")

        self._BUF_SIZE = BUF_SIZE
        self._file_handle = open(path, "r") 
        let in_path = Path(path)
        let suffix = in_path.suffix()
        self._out_path = path.replace(suffix, "") + "_out" + suffix
        

    fn parse_records(
        inout self,
        trim: Bool = True,
        min_quality: Int = 20,
        direction: String = "end",
    ) raises -> Tuple[UInt64, Int]:


        if not self._header_parser():
            return Tuple[UInt64, Int](0,0)

        let out = open(self._out_path, "w")

        var last_valid_pos: UInt64 = 0
        var total_reads: UInt64 = 0
        var total_bases: Int = 0
        var temp: UInt64 = 0
        var temp2: UInt64 = 0
        var temp3: Int = 0

        while True:

            let chunk = read_bytes(self._file_handle, last_valid_pos, self._BUF_SIZE)
            temp, temp2, temp3 = self._parse_chunk(chunk)
            last_valid_pos += temp
            total_reads += temp2
            total_bases += temp3

            if chunk.num_elements() == 0:
                break

        return total_reads, total_bases

    fn _header_parser(self) raises -> Bool:
        let header: String = self._file_handle.read(1)
        _ = self._file_handle.seek(0)
        if header != "@":
            raise Error("Fastq file should start with valid header '@'")
        return True

    fn _parse_chunk(self, borrowed chunk: Tensor[DType.int8]) raises -> Tuple[UInt64, UInt64, Int]:
        var temp = 0
        var last_valid_pos: UInt64 = 0
        let read: FastqRecord
        var reads: UInt64 = 0
        var total_length: Int = 0

        while True:
            try:
                read = self._parse_read(temp, chunk)
                reads += 1
                total_length += len(read)
            except:
                break

            last_valid_pos = (
                last_valid_pos + read.total_length
            )  # Should be update before any mutating operations on the Record that can change the length
        return Tuple[UInt64, UInt64, Int](last_valid_pos, reads, total_length)


    fn _parse_read(self, inout counter: Int, borrowed chunk: Tensor[DType.int8] ) raises -> FastqRecord:
        
            let line1 = next_line_simd(
                chunk, counter
            )  # 42s for 50 GB for tensor readinvsg in general
            counter = counter + line1.num_elements() + 1

            let line2 = next_line_simd(chunk, counter)
            counter = counter + line2.num_elements() + 1

            let line3 = next_line_simd(chunk, counter)
            counter = counter + line3.num_elements() + 1

            let line4 = next_line_simd(chunk, counter)
            counter = counter + line4.num_elements() + 1


            return FastqRecord(line1, line2, line3, line4)


fn main() raises:
    import time
    from math import math
    from sys import argv

    let KB = 1024
    let MB = 1024 * KB
    let vars = argv()
    # var parser = FastqParser(vars[1])
    var parser = FastqParser(
        "data/M_abscessus_HiSeq.fq"
    )
    let t1 = time.now()
    let num: UInt64
    let total_bases: Int
    num, total_bases = parser.parse_records(
        trim=False, min_quality=28, direction="both"
    )
    let t2 = time.now()
    let t_sec = ((t2 - t1) / 1e9)
    let s_per_r = t_sec / num.to_int()
    print(
        String(t_sec)
        + "S spend in parsing: "
        + num
        + " records. \neuqaling "
        + String((s_per_r) * 1e6)
        + " microseconds/read or "
        + math.round[DType.float32, 1](1 / s_per_r) * 60
        + " reads/min"
        + "total base count is:"
        + total_bases
    )
