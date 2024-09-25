from blazeseq.record import FastqRecord, RecordCoord
from blazeseq.helpers import (
    find_last_read_header,
    get_next_line,
)
from blazeseq.CONSTS import *
from blazeseq.iostream import BufferedLineIterator, FileReader
import time
from utils import StringRef


struct RecordParser[validate_ascii: Bool = True, validate_quality: Bool = True]:
    var stream: BufferedLineIterator[FileReader, check_ascii=validate_ascii]
    var quality_schema: QualitySchema

    fn __init__(
        inout self, path: String, schema: String = "generic"
    ) raises -> None:
        self.stream = BufferedLineIterator[
            FileReader, check_ascii=validate_ascii
        ](path, DEFAULT_CAPACITY)
        self.quality_schema = self._parse_schema(schema)

    fn parse_all(inout self) raises:
        while True:
            var record: FastqRecord
            record = self._parse_record()
            # print(record)
            record.validate_record()

            # ASCII validation is carried out in the reader
            @parameter
            if validate_quality:
                record.validate_quality_schema()

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
                """Uknown quality schema please choose one of 'sanger', 'solexa',"
                " 'illumina_1.3', 'illumina_1.5' 'illumina_1.8', or 'generic'.
                Parsing with generic schema."""
            )
            return generic_schema
        return schema


struct CoordParser:
    var stream: BufferedLineIterator[FileReader]

    fn __init__(inout self, path: String) raises -> None:
        self.stream = BufferedLineIterator[FileReader](path, DEFAULT_CAPACITY)

    @always_inline
    fn parse_all(inout self) raises:
        while True:
            var record: RecordCoord
            record = self._parse_record()
            record.validate()

    @always_inline
    fn next(inout self) raises -> RecordCoord:
        var read: RecordCoord
        read = self._parse_record()
        read.validate()
        return read

    @always_inline
    fn _parse_record(inout self) raises -> RecordCoord:
        var line1 = self.stream.read_next_coord()
        if (
            self.stream.buf[self.stream.map_pos_2_buf(line1.start.or_else(0))]
            != read_header
        ):
            raise Error("Sequence Header is corrupt")

        var line2 = self.stream.read_next_coord()

        var line3 = self.stream.read_next_coord()
        if (
            self.stream.buf[self.stream.map_pos_2_buf(line3.start.or_else(0))]
            != quality_header
        ):
            raise Error("Quality Header is corrupt")

        var line4 = self.stream.read_next_coord()
        return RecordCoord(line1, line2, line3, line4)

    @always_inline
    fn _parse_record2(inout self) raises -> RecordCoord:
        var coords = self.stream.read_n_coords[4]()
        var n = 0
        if self.stream.buf[coords[0].start.or_else(0)] != read_header:
            print(
                coords[n],
                StringRef(
                    self.stream.buf._ptr + coords[n].start.or_else(0),
                    coords[n].end.or_else(0) - coords[n].start.or_else(0),
                ),
            )
            raise Error("Sequence Header is corrupt")

        if self.stream.buf[coords[2].start.or_else(0)] != quality_header:
            raise Error("Quality Header is corrupt")

        return RecordCoord(coords[0], coords[1], coords[2], coords[3])


