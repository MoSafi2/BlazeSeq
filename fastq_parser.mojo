from fastq_record import FastqRecord
from helpers import slice_tensor, read_bytes, find_last_read_header, get_next_line
from algorithm.functional import parallelize
from os.atomic import Atomic

"""Module to parse fastq. It has three functoins, Parse all records (single core), parse parallel (multi-core), next(lazy next read).
Consider merge parse_all_records() to become parse_parallel(1)"""


alias USE_SIMD = True
alias read_header = 64
alias new_line = 10
alias quality_header = 43


struct FastqParser:
    var _file_handle: FileHandle
    var _BUF_SIZE: Int
    var _current_chunk: Tensor[DType.int8]
    var _file_pos: Int
    var _chunk_last_index: Int
    var _chunk_pos: Int

    fn __init__(
        inout self, path: String, BUF_SIZE: Int = 1 * 1024 * 1024
    ) raises -> None:
        # Initailizing starting conditions
        self._BUF_SIZE = BUF_SIZE
        self._file_pos = 0
        self._chunk_pos = 0
        self._chunk_last_index = 0


        #Reading, Processing 1st chunk
        self._file_handle = open(path, "r")
        self._current_chunk = read_bytes(
            self._file_handle, self._file_pos, self._BUF_SIZE
        )
        _ = self._header_parser() #Checking if it is a Fastq file

        self._get_last_index(self._BUF_SIZE)
        self._file_pos += self._chunk_last_index


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
                self._file_handle, self._file_pos, self._BUF_SIZE
            )

            if self._current_chunk.num_elements() == self._BUF_SIZE:
                self._chunk_last_index = find_last_read_header(self._current_chunk)
            else:
                self._chunk_last_index = self._current_chunk.num_elements()

            self._file_pos += self._chunk_last_index

            if self._current_chunk.num_elements() == 0:
                break

        return total_reads, total_bases

    # BUG: Over estimation of the number of reads with threads > 1
    fn parse_parallel(inout self, num_workers: Int) raises -> Tensor[DType.int64]:
        var reads = Tensor[DType.int64](num_workers)
        var total_length = Tensor[DType.int64](num_workers)
        self._file_pos = 0

        while True:
            self._current_chunk = read_bytes(
                self._file_handle, self._file_pos, num_workers * self._BUF_SIZE
            )

            if self._current_chunk.num_elements() == 0:
                break

            if self._current_chunk.num_elements() == self._BUF_SIZE * num_workers:
                var last_read_vector = Tensor[DType.int32](num_workers + 1)
                var bg_index = 0
                var count = 1
                for index in range(
                    self._BUF_SIZE, num_workers * self._BUF_SIZE + 1, self._BUF_SIZE
                ):
                    # Not really needed, right a function that finds last Header in a bounded range.
                    let header = find_last_read_header(
                        self._current_chunk, bg_index, bg_index + self._BUF_SIZE
                    )
                    last_read_vector[count] = header
                    bg_index = header
                    count += 1

                @parameter
                fn _parse_chunk_inner(thread: Int):
                    let t1: Int
                    let t2: Int
                    let t3: Int

                    try:
                        t1, t2, t3 = self._parse_chunk(
                            self._current_chunk,
                            last_read_vector[thread].to_int(),
                            last_read_vector[thread + 1].to_int(),
                        )
                        reads[thread] += t1
                        total_length[thread] += t2
                    except:
                        pass

                parallelize[_parse_chunk_inner](num_workers)
                _ = last_read_vector  # Fix to retain the lifetime of last_read_vector

            else:
                var t1: Int = 0
                var t2: Int = 0
                var t3: Int = 0
                t1, t2, t3 = self._parse_chunk(self._current_chunk)
                reads[0] += t1
                total_length[0] += t2

            # Recussing theme, extract to a seperate function
            if self._current_chunk.num_elements() == self._BUF_SIZE * num_workers:
                self._chunk_last_index = find_last_read_header(self._current_chunk)
            else:
                self._chunk_last_index = self._current_chunk.num_elements()
            self._file_pos += self._chunk_last_index

        return reads

    @always_inline
    fn next(inout self) raises -> FastqRecord:
        """Method that lazily returns the Next record in the file."""

        let read: FastqRecord

        if self._current_chunk.num_elements() == 0:
            raise Error("EOF")

        if self._chunk_pos >= self._chunk_last_index:
            self._current_chunk = read_bytes(
                self._file_handle, self._file_pos, self._BUF_SIZE
            )

            self._chunk_last_index = find_last_read_header(self._current_chunk)

            if self._current_chunk.num_elements() < self._BUF_SIZE:
                self._chunk_last_index = self._current_chunk.num_elements()
                if self._chunk_last_index <= 1:
                    raise Error("EOF")

            self._chunk_pos = 0
            self._file_pos += self._chunk_last_index

        read = self._parse_read(self._chunk_pos, self._current_chunk)

        return read

    @always_inline
    fn _header_parser(self) raises -> Bool:
        if self._current_chunk[0] != read_header:
            raise Error("Fastq file should start with valid header '@'")
        return True

    @always_inline
    fn _parse_chunk(
        self, chunk: Tensor[DType.int8], start: Int = 0, end: Int = -1
    ) raises -> Tuple[Int, Int, Int]:
        let end_inner: Int
        if end == -1:
            end_inner = chunk.num_elements()
        else:
            end_inner = end

        var pos = 0
        var read: FastqRecord
        var reads: Int = 0
        var total_length: Int = 0
        var acutal_length: Int = 0

        while True:
            try:
                read = self._parse_read(pos, chunk)
                # read.trim_record()
                reads += 1
                total_length += len(read)
                acutal_length += read.total_length
            except:
                print("falied read")
                raise Error()

            if pos >= end_inner - start:
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

        let read = FastqRecord(line1, line2, line3, line4)

        return FastqRecord(line1, line2, line3, line4)

    fn _get_last_index(inout self, num_elements: Int):
        if self._current_chunk.num_elements() == num_elements:
            self._chunk_last_index = find_last_read_header(self._current_chunk)
        else:
            self._chunk_last_index = self._current_chunk.num_elements()


fn main() raises:
    var parser = FastqParser("data/M_abscessus_HiSeq.fq")

    # var t1: Int64 = 0
    # let out: Tensor[DType.int64]
    # out = parser.parse_parallel(18)
    # for i in range(out.num_elements()):
    #     t1 += out[i]
    # print(t1)

    let t1: Int
    let t2: Int
    t1, t2 = parser.parse_all_records()
    print(t1)
