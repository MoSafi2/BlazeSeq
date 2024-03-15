from . import FastqRecord, RecordCoord
from .helpers import (
    find_last_read_header,
    get_next_line,
)
from .CONSTS import *
from . import Stats
from .iostream import BufferedLineIterator, FileReader
import time


struct FastqParser[tally: Bool = False, validate_ascii: Bool = False]:
    var stream: BufferedLineIterator[FileReader, check_ascii=validate_ascii]
    var quality_schema: QualitySchema
    var stats: Stats

    fn __init__(
        inout self, path: String, analysers: Stats, schema: String = "generic"
    ) raises -> None:
        self.stream = BufferedLineIterator[FileReader, check_ascii=validate_ascii](
            path, DEFAULT_CAPACITY
        )
        self.quality_schema = generic_schema
        self.stats = analysers

    fn parse_all(inout self) raises:
        while True:
            try:
                var record = self.next()
                record.validate_record()

                @parameter
                if tally:
                    self.stats.tally(record)
            except:

                @parameter
                if tally:
                    print(self.stats)
                break

    @always_inline
    fn next(inout self) raises -> FastqRecord:
        """Method that lazily returns the Next record in the file."""
        var record: FastqRecord
        record = self._parse_record()
        # ASCII validation is carried out in the reader
        record.validate_record[validate_ascii=False]()
        return record

    @always_inline
    fn _parse_record(inout self) raises -> FastqRecord:
        var line1 = self.stream.read_next_line()
        var line2 = self.stream.read_next_line()
        var line3 = self.stream.read_next_line()
        var line4 = self.stream.read_next_line()
        return FastqRecord(line1, line2, line3, line4)


struct CoordParser[tally: Bool = False, validate_ascii: Bool = False]:
    var stream: BufferedLineIterator[FileReader, check_ascii=validate_ascii]
    var parsing_stats: Stats

    fn __init__(
        inout self,
        path: String,
    ) raises -> None:
        self.stream = BufferedLineIterator[FileReader, check_ascii=validate_ascii](
            path, DEFAULT_CAPACITY
        )
        self.parsing_stats = Stats()

    @always_inline
    fn next(inout self) raises -> RecordCoord:
        var read: RecordCoord
        read = self._parse_read()
        read.validate(self.stream)

        # TODO: Add basic stat for RecordCoord

        return read

    @always_inline
    fn _parse_read(
        inout self,
    ) raises -> RecordCoord:
        var line1 = self.stream.read_next_coord()
        if self.stream.buf[self.stream.map_pos_2_buf(line1.start)] != read_header:
            raise Error("Corrupt read header")

        var line2 = self.stream.read_next_coord()

        var line3 = self.stream.read_next_coord()
        if self.stream.buf[self.stream.map_pos_2_buf(line3.start)] != quality_header:
            raise Error("Corrupt quality header")

        var line4 = self.stream.read_next_coord()
        return RecordCoord(line1, line2, line3, line4)
