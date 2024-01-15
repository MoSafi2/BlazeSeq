from fastq_record import FastqRecord
from helpers import *


alias USE_SIMD = True


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

        _ = self._header_parser()

    fn parse_all_records(inout self, trim: Bool = True) raises -> Tuple[Int, Int]:
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

    fn parse_parallel(inout self, num_workers: Int) raises:
        self._current_chunk = read_bytes(
            self._file_handle, self._current_pos, num_workers * self._BUF_SIZE
        )

        var last_read_vector = Tensor[DType.int32](num_workers + 1)
        var bg_index = 0
        var count = 1
        for index in range(
            self._BUF_SIZE, num_workers * self._BUF_SIZE + 1, self._BUF_SIZE
        ):
            let _slice = slice_tensor(self._current_chunk, bg_index, index)
            let header = find_last_read_header(_slice) + bg_index
            last_read_vector[count] = header
            bg_index = index
            count += 1

        for i in range(last_read_vector.num_elements() - 1):
            print(
                slice_tensor(
                    self._current_chunk,
                    last_read_vector[i].to_int(),
                    last_read_vector[i + 1].to_int(),
                )
            )

        # Implement the function to parallerlized here

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

        self, inout pos: Int, chunk: Tensor[DType.int8]
    ) raises -> FastqRecord:
        let line1 = get_next_line[USE_SIMD=USE_SIMD](chunk, pos)
        pos += line1.num_elements() + 1  # Offseting for the trailing \n

        let line2 = get_next_line[USE_SIMD=USE_SIMD](chunk, pos)
        pos += line2.num_elements() + 1

        let line3 = get_next_line[USE_SIMD=USE_SIMD](chunk, pos)
        pos += line3.num_elements() + 1

        let line4 = get_next_line[USE_SIMD=USE_SIMD](chunk, pos)
        pos += line4.num_elements() + 1

        print(line4)

        let read = FastqRecord(line1, line2, line3, line4)

        return FastqRecord(line1, line2, line3, line4)


fn main() raises:
    var parser = FastqParser("data/M_abscessus_HiSeq.fq")
    parser.parse_parallel(5)
