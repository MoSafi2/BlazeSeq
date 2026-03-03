from blazeseq.fasta.record import FastaRecord
from blazeseq.io.buffered import EOFError, BufferedReader
from blazeseq.io.readers import Reader
from blazeseq.CONSTS import new_line, carriage_return, EOF
from blazeseq.errors import ParseError
from blazeseq.utils import format_parse_error
from blazeseq.ascii_string import ASCIIString
from memory import Span
from collections.string import StringSlice, String
from memory import memcpy


comptime fasta_header = ord(">")


struct FastaParser[R: Reader](Iterable, Movable):
    """Streaming FASTA parser over a `Reader`.

    Multi-line FASTA sequences are normalized so that all line breaks within
    the sequence are removed and stored as a single logical line.

    API:
        - `next_record()` → `FastaRecord`
        - `records()` → iterator over `FastaRecord`
    """

    comptime IteratorType[
        mut: Bool, origin: Origin[mut=mut]
    ] = _FastaParserRecordIter[Self.R, origin]

    var buffer: BufferedReader[Self.R]
    var _current_line_number: Int  # 1-based, for error context
    var _record_number: Int  # 1-based record count

    fn __init__(out self, var reader: Self.R) raises:
        self.buffer = BufferedReader(reader^)
        self._current_line_number = 0
        self._record_number = 0

    @always_inline
    fn has_more(self) -> Bool:
        """Return True if there may be more records to read."""
        return self.buffer.available() > 0 or not self.buffer.is_eof()

    @always_inline
    fn get_record_number(ref self) -> Int:
        return self._record_number

    @always_inline
    fn get_line_number(ref self) -> Int:
        return self._current_line_number

    @always_inline
    fn get_file_position(ref self) -> Int64:
        return Int64(self.buffer.stream_position())

    fn _read_line(mut self) raises -> Span[Byte, MutExternalOrigin]:
        """Read next line (including newline) as a span; updates line counter.

        Returns empty span on EOF with no data.
        """
        while True:
            var view = self.buffer.view()
            if len(view) == 0:
                if self.buffer.is_eof():
                    return Span[Byte, MutExternalOrigin](
                        ptr=view.unsafe_ptr(), length=0
                    )
                _ = self.buffer.compact_and_fill()
                view = self.buffer.view()
                if len(view) == 0:
                    return Span[Byte, MutExternalOrigin](
                        ptr=view.unsafe_ptr(), length=0
                    )

            # Find newline
            var i = 0
            while i < len(view) and view[i] != new_line:
                i += 1

            if i < len(view) and view[i] == new_line:
                var line_span = view[0 : i + 1]
                _ = self.buffer.consume(i + 1)
                self._current_line_number += 1
                return line_span

            # No newline yet, need more data (line longer than buffer slice)
            if self.buffer.is_eof():
                # Treat rest of buffer as last line without trailing newline
                var last_span = view
                _ = self.buffer.consume(len(view))
                self._current_line_number += 1
                return last_span

            _ = self.buffer.compact_and_fill()

    fn _skip_blank_and_comment_lines(mut self) raises:
        """Skip blank lines until a non-empty line or EOF."""
        while True:
            var pos_before = self.buffer.stream_position()
            var line = self._read_line()
            if len(line) == 0:
                return
            # Trim CR and LF to test emptiness
            var start = 0
            var end = len(line)
            while end > start and (
                line[end - 1] == new_line or line[end - 1] == carriage_return
            ):
                end -= 1
            var is_blank = True
            for i in range(start, end):
                var b = line[i]
                if b != ord(" ") and b != ord("\t"):
                    is_blank = False
                    break
            if not is_blank:
                # Rewind this line for caller
                var consumed = self.buffer.stream_position() - pos_before
                self.buffer.unconsume(consumed)
                self._current_line_number -= 1
                return

    fn _read_header_line(mut self) raises -> Span[Byte, MutExternalOrigin]:
        """Read and return the header line (without leading '>').

        Raises ParseError if the first non-blank line does not start with '>'.
        """
        self._skip_blank_and_comment_lines()
        var line = self._read_line()
        if len(line) == 0:
            raise EOFError()

        var start = 0
        var end = len(line)
        while end > start and (
            line[end - 1] == new_line or line[end - 1] == carriage_return
        ):
            end -= 1

        if end <= start or line[start] != fasta_header:
            var msg = format_parse_error(
                "Sequence id line does not start with '>'",
                self._record_number + 1,
                self._current_line_number,
                self.get_file_position(),
                "",
            )
            raise Error(msg)

        start += 1  # skip '>'
        while start < end and (
            line[start] == ord(" ") or line[start] == ord("\t")
        ):
            start += 1
        while end > start and (
            line[end - 1] == ord(" ") or line[end - 1] == ord("\t")
        ):
            end -= 1
        return line[start:end]

    fn _append_span_no_newlines(
        mut self,
        mut seq: ASCIIString,
        chunk: Span[Byte, MutExternalOrigin],
        mut at_line_start: Bool,
        mut found_next_header: Bool,
    ):
        """Append bytes from chunk into seq, stripping '\\n'/'\\r' and stopping
        when a '>' appears at start-of-line (sets found_next_header=True)."""
        var i = 0
        var run_start = 0
        while i < len(chunk):
            var b = chunk[i]
            if b == new_line or b == carriage_return:
                if i > run_start:
                    var length = i - run_start
                    var old_len = len(seq)
                    seq.resize(UInt32(old_len + length))
                    var dest = seq.addr(old_len)
                    var src = chunk.unsafe_ptr() + run_start
                    memcpy(dest=dest, src=src, count=length)
                at_line_start = True
                i += 1
                run_start = i
                continue
            if at_line_start and b == fasta_header:
                if i > run_start:
                    var length2 = i - run_start
                    var old_len2 = len(seq)
                    seq.resize(UInt32(old_len2 + length2))
                    var dest2 = seq.addr(old_len2)
                    var src2 = chunk.unsafe_ptr() + run_start
                    memcpy(dest=dest2, src=src2, count=length2)
                found_next_header = True
                return

            at_line_start = False
            i += 1

        if len(chunk) > run_start:
            var tail_len = len(chunk) - run_start
            var old_len3 = len(seq)
            seq.resize(UInt32(old_len3 + tail_len))
            var dest3 = seq.addr(old_len3)
            var src3 = chunk.unsafe_ptr() + run_start
            memcpy(dest=dest3, src=src3, count=tail_len)

    fn next_record(mut self) raises -> FastaRecord:
        """Return the next FASTA record as an owned FastaRecord."""
        if not self.has_more():
            raise EOFError()

        var id_span = self._read_header_line()

        var seq_buf = ASCIIString()
        var at_line_start = True
        var seq_start_line = self._current_line_number + 0

        while True:
            var pos_before = self.buffer.stream_position()
            var line = self._read_line()
            if len(line) == 0:
                break

            var tmp_found_header = False
            self._append_span_no_newlines(
                seq_buf, line, at_line_start, tmp_found_header
            )
            if tmp_found_header:
                var consumed = self.buffer.stream_position() - pos_before
                self.buffer.unconsume(consumed)
                self._current_line_number -= 1
                break

        if len(seq_buf) == 0:
            var msg2 = format_parse_error(
                "FASTA record has empty sequence",
                self._record_number + 1,
                seq_start_line,
                self.get_file_position(),
                "",
            )
            raise Error(msg2)
            
        rec = FastaRecord(ASCIIString(id_span), seq_buf^)
        self._record_number += 1
        return rec^

    fn __iter__(ref self,) -> Self.IteratorType[origin_of(self).mut, origin_of(self)]:
        return  {Pointer(to=self)}


struct _FastaParserRecordIter[R: Reader, origin: Origin](Iterator):
    """Iterator over owned FastaRecord; use `parser.records()`."""

    comptime Element = FastaRecord

    var _src: Pointer[FastaParser[Self.R], Self.origin]

    fn __init__(
        out self,
        src: Pointer[FastaParser[Self.R], Self.origin],
    ):
        self._src = src

    fn __iter__(ref self) -> Self:
        return Self(self._src)

    @always_inline
    fn __has_next__(self) -> Bool:
        return True

    @always_inline
    fn __next__(mut self) raises StopIteration -> Self.Element:
        var mut_ptr = rebind[Pointer[FastaParser[Self.R], MutExternalOrigin]](
            self._src
        )
        try:
            return mut_ptr[].next_record()
        except e:
            if String(e) == EOF or String(e).startswith(EOF):
                raise StopIteration()
            else:
                print(e)
                raise StopIteration()


fn records[
    R: Reader
](ref parser: FastaParser[R],) -> _FastaParserRecordIter[R, origin_of(parser)]:
    """Return an iterator over owned FastaRecord."""
    return _FastaParserRecordIter[R, origin_of(parser)](Pointer(to=parser))
