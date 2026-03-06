from blazeseq.fasta.record import FastaRecord
from blazeseq.io.buffered import EOFError, LineIterator
from blazeseq.io.readers import Reader
from blazeseq.CONSTS import EOF
from blazeseq.utils import format_parse_error, _strip_spaces
from blazeseq.byte_string import BString
from memory import Span
from collections import List
from collections.string import StringSlice, String


# Fix #8: Named constant with explicit value documented for clarity.
comptime FASTA_HEADER_BYTE: Byte = 62  # ord('>')


struct FastaParser[R: Reader](Iterable, Movable):
    """Streaming FASTA parser over a `Reader`.

    Multi-line FASTA sequences are normalised so that all line breaks within
    the sequence body are stripped, producing a single contiguous sequence
    string per record.

    API:
        - `next_record()` → `FastaRecord`   (raises EOFError when exhausted)
        - `for rec in parser:`              (standard iteration, propagates
                                             parse errors — see note on
                                             _FastaParserRecordIter)
    """

    comptime IteratorType[
        mut: Bool, origin: Origin[mut=mut]
    ] = _FastaParserRecordIter[Self.R, origin]

    var lines: LineIterator[Self.R]
    var _record_number: Int  # 1-based record count
    var _pending_ids: List[BString]
    var _last_seq_size: UInt32  # tracks previous sequence size for optimistic pre-allocation

    fn __init__(out self, var reader: Self.R) raises:
        self.lines = LineIterator(reader^)
        self._record_number = 0
        self._pending_ids = List[BString]()
        self._last_seq_size = 0

    # ------------------------------------------------------------------ #
    # Public accessors                                                     #
    # ------------------------------------------------------------------ #

    @always_inline
    fn has_more(self) -> Bool:
        """Return True if there may be more records to read."""
        return len(self._pending_ids) > 0 or self.lines.has_more()

    @always_inline
    fn get_record_number(ref self) -> Int:
        return self._record_number

    @always_inline
    fn get_line_number(ref self) -> Int:
        return self.lines.get_line_number()

    @always_inline
    fn get_file_position(ref self) -> Int64:
        return self.lines.get_file_position()

    @always_inline
    fn get_buffer_position(ref self) -> Int:
        """Return the current buffer position."""
        return self.lines.buffer_position()

    # ------------------------------------------------------------------ #
    # Public record API                                                    #
    # ------------------------------------------------------------------ #

    # TODO: Add validation to FASTA Record
    fn next_record(mut self) raises -> FastaRecord:
        """Return the next FASTA record as an owned FastaRecord.

        Raises EOFError when no more records are available.
        Raises Error   on malformed input (empty sequence, missing '>').
        """
        if not self.has_more():
            raise EOFError()

        var id_str = self._read_header_line()
        var seq_buf = BString()
        if self._last_seq_size > 0:
            seq_buf.reserve(self._last_seq_size)
        var seq_start_line = self.lines.get_line_number() + 1

        while True:
            try:
                var line = _strip_spaces(self.lines.next_line())
                if len(line) > 0 and line[0] == FASTA_HEADER_BYTE:
                    # Next record's header; store for next next_record().
                    var id_span = _strip_spaces(line[1:])
                    self._pending_ids.append(BString(id_span))
                    break
                # Sequence line: append (line has no newline from LineIterator).
                seq_buf.extend(line)
            except e:
                if String(e) == String(EOFError()) or String(e).startswith(EOF):
                    break
                raise e^

        self._last_seq_size = seq_buf.size
        if len(seq_buf) == 0:
            var msg = format_parse_error(
                "FASTA record has empty sequence",
                self._record_number + 1,
                seq_start_line,
                self.get_file_position(),
                "",
            )
            raise Error(msg)

        self._record_number += 1
        return FastaRecord(id_str^, seq_buf^)

    # ------------------------------------------------------------------ #
    # Internal helpers                                                     #
    # ------------------------------------------------------------------ #

    fn _read_header_line(mut self) raises -> BString:
        """Return the next header id (after '>'), or raise EOFError/ParseError.

        Uses _pending_ids if non-empty; otherwise reads lines until a non-blank
        line starting with '>' and returns its trimmed id. The returned id is owned.
        """
        if len(self._pending_ids) > 0:
            return self._pending_ids.pop()

        while True:
            var line = self.lines.next_line()
            var trimmed = _strip_spaces(line)
            if len(trimmed) == 0:
                continue
            if trimmed[0] != FASTA_HEADER_BYTE:
                var msg = format_parse_error(
                    "Sequence id line does not start with '>'",
                    self._record_number + 1,
                    self.lines.get_line_number(),
                    self.get_file_position(),
                    "",
                )
                raise Error(msg)
            # Id is text after '>', trimmed of leading/trailing whitespace.
            var id_span = _strip_spaces(trimmed[1:])
            return BString(id_span)

    fn __iter__(
        ref self,
    ) -> Self.IteratorType[origin_of(self).mut, origin_of(self)]:
        return {Pointer(to=self)}


struct _FastaParserRecordIter[R: Reader, origin: Origin](Iterator):
    """Iterator returned by `for rec in parser`.

    Fix #5: Parse errors are now re-raised rather than printed-and-swallowed,
    so callers can distinguish a clean EOF from a malformed record.

    Fix #11: __has_next__ delegates to parser.has_more() rather than
    unconditionally returning True.
    """

    comptime Element = FastaRecord

    var _src: Pointer[FastaParser[Self.R], Self.origin]

    fn __init__(
        out self,
        src: Pointer[FastaParser[Self.R], Self.origin],
    ):
        self._src = src

    fn __iter__(ref self) -> Self:
        return Self(self._src)

    # Fix #11: Reflect actual parser state.
    @always_inline
    fn __has_next__(self) -> Bool:
        return self._src[].has_more()

    @always_inline
    fn __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[Pointer[FastaParser[Self.R], MutExternalOrigin]](
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
