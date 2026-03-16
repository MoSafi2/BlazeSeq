"""Parser for FASTA/FASTQ .fai index files.

The .fai format is a TAB-delimited text index with 5 columns for FASTA and
6 columns for FASTQ:

    NAME        (string)  – reference sequence name
    LENGTH      (int)     – total length of the reference (bases)
    OFFSET      (int)     – byte offset of first base in the FASTA/FASTQ file
    LINEBASES   (int)     – number of bases per sequence line
    LINEWIDTH   (int)     – number of bytes per sequence line (incl. newline)
    QUALOFFSET  (int)     – (FASTQ only) byte offset of first quality

This parser streams `FaiRecord` entries from a `Reader`, built on top of the
generic `DelimitedReader` (TAB-separated, no header).
"""


from std.collections import List
from std.collections.string import String
from std.iter import Iterator

from blazeseq.CONSTS import EOF
from blazeseq.fai.record import FaiRecord
from blazeseq.io.buffered import EOFError
from blazeseq.io.delimited import DelimitedReader, DelimitedRecord
from blazeseq.io.readers import Reader
from blazeseq.utils import format_parse_error
from blazeseq.byte_string import BString


struct FaiParser[R: Reader](Iterable, Movable):
    """Streaming parser for .fai index files over a `Reader`.

    API:
        - `next_record()` → `FaiRecord`   (raises EOFError when exhausted)
        - `for rec in parser`             (standard iteration)
        - `collect()` → `List[FaiRecord]` (helper that reads the whole index)
    """

    # Iterator type alias for `for rec in parser` loops.
    comptime IteratorType[origin: Origin] = _FaiParserRecordIter[Self.R, origin]

    var _rows: DelimitedReader[Self.R]

    fn __init__(out self, var reader: Self.R) raises:
        self._rows = DelimitedReader[Self.R](
            reader^, delimiter=9, has_header=False
        )

    # ------------------------------------------------------------------ #
    # Public accessors                                                   #
    # ------------------------------------------------------------------ #

    @always_inline
    fn has_more(self) -> Bool:
        return self._rows.has_more()

    @always_inline
    fn get_record_number(ref self) -> Int:
        return self._rows.get_record_number()

    @always_inline
    fn get_line_number(ref self) -> Int:
        return self._rows.get_line_number()

    @always_inline
    fn get_file_position(ref self) -> Int64:
        return self._rows.get_file_position()

    # ------------------------------------------------------------------ #
    # Record API                                                         #
    # ------------------------------------------------------------------ #

    fn next_record(mut self) raises -> FaiRecord:
        """Return the next FAI index row as a `FaiRecord`.

        Raises:
            EOFError: When no more records are available.
            Error:    On malformed input (wrong column count, non-integer fields).
        """
        if not self.has_more():
            raise EOFError()

        var row = self._rows.next_record()
        var n_fields = row.num_fields()
        if n_fields != 5 and n_fields != 6:
            var msg = format_parse_error(
                "FAI row must have 5 or 6 TAB-delimited columns",
                self.get_record_number() + 1,
                self.get_line_number(),
                self.get_file_position(),
                "",
            )
            raise Error(msg)

        # Column 0: NAME
        var name_bytes = row[0]

        # Helper to parse signed Int64 from a BString field.
        fn _parse_int64(field: BString) raises -> Int64:
            var s = field.to_string()
            # Let String->Int64 raise its own Error on malformed numbers.
            return Int64(atol(s))

        var length = _parse_int64(row[1])
        var offset = _parse_int64(row[2])
        var line_bases = _parse_int64(row[3])
        var line_width = _parse_int64(row[4])

        var qual_offset: Optional[Int64] = None
        if n_fields == 6:
            qual_offset = _parse_int64(row[5])

        return FaiRecord(
            Name=name_bytes^,
            Length=length,
            Offset=offset,
            LineBases=line_bases,
            LineWidth=line_width,
            QualOffset=qual_offset,
        )

    fn collect(mut self) raises -> List[FaiRecord]:
        """Read all rows from this index into memory."""
        var out = List[FaiRecord]()
        while True:
            try:
                var rec = self.next_record()
                out.append(rec^)
            except e:
                var msg = String(e)
                if msg == EOF or msg.startswith(EOF):
                    break
                raise e^
        return out^

    fn __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return {Pointer(to=self)}


struct _FaiParserRecordIter[R: Reader, origin: Origin](Iterator):
    """Iterator returned by `for rec in parser`."""

    comptime Element = FaiRecord

    var _src: Pointer[FaiParser[Self.R], Self.origin]

    fn __init__(
        out self,
        src: Pointer[FaiParser[Self.R], Self.origin],
    ):
        self._src = src

    fn __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    fn __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    fn __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[Pointer[FaiParser[Self.R], MutExternalOrigin]](
            self._src
        )
        try:
            return mut_ptr[].next_record()
        except e:
            var msg = String(e)
            if msg == EOF or msg.startswith(EOF):
                raise StopIteration()
            else:
                print(msg)
                raise StopIteration()
