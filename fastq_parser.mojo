from fastq_record import FastqRecord
from helpers import *
from fastq_writer import FastqWriter

alias USE_SIMD = True


# TODO: Make FastQ Parser an Iterator that can return Fastq Records endlessly
struct FastqParser:
    var _file_handle: FileHandle
    var _BUF_SIZE: Int
    var _current_chunk: Tensor[DType.int8]
    var _current_pos: Int
    var _chunk_last_index: Int
    var _chunk_pos: Int

    fn __init__(
        inout self, path: String, BUF_SIZE: Int = 1 * 1024 * 1024
    ) raises -> None:
        # if not BUF_SIZE & (BUF_SIZE - 1):
        #     raise Error("The batch size should have a power of two.")

        self._BUF_SIZE = BUF_SIZE
        self._file_handle = open(path, "r")
        self._current_pos = 0
        self._chunk_pos = 0

        self._current_chunk = read_bytes(
            self._file_handle, self._current_pos, self._BUF_SIZE
        )

        # Seems to be a recurring theme, Extract to a function
        if self._current_chunk.num_elements() == self._BUF_SIZE:
            self._chunk_last_index = find_last_read_header(self._current_chunk)
        else:
            self._chunk_last_index = self._current_chunk.num_elements()

        self._current_pos += self._chunk_last_index

    fn parse_all_records(inout self, trim: Bool = True) raises -> Tuple[Int, Int]:
        if not self._header_parser():
            return Tuple[Int, Int](0, 0)

        var total_reads: Int = 0
        var total_bases: Int = 0
        var temp: Int = 0
        var temp2: Int = 0
        var acutal_length: Int = 0

        while True:
            # Potenial BUG if the final chunk has the buffer size exactly, could be rare occurancce
            # Needs to flag EOF somehow?

            let chunk = slice_tensor[USE_SIMD=USE_SIMD](
                self._current_chunk, 0, self._chunk_last_index
            )

            temp, temp2, acutal_length = self._parse_chunk(chunk)

            total_reads += temp
            total_bases += temp2

            self._current_chunk = read_bytes(
                self._file_handle, self._current_pos, self._BUF_SIZE
            )

            if self._current_chunk.num_elements() == self._BUF_SIZE:
                self._chunk_last_index = find_last_read_header(self._current_chunk)
            else:
                self._chunk_last_index = self._current_chunk.num_elements()

            self._current_pos += self._chunk_last_index

            if self._current_chunk.num_elements() == 0:
                break

        return total_reads, total_bases

    @always_inline
    fn next(inout self) raises -> FastqRecord:
        """Method that lazily returns the Next record in the file."""

        let read: FastqRecord

        if self._current_chunk.num_elements() == 0:
            raise Error("EOF")

        if self._chunk_pos >= self._chunk_last_index:
            self._current_chunk = read_bytes(
                self._file_handle, self._current_pos, self._BUF_SIZE
            )

            self._chunk_last_index = find_last_read_header(self._current_chunk)

            if self._current_chunk.num_elements() < self._BUF_SIZE:
                self._chunk_last_index = self._current_chunk.num_elements()
                if self._chunk_last_index <= 1:
                    raise Error("EOF")

            self._chunk_pos = 0
            self._current_pos += self._chunk_last_index

        read = self._parse_read(self._chunk_pos, self._current_chunk)

        return read

    @always_inline
    fn _header_parser(self) raises -> Bool:
        if self._current_chunk[0] != ord("@"):
            raise Error("Fastq file should start with valid header '@'")
        return True

    @always_inline
    fn _parse_chunk(self, chunk: Tensor[DType.int8]) raises -> Tuple[Int, Int, Int]:
        var pos = 0
        let read: FastqRecord
        var reads: Int = 0
        var total_length: Int = 0
        var acutal_length: Int = 0

        while True:
            try:
                read = self._parse_read(pos, chunk)
                reads += 1
                total_length += len(read)
                acutal_length += read.total_length
            except:
                print("falied read")
                pass

            if pos >= chunk.num_elements():
                break

        return Tuple[Int, Int, Int](reads, total_length, acutal_length)

    @always_inline
    fn _parse_read(
        self, inout pos: Int, borrowed chunk: Tensor[DType.int8]
    ) raises -> FastqRecord:
        let line1 = get_next_line[USE_SIMD=USE_SIMD](chunk, pos)
        pos += line1.num_elements() + 1

        let line2 = get_next_line[USE_SIMD=USE_SIMD](chunk, pos)
        pos += line2.num_elements() + 1

        let line3 = get_next_line[USE_SIMD=USE_SIMD](chunk, pos)
        pos += line3.num_elements() + 1

        let line4 = get_next_line[USE_SIMD=USE_SIMD](chunk, pos)
        pos += line4.num_elements() + 1

        return FastqRecord(line1, line2, line3, line4)


fn main() raises:
    import time
    from math import math
    from sys import argv

    let vars = argv()
    # var parser = FastqParser(vars[1])
    var parser = FastqParser("data/M_abscessus_HiSeq.fq")
    let t1 = time.now()
    var num: Int = 0
    var total_bases: Int = 0

    # num, total_bases = parser.parse_all_records()
    while True:
        try:
            let x = parser.next()
            num += 1
            total_bases += len(x)
        except:
            break

    let t2 = time.now()

    print(num)
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
