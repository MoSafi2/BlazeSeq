from fastq_record import FastqRecord
from helpers import (
    slice_tensor,
    read_bytes,
    next_line_simd,
    find_chr_all_occurances,
    find_chr_first_occurance,
    find_chr_last_occurance,
    write_to_buff,
)


# TODO: Make FastQ Parser an Iterator that can return Fastq Records endlessly
struct FastqParser:
    var _file_handle: FileHandle
    var _out_path: String
    var _BUF_SIZE: Int
    var _current_chunk: Tensor[DType.int8]
    var _current_pos: UInt64

    fn __init__(
        inout self, path: String, BUF_SIZE: Int = 16 * 1024 * 1024
    ) raises -> None:
        # if not BUF_SIZE & (BUF_SIZE - 1):
        #     raise Error("The batch size should have a power of two.")

        self._BUF_SIZE = BUF_SIZE
        self._file_handle = open(path, "r")
        let in_path = Path(path)
        let suffix = in_path.suffix()
        self._out_path = path.replace(suffix, "") + "_out" + suffix
        self._current_pos = 0
        self._current_chunk = read_bytes(
            self._file_handle, self._current_pos, self._BUF_SIZE
        )

    fn parse_all_records(
        inout self,
        trim: Bool = True,
        min_quality: Int = 20,
        direction: String = "end",
    ) raises -> Tuple[Int, Int]:
        if not self._header_parser():
            return Tuple[Int, Int](0, 0)

        let out = open(self._out_path, "w")

        var total_reads: Int = 0
        var total_bases: Int = 0
        var temp: Int = 0
        var temp2: Int = 0
        var index_last_read: UInt64 = 0

        while True:
            # Potenial BUG if the final chunk has the buffer size exactly, could be rare occurancce
            # Needs to flag EOF somehow?
            if self._current_chunk.num_elements() == self._BUF_SIZE:
                index_last_read = find_chr_last_occurance(self._current_chunk)
            else:
                index_last_read = self._current_chunk.num_elements()

            temp, temp2 = self._parse_chunk(
                slice_tensor(self._current_chunk, 0, index_last_read.to_int()), out
            )
            total_reads += temp
            total_bases += temp2

            self._current_pos += index_last_read
            self._current_chunk = read_bytes(
                self._file_handle, self._current_pos, self._BUF_SIZE
            )

            if self._current_chunk.num_elements() == 0:
                break

        return total_reads, total_bases

    fn _header_parser(self) raises -> Bool:
        if self._current_chunk[0] != ord("@"):
            raise Error("Fastq file should start with valid header '@'")
        return True

    fn _parse_chunk(
        self, borrowed chunk: Tensor[DType.int8], out_handle: FileHandle
    ) raises -> Tuple[Int, Int]:
        var pos = 0
        var read: FastqRecord
        var reads: Int = 0
        var total_length: Int = 0
        var write_buffer = Tensor[DType.int8](chunk.num_elements() + 500)
        while True:
            read = self._parse_read(pos, chunk)
            reads += 1
            total_length += len(read)

            # print(pos, ":", write_buffer.num_elements())
            write_to_buff[DType.int8](
                read.wirte_record(), write_buffer, pos - len(read)
            )
            read.trim_record()
            if pos >= chunk.num_elements():
                break

        let ele = write_buffer.num_elements()
        out_handle.write(String(write_buffer._steal_ptr(), ele))

        return Tuple[Int, Int](reads, total_length)

    fn _parse_read(
        self, inout pos: Int, borrowed chunk: Tensor[DType.int8]
    ) raises -> FastqRecord:
        let line1 = next_line_simd(chunk, pos)
        pos += line1.num_elements() + 1

        let line2 = next_line_simd(chunk, pos)
        pos += line2.num_elements() + 1

        let line3 = next_line_simd(chunk, pos)
        pos += line3.num_elements() + 1

        let line4 = next_line_simd(chunk, pos)
        pos += line4.num_elements() + 1

        return FastqRecord(line1, line2, line3, line4)


fn main() raises:
    import time
    from math import math
    from sys import argv

    let KB = 1024
    let MB = 1024 * KB
    let vars = argv()
    # var parser = FastqParser(vars[1])
    var parser = FastqParser("data/M_abscessus_HiSeq.fq")
    let t1 = time.now()
    let num: Int
    let total_bases: Int
    num, total_bases = parser.parse_all_records(
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
        + "total base count is:"
        + total_bases
    )
