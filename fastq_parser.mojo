from fastq_record import FastqRecord
from helpers import slice_tensor, read_bytes, next_line_simd


struct FastqParser:
    var _file_handle: FileHandle
    var _out_path: String
    var _BUF_SIZE: Int

    fn __init__(
        inout self, path: String, BUF_SIZE: Int = 4 * 1024 * 1024
    ) raises -> None:
        self._file_handle = open(path, "r")
        let in_path = Path(path)
        let suffix = in_path.suffix()
        self._out_path = path.replace(suffix, "") + "_out" + suffix
        self._BUF_SIZE = BUF_SIZE

    fn parse_records(
        inout self,
        trim: Bool = True,
        min_quality: Int = 20,
        direction: String = "end",
    ) raises -> Int:
        var count: Int = 0
        var bases: Int = 0
        var qu: Int = 0
        var pos: Int = 0

        if not self._header_parser():
            return 0
        let out = open(self._out_path, "w")

        var last_valid_pos: UInt64 = 0

        while True:
            let chunk = read_bytes(self._file_handle, last_valid_pos, self._BUF_SIZE)
            last_valid_pos += self._parse_chunk(chunk)
        return count

    fn _header_parser(self) raises -> Bool:
        let header: String = self._file_handle.read(1)
        _ = self._file_handle.seek(0)
        if header != "@":
            raise Error("Fastq file should start with valid header '@'")
        return True

    fn _parse_chunk(self, chunk: Tensor[DType.int8]) raises -> UInt64:
        var temp = 0
        var last_valid_pos: UInt64 = 0
        var x: FastqRecord
        while True:


            let line1 = next_line_simd(
                chunk, temp
            )  # 42s for 50 GB for tensor readinvsg in general
            temp = temp + line1.num_elements() + 1
            if line1.num_elements() == 0:
                break

            let line2 = next_line_simd(chunk, temp)
            temp = temp + line2.num_elements() + 1
            if line2.num_elements() == 0:
                break

            let line3 = next_line_simd(chunk, temp)
            temp = temp + line3.num_elements() + 1
            if line3.num_elements() == 0:
                break

            let line4 = next_line_simd(chunk, temp)
            temp = temp + line4.num_elements() + 1
            if line4.num_elements() == 0:
                break

            x = FastqRecord(line1, line2, line3, line4)
            last_valid_pos = (
                last_valid_pos + x.total_length
            )  # Should be update before any mutating operations on the Record that can change the length

            x.trim_record()
            _ = x.wirte_record()

            return last_valid_pos


fn main() raises:
    import time
    from math import math
    from sys import argv

    let KB = 1024
    let MB = 1024 * KB
    let vars = argv()
    # var parser = FastqParser(vars[1])
    var parser = FastqParser(
        "/home/mohamed/Documents/Projects/fastq_parser_mojo/data/M_abscessus_HiSeq.fq"
    )
    let t1 = time.now()
    let num = parser.parse_records(
        trim=False, min_quality=28, direction="both"
    )
    let t2 = time.now()
    let t_sec = ((t2 - t1) / 1e9)
    let s_per_r = t_sec / num
    print(
        String(t_sec)
        + "S spend in parsing: "
        + num
        + " records. \neuqaling "
        + String((s_per_r) * 1e6)
        + " microseconds/read or "
        + math.round[DType.float32, 1](1 / s_per_r) * 60
        + " reads/min"
    )
