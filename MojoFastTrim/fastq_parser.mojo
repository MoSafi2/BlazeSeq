from MojoFastTrim import FastqRecord
from MojoFastTrim.helpers import (
    read_bytes,
    find_last_read_header,
    get_next_line,
)
from algorithm import parallelize
from os.atomic import Atomic
from MojoFastTrim.CONSTS import *
from MojoFastTrim import Stats

alias T = DType.int8


struct FastqParser:
    var _file_handle: FileHandle
    var _BUF_SIZE: Int
    var _current_chunk: Tensor[T]
    var _file_pos: Int
    var _chunk_last_index: Int
    var _chunk_pos: Int
    var parsing_stats: Stats

    fn __init__(
        inout self, path: String, num_workers: Int = 1, BUF_SIZE: Int = 64 * 1024
    ) raises -> None:
        self._BUF_SIZE = BUF_SIZE * num_workers
        self._file_pos = 0
        self._current_chunk = Tensor[T](0)
        self._chunk_last_index = 0
        self._chunk_pos = 0
        self.parsing_stats = Stats()

        self._file_handle = open(path, "r")
        self.fill_buffer()
        _ = self._header_parser()

    fn parse_all(inout self) raises:
        while True:
            self._parse_chunk(self._current_chunk, start=0, end=self._chunk_last_index)
            try:
                self.fill_buffer()
                self.check_EOF()
            except:
                break

    @always_inline
    fn next(inout self) raises -> FastqRecord:
        """Method that lazily returns the Next record in the file."""
        let read: FastqRecord
        self.check_EOF()
        if self._chunk_pos >= self._chunk_last_index:
            self.fill_buffer()

        read = self._parse_read(self._chunk_pos, self._current_chunk)
        self.parsing_stats.tally(read)

        return read

    @always_inline
    fn check_EOF(self) raises:
        if self._current_chunk.num_elements() == 0:
            raise Error("EOF")

    @always_inline
    fn _header_parser(self) raises -> Bool:
        if self._current_chunk[0] != read_header:
            raise Error("Fastq file should start with valid header '@'")
        return True

    @always_inline
    fn _parse_chunk(inout self, chunk: Tensor[T], start: Int, end: Int) raises:
        var pos = 0
        let read: FastqRecord
        while True:
            try:
                read = self._parse_read(pos, chunk)
                self.parsing_stats.tally(read)
            except:
                raise Error("falied read")
            if pos >= end - start:
                break

    @always_inline
    fn _parse_read(self, inout pos: Int, chunk: Tensor[T]) raises -> FastqRecord:
        let line1 = get_next_line[USE_SIMD=USE_SIMD](chunk, pos)
        pos += line1.num_elements() + 1
        let line2 = get_next_line[USE_SIMD=USE_SIMD](chunk, pos)
        pos += line2.num_elements() + 1
        let line3 = get_next_line[USE_SIMD=USE_SIMD](chunk, pos)
        pos += line3.num_elements() + 1
        let line4 = get_next_line[USE_SIMD=USE_SIMD](chunk, pos)
        pos += line4.num_elements() + 1
        return FastqRecord(line1, line2, line3, line4)

    fn _get_last_index(inout self, num_elements: Int):
        if self._current_chunk.num_elements() == num_elements:
            self._chunk_last_index = find_last_read_header(self._current_chunk)
        else:
            self._chunk_last_index = self._current_chunk.num_elements()

    fn fill_buffer(inout self) raises:
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

    # # BUG: Over estimation of the number of reads with threads > 1
    # # TODO: Make the number of workers Modifable
    # fn parse_parallel(inout self, num_workers: Int) raises:
    #     self._file_pos = 0

    #     while True:
    #         self.fill_buffer()
    #         self.check_EOF()

    #         var last_read_vector = Tensor[DType.int32](num_workers + 1)
    #         var bg_index = 0
    #         var count = 1
    #         for index in range(
    #             self._BUF_SIZE, num_workers * self._BUF_SIZE + 1, self._BUF_SIZE
    #         ):
    #             # Not really needed, right a function that finds last Header in a bounded range.
    #             let header = find_last_read_header(
    #                 self._current_chunk, bg_index, bg_index + self._BUF_SIZE
    #             )
    #             last_read_vector[count] = header
    #             bg_index = header
    #             count += 1

    #         @parameter
    #         fn _parse_chunk_inner(thread: Int):
    #             try:
    #                 self._parse_chunk(
    #                     self._current_chunk,
    #                     last_read_vector[thread].to_int(),
    #                     last_read_vector[thread + 1].to_int(),
    #                 )
    #             except:
    #                 pass

    #         parallelize[_parse_chunk_inner](num_workers)
    #         _ = last_read_vector  # Fix to retain the lifetime of last_read_vector

    #     else:
    #         self._parse_chunk(self._current_chunk, 0, self._chunk_last_index)

    #     # Recussing theme, extract to a seperate function
    #     if self._current_chunk.num_elements() == self._BUF_SIZE * num_workers:
    #         self._chunk_last_index = find_last_read_header(self._current_chunk)
    #     else:
    #         self._chunk_last_index = self._current_chunk.num_elements()
    #     self._file_pos += self._chunk_last_index
