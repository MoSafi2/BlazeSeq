from blazeseq.record import FastqRecord, RecordCoord
from blazeseq.CONSTS import *
from blazeseq.iostream import BufferedReader, FileReader, Reader
import time


struct RecordParser[
    R: Reader, check_ascii: Bool = True, check_quality: Bool = True
]:
    var stream: BufferedReader[R, check_ascii=check_ascii]
    var quality_schema: QualitySchema

    fn __init__(out self, var reader: R, schema: String = "generic") raises:
        self.stream = BufferedReader[check_ascii=check_ascii](
            reader^, DEFAULT_CAPACITY
        )
        self.quality_schema = self._parse_schema(schema)

    fn parse_all(mut self) raises:
        while True:
            if not self.stream.has_more_lines():
                break
            var record: FastqRecord
            record = self._parse_record()
            record.validate_record()

            # ASCII validation is carried out in the reader
            @parameter
            if check_quality:
                record.validate_quality_schema()

    @always_inline
    fn next(mut self) raises -> Optional[FastqRecord]:
        """Method that lazily returns the Next record in the file."""
        if self.stream.has_more_lines():
            var record: FastqRecord
            record = self._parse_record()
            record.validate_record()

            # ASCII validation is carried out in the reader
            @parameter
            if check_quality:
                record.validate_quality_schema()
            return record^
        else:
            return None

    @always_inline
    fn _parse_record(mut self) raises -> FastqRecord:
        l1 = self.stream.get_next_line()
        l2 = self.stream.get_next_line()
        l3 = self.stream.get_next_line()
        l4 = self.stream.get_next_line()
        schema = self.quality_schema.copy()
        try:
            return FastqRecord(l1, l2, l3, l4, schema)
        except Error:
            raise

    @staticmethod
    @always_inline
    fn _parse_schema(quality_format: String) -> QualitySchema:
        var schema: QualitySchema

        if quality_format == "sanger":
            schema = materialize[sanger_schema]()
        elif quality_format == "solexa":
            schema = materialize[solexa_schema]()
        elif quality_format == "illumina_1.3":
            schema = materialize[illumina_1_3_schema]()
        elif quality_format == "illumina_1.5":
            schema = materialize[illumina_1_5_schema]()
        elif quality_format == "illumina_1.8":
            schema = materialize[illumina_1_8_schema]()
        elif quality_format == "generic":
            schema = materialize[generic_schema]()
        else:
            print(
                """Uknown quality schema please choose one of 'sanger', 'solexa',"
                " 'illumina_1.3', 'illumina_1.5' 'illumina_1.8', or 'generic'.
                Parsing with generic schema."""
            )
            return materialize[generic_schema]()
        return schema^


struct CoordParser[
    R: Reader, check_ascii: Bool = True, check_quality: Bool = True
]:
    var stream: BufferedLineIterator[R, check_ascii=check_ascii]

    fn __init__(out self, var reader: R) raises:
        self.stream = BufferedReader[check_ascii=check_ascii](
            reader^, DEFAULT_CAPACITY
        )

    @always_inline
    fn parse_all(mut self) raises:
        while True:
            record = self._parse_record()
            record.validate()

            @parameter
            if check_quality:
                record.validate_quality_schema()

    @always_inline
    fn next(
        mut self,
    ) raises -> RecordCoord[mut=False, o = origin_of(self.stream.buf)]:
        read = self._parse_record()
        read.validate()

        @parameter
        if check_quality:
            read.validate_quality_schema()
        return read

    @always_inline
    fn _parse_record(
        mut self,
    ) raises -> RecordCoord[
        mut=False, o = origin_of(origin_of(self.stream.buf))
    ]:
        var line1 = self.stream.get_next_line_span()

        var line2 = self.stream.get_next_line_span()
        var line3 = self.stream.get_next_line_span()
        var line4 = self.stream.get_next_line_span()

        return RecordCoord(
            line1.get_immutable(),
            line2.get_immutable(),
            line3.get_immutable(),
            line4.get_immutable(),
        )
