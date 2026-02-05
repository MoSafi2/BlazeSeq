from blazeseq.record import FastqRecord, RecordCoord
from blazeseq.CONSTS import *
from blazeseq.iostream import BufferedReader, FileReader, Reader
import time


struct RecordParser[
    R: Reader, check_ascii: Bool = True, check_quality: Bool = True
]:
    var stream: BufferedReader[Self.R, check_ascii = Self.check_ascii]
    var quality_schema: QualitySchema

    fn __init__(
        out self, var reader: Self.R, schema: String = "generic"
    ) raises:
        self.stream = BufferedReader[check_ascii = Self.check_ascii](
            reader^, DEFAULT_CAPACITY
        )
        self.quality_schema = self._parse_schema(schema)

    fn parse_all(mut self) raises:
        # Check if file is empty - if so, raise EOF error
        if not self.stream.has_more_lines():
            raise Error("EOF")

        while True:
            if not self.stream.has_more_lines():
                break
            var record: FastqRecord[self.check_quality]
            record = self._parse_record()
            record.validate_record()

            # ASCII validation is carried out in the reader
            @parameter
            if Self.check_quality:
                record.validate_quality_schema()

    @always_inline
    fn next(mut self) raises -> Optional[FastqRecord[val = self.check_quality]]:
        """Method that lazily returns the Next record in the file."""
        if self.stream.has_more_lines():
            var record: FastqRecord[self.check_quality]
            record = self._parse_record()
            record.validate_record()

            # ASCII validation is carried out in the reader
            @parameter
            if Self.check_quality:
                record.validate_quality_schema()
            return record^
        else:
            return None

    @always_inline
    fn _parse_record(mut self) raises -> FastqRecord[self.check_quality]:
        lines = self.stream.get_n_lines[4]()
        l1, l2, l3, l4 = lines[0], lines[1], lines[2], lines[3]
        schema = self.quality_schema.copy()
        try:
            return FastqRecord[val = self.check_quality](l1, l2, l3, l4, schema)
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
    var stream: BufferedReader[Self.R, check_ascii = Self.check_ascii]

    fn __init__(out self, var reader: Self.R) raises:
        self.stream = BufferedReader[check_ascii = self.check_ascii](
            reader^, DEFAULT_CAPACITY
        )

    @always_inline
    fn parse_all(mut self) raises:
        while True:
            record = self._parse_record()
            record.validate_record()

            @parameter
            if Self.check_quality:
                record.validate_quality_schema()

    @always_inline
    fn next(
        mut self,
    ) raises -> RecordCoord[validate_quality = Self.check_quality]:
        read = self._parse_record()
        read.validate_record()

        @parameter
        if self.check_quality:
            read.validate_quality_schema()
        return read^

    @always_inline
    fn _parse_record(
        mut self,
    ) raises -> RecordCoord[validate_quality = Self.check_quality]:
        lines = self.stream.get_n_lines[4]()
        l1, l2, l3, l4 = lines[0], lines[1], lines[2], lines[3]

        return RecordCoord[validate_quality = self.check_quality](
            l1, l2, l3, l4
        )
