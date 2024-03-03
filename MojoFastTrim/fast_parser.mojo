from MojoFastTrim.helpers import (
    get_next_line_index,
    find_last_read_header,
    cpy_tensor,
)
from MojoFastTrim.CONSTS import read_header, quality_header
from MojoFastTrim import RecordCoord, Stats
from MojoFastTrim.iostream import IOStream
from MojoFastTrim.CONSTS import I8

alias SIMD_WIDTH = simdwidthof[I8]()


struct FastParser:
    var stream: IOStream
    var _BUF_SIZE: Int
    var parsing_stats: Stats

    fn __init__(inout self, path: String, BUF_SIZE: Int = 64 * 1024) raises -> None:
        # Initailizing starting conditions
        self._BUF_SIZE = BUF_SIZE
        self.stream = IOStream(path, BUF_SIZE)
        self.parsing_stats = Stats()

    # fn parse_all(inout self) raises:
    #     while True:
    #         self.parse_chunk(self._current_chunk, start=0, end=self._chunk_last_index)
    #         try:
    #             self.fill_buffer()
    #             self.check_EOF()
    #         except:
    #             break

    @always_inline
    fn next(inout self) raises -> RecordCoord:
        var read: RecordCoord
        read = self.parse_read()
        # read.validate(self.stream.buf)
        return read

    # BUG, there is a still a problem with validation
    @always_inline
    fn parse_read(
        inout self,
    ) raises -> RecordCoord:
        var start = self.stream.head
        var line1 = self.stream.next_line_index() + 1
        var line2 = self.stream.next_line_index() + 1
        var line3 = self.stream.next_line_index() + 1
        var line4 = self.stream.next_line_index() + 1
        return RecordCoord(start, line1, line2, line3, line4)


fn main() raises:
    var parser = FastParser(
        "/home/mohamed/Documents/Projects/Fastq_Parser/data/M_abscessus_HiSeq.fq"
    )
    var no_bases = 0
    var num_reads = 0
    while True:
        try:
            var record = parser.next()
            num_reads += 1
            # no_bases += (record.SeqStr - record.QuHeader).to_int()
        except Error:
            print(Error)
            print(num_reads)
            print(no_bases)
            break
