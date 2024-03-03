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
from MojoFastTrim.iostream import IOStream
import time

alias T = DType.int8


struct FastqParser:
    var stream: IOStream
    var _BUF_SIZE: Int
    # var parsing_stats: Stats

    fn __init__(
        inout self, path: String, num_workers: Int = 1, BUF_SIZE: Int = 64 * 1024
    ) raises -> None:
        self._BUF_SIZE = BUF_SIZE * num_workers
        self.stream = IOStream(path, self._BUF_SIZE)
        _ = self._header_parser()
        # self.parsing_stats = Stats()

    fn parse_all(inout self) raises:
        while True:
            try:
                var read = self.next()
            except:
                break

    @always_inline
    fn next(inout self) raises -> FastqRecord:
        """Method that lazily returns the Next record in the file."""
        var read: FastqRecord
        read = self._parse_read()
        # self.parsing_stats.tally(read)
        return read

    @always_inline
    fn _header_parser(self) raises -> Bool:
        if self.stream.buf[0] != 64:
            raise Error("Fastq file should start with valid header '@'")
        return True

    @always_inline
    fn _parse_read(inout self) raises -> FastqRecord:
        var line1 = self.stream.read_next_line()
        var line2 = self.stream.read_next_line()
        var line3 = self.stream.read_next_line()
        var line4 = self.stream.read_next_line()
        return FastqRecord(line1, line2, line3, line4)


fn main() raises:
    var file = "/home/mohamed/Documents/Projects/Fastq_Parser/data/M_abscessus_HiSeq.fq"
    var parser = FastqParser(file, 1, 256 * 1024)

    var t1 = time.now()
    var no_reads = 0
    while True:
        try:
            var read = parser.next()
            no_reads += 1
        except Error:
            print(no_reads)
            break
    var t2 = time.now()
    print((t2 - t1) / 1e9)
