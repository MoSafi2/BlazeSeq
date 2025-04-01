from blazeseq.record import FastqRecord, RecordCoord
from blazeseq.CONSTS import *
from blazeseq.iostream import BufferedLineIterator, FileReader
import time


struct RecordParser[validate_ascii: Bool = True, validate_quality: Bool = True]:
    var stream: BufferedLineIterator[FileReader, check_ascii=validate_ascii]
    var quality_schema: QualitySchema

    fn __init__(out self, path: String, schema: String = "generic") raises:
        self.stream = BufferedLineIterator[
            FileReader, check_ascii=validate_ascii
        ](path, DEFAULT_CAPACITY)
        self.quality_schema = self._parse_schema(schema)

    fn parse_all(mut self) raises:
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
    fn next(mut self) raises -> FastqRecord:
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
    fn _parse_record(mut self) raises -> FastqRecord:
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
            schema = illumina_1_8_schema
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


struct CoordParser[validate_ascii: Bool = True, validate_quality: Bool = True]:
    var stream: BufferedLineIterator[FileReader, check_ascii=validate_ascii]

    fn __init__(out self, path: String) raises:
        self.stream = BufferedLineIterator[
            FileReader, check_ascii=validate_ascii
        ](path, DEFAULT_CAPACITY)

    @always_inline
    fn parse_all(mut self) raises:
        while True:
            var record: RecordCoord
            record = self._parse_record()
            record.validate()

            @parameter
            if validate_quality:
                record.validate_quality_schema()

    @always_inline
    fn next(mut self) raises -> RecordCoord:
        read = self._parse_record()
        read.validate()

        @parameter
        if validate_quality:
            read.validate_quality_schema()
        return read

    @always_inline
    fn _parse_record(
        mut self,
    ) raises -> RecordCoord:
        var line1 = self.stream.read_next_coord()
        var line2 = self.stream.read_next_coord()
        var line3 = self.stream.read_next_coord()
        var line4 = self.stream.read_next_coord()

        return RecordCoord(line1, line2, line3, line4)
