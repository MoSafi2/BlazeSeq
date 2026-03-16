from std.collections import List
from std.collections.string import String
from std.memory import Span
from std.iter import Iterator

from blazeseq.byte_string import BString
from blazeseq.CONSTS import EOF
from blazeseq.io.buffered import EOFError, LineIterator
from blazeseq.io.readers import Reader
from blazeseq.utils import memchr, format_parse_error


struct DelimitedRecord(Copyable, Movable, Sized, Writable):
    """A single delimited row, storing fields as owned `BString`s."""

    var _fields: List[BString]

    fn __init__(out self):
        self._fields = List[BString]()

    fn __init__(out self, *, var fields: List[BString]):
        self._fields = fields^

    @always_inline
    fn num_fields(self) -> Int:
        return len(self._fields)

    @always_inline
    fn __len__(self) -> Int:
        return len(self._fields)

    fn __getitem__(mut self, idx: Int) -> BString:
        return self._fields[idx].copy()

    fn get(mut self, idx: Int) -> Optional[BString]:
        if idx < 0 or idx >= len(self._fields):
            return None
        return self._fields[idx].copy()

    fn write_to[w: Writer](self, mut writer: w):
        var first = True
        for field in self._fields:
            if not first:
                writer.write("\t")
            first = False
            writer.write(String(field.as_span()))


fn _split_by_delimiter[
    O: Origin
](line: Span[UInt8, O], delimiter: UInt8,) -> List[Span[UInt8, O]]:
    """Split a single line into fields on `delimiter`, returning spans into `line`.
    """
    var fields = List[Span[UInt8, O]](capacity=10)
    var start = 0

    while True:
        var idx = memchr(line, delimiter, start)
        if idx == -1:
            # Final field (may be empty).
            var tail = line[start:]
            fields.append(tail)
            break
        else:
            var span = line[start:idx]
            fields.append(span)
            start = idx + 1
            if start > len(line):
                # Trailing delimiter -> final empty field.
                fields.append(Span[UInt8, O]())
                break

    return fields^


struct DelimitedReader[R: Reader](Movable):
    """Generic delimited-file reader over a `Reader`.

    Supports TSV, CSV, FAI, and similar formats by choosing an appropriate
    delimiter byte at construction time.

    Example:
        ```mojo
        from blazeseq.io.readers import MemoryReader
        from blazeseq.io.delimited import DelimitedReader

        var content = "col1\tcol2\n1\t2\n3\t4\n"
        var reader = MemoryReader(content.as_bytes())
        var delimited = DelimitedReader[MemoryReader](reader^, has_header=True)

        # Optional header row as owned `BString`s.
        if header_opt = delimited.header():
            let header = header_opt.value()
            print(header[0].to_string(), header[1].to_string())

        # Iterate over rows.
        for record in delimited.records():
            print(record[0].to_string(), record[1].to_string())
        ```
    """

    var lines: LineIterator[Self.R]
    var _delimiter: UInt8
    var _record_number: Int
    var _has_header: Bool
    var _header: Optional[List[BString]]
    var _expected_num_fields: Int

    fn __init__(
        out self,
        var reader: Self.R,
        delimiter: UInt8 = 9,  # ord("\t")
        has_header: Bool = False,
    ) raises:
        self.lines = LineIterator(reader^)
        self._delimiter = delimiter
        self._record_number = 0
        self._has_header = has_header
        self._header = None
        self._expected_num_fields = 0

        if self._has_header and self.lines.has_more():
            var header_record = self._read_next_record()
            self._header = header_record._fields.copy()

    @always_inline
    fn has_more(self) -> Bool:
        return self.lines.has_more()

    @always_inline
    fn get_record_number(ref self) -> Int:
        return self._record_number

    @always_inline
    fn get_line_number(ref self) -> Int:
        return self.lines.get_line_number()

    @always_inline
    fn get_file_position(ref self) -> Int64:
        return self.lines.get_file_position()

    fn header(mut self) -> Optional[List[BString]]:
        if self._header:
            return self._header.value().copy()
        return None

    fn next_record(mut self) raises -> DelimitedRecord:
        """Return the next row as a `DelimitedRecord`.

        Raises EOFError when no more records are available.
        """
        if not self.has_more():
            raise EOFError()

        var record = self._read_next_record()
        if self._expected_num_fields == 0:
            self._expected_num_fields = record.num_fields()
        elif record.num_fields() != self._expected_num_fields:
            var msg = format_parse_error(
                "Delimited row has inconsistent number of fields",
                self._record_number + 1,
                self.get_line_number(),
                self.get_file_position(),
                "",
            )
            raise Error(msg)

        self._record_number += 1
        return record^

    fn _read_next_record(mut self) raises -> DelimitedRecord:
        while True:
            var line = self.lines.next_line()
            if len(line) == 0:
                continue
            var field_spans = _split_by_delimiter(line, self._delimiter)
            var fields = List[BString]()
            for span in field_spans:
                fields.append(BString(span))
            return DelimitedRecord(fields=fields^)

    fn records(
        ref self,
    ) -> _DelimitedReaderIter[Self.R, origin_of(self)]:
        return _DelimitedReaderIter[Self.R, origin_of(self)](Pointer(to=self))

    fn __iter__(
        ref self,
    ) -> _DelimitedReaderIter[Self.R, origin_of(self)]:
        return _DelimitedReaderIter[Self.R, origin_of(self)](Pointer(to=self))


struct _DelimitedReaderIter[R: Reader, origin: Origin](Iterator):
    """Iterator adapter for `for row in reader` and `for row in reader.records()`.
    """

    comptime Element = DelimitedRecord

    var _src: Pointer[DelimitedReader[Self.R], Self.origin]

    fn __init__(
        out self,
        src: Pointer[DelimitedReader[Self.R], Self.origin],
    ):
        self._src = src

    fn __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    fn __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    fn __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[
            Pointer[DelimitedReader[Self.R], MutExternalOrigin]
        ](self._src)
        try:
            return mut_ptr[].next_record()
        except e:
            var msg = String(e)
            if msg == EOF or msg.startswith(EOF):
                raise StopIteration()
            else:
                print(msg)
                raise StopIteration()
