from . import FastqRecord, RecordCoord
from .helpers import (
    find_last_read_header,
    get_next_line,
)
from .CONSTS import *
from . import FullStats
from .iostream import BufferedLineIterator, FileReader
import time


struct RecordParser[validate_ascii: Bool = False, validate_quality: Bool = False]:
    var stream: BufferedLineIterator[FileReader, check_ascii=validate_ascii]
    var quality_schema: QualitySchema

    fn __init__(inout self, path: String, schema: String = "generic") raises -> None:
        self.stream = BufferedLineIterator[FileReader, check_ascii=validate_ascii](
            path, DEFAULT_CAPACITY
        )
        self.quality_schema = self._parse_schema(schema)

    fn parse_all(inout self) raises:
        while True:
            var record = self.next()

    @always_inline
    fn next(inout self) raises -> FastqRecord:
        """Method that lazily returns the Next record in the file."""
        var record: FastqRecord
        record = self._parse_record()
        record.validate_record()

        # ASCII validation is carried out in the reader
        @parameter
        if validate_quality:
            record.validate_quality_schema()

        return record

    @always_inline
    fn _parse_record(inout self) raises -> FastqRecord:
        var line1 = self.stream.read_next_line()
        var line2 = self.stream.read_next_line()
        var line3 = self.stream.read_next_line()
        var line4 = self.stream.read_next_line()
        return FastqRecord(line1, line2, line3, line4, self.quality_schema)

    @staticmethod
    @always_inline
    fn _parse_schema(quality_format: String) -> QualitySchema:
        var schema: QualitySchema

        if quality_format == "sanger":
            schema = sanger_schema
        elif quality_format == "solexa":
            schema = solexa_schema
        elif quality_format == "illumina_1.3":
            schema = illumina_1_3_schema
        elif quality_format == "illumina_1.5":
            schema = illumina_1_5_schema
        elif quality_format == "illumina_1.8":
            schema = illumina_1_8
        elif quality_format == "generic":
            schema = generic_schema
        else:
            print(
                "Uknown quality schema please choose one of 'sanger', 'solexa',"
                " 'illumina_1.3', 'illumina_1.5' 'illumina_1.8', or 'generic'"
            )
            return generic_schema
        return schema


struct CoordParser[validate_ascii: Bool = False]:
    var stream: BufferedLineIterator[FileReader, check_ascii=validate_ascii]

    fn __init__(
        inout self,
        path: String,
    ) raises -> None:
        self.stream = BufferedLineIterator[FileReader, check_ascii=validate_ascii](
            path, DEFAULT_CAPACITY
        )

    @always_inline
    fn next(inout self) raises -> RecordCoord:
        var read: RecordCoord
        read = self._parse_read()
        read.validate(self.stream)
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
