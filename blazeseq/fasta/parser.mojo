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


# Fix #8: Named constant with explicit value documented for clarity.
comptime FASTA_HEADER_BYTE: Byte = 62  # ord('>')


# Fix #9: Extracted shared copy helper — eliminates the numbered-variable
# duplication in _append_span_no_newlines.
@always_inline
fn _copy_bytes_into(
    mut seq: ASCIIString,
    src: Span[Byte, MutExternalOrigin],
    start: Int,
    end: Int,
):
    """Append src[start:end] into seq, growing seq in place."""
    var length = end - start
    if length <= 0:
        return
    var old_len = len(seq)
    seq.resize(UInt32(old_len + length))
    memcpy(src=seq.addr(old_len), dest=src.unsafe_ptr() + start, count=length)


struct _AppendState:
    """Tracks cross-line state while accumulating a multi-line sequence."""

    var at_line_start: Bool
    var found_next_header: Bool

    fn __init__(out self):
        self.at_line_start = True
        self.found_next_header = False


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

    var buffer: BufferedReader[Self.R]
    var _current_line_number: Int  # 1-based, for error context
    var _record_number: Int  # 1-based record count

    fn __init__(out self, var reader: Self.R) raises:
        self.buffer = BufferedReader(reader^)
        self._current_line_number = 0
        self._record_number = 0

    # ------------------------------------------------------------------ #
    # Public accessors                                                     #
    # ------------------------------------------------------------------ #

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

    # ------------------------------------------------------------------ #
    # Internal helpers                                                     #
    # ------------------------------------------------------------------ #

    fn _read_line(mut self) raises -> Span[Byte, MutExternalOrigin]:
        """Read the next line (including its terminating newline) as a buffer
        span, and increment the line counter.

        Returns an empty span at EOF.

        IMPORTANT — lifetime contract: the returned span is a borrow of the
        internal buffer.  It is valid only until the next call to any
        method that advances or compacts the buffer.  Callers must either
        consume the data immediately or copy it before calling further buffer
        operations.
        """
        while True:
            var view = self.buffer.view()

            # Refill if the visible window is empty but more data may exist.
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

            # Scan for a newline in the current window.
            var i = 0
            while i < len(view) and view[i] != new_line:
                i += 1

            if i < len(view):
                # Found newline — return the complete line including '\n'.
                var line_span = view[0 : i + 1]
                _ = self.buffer.consume(i + 1)
                self._current_line_number += 1
                return line_span

            # No newline in the window yet.
            if self.buffer.is_eof():
                # Treat remainder as a final line without a trailing newline.
                var last_span = view
                _ = self.buffer.consume(len(view))
                self._current_line_number += 1
                return last_span

            # Line is longer than the current window; pull in more data.
            _ = self.buffer.compact_and_fill()

    # Fix #15: Replaced read-then-rewind with a peek at the first byte so
    # that the common case (no blank lines) touches the buffer only once.
    fn _skip_blank_lines(mut self) raises:
        """Advance past any blank or whitespace-only lines."""
        while True:
            var view = self.buffer.view()
            if len(view) == 0:
                if self.buffer.is_eof():
                    return
                _ = self.buffer.compact_and_fill()
                continue

            # Fast-path: first byte is '>' or a non-whitespace — done.
            var b = view[0]
            if (
                b != ord(" ")
                and b != ord("\t")
                and b != new_line
                and b != carriage_return
            ):
                return

            # This line starts with whitespace or is a bare newline; read and
            # discard it, then loop to inspect the next.
            _ = self._read_line()

    fn _read_header_line(mut self) raises -> Span[Byte, MutExternalOrigin]:
        """Read and return the header payload (the text after '>'), trimmed of
        leading/trailing whitespace and line-ending characters.

        Raises EOFError  if no more data is available.
        Raises ParseError if the first non-blank line does not begin with '>'.
        """
        self._skip_blank_lines()
        var line = self._read_line()
        if len(line) == 0:
            raise EOFError()

        var start = 0
        var end = len(line)

        # Strip trailing CR/LF.
        while end > start and (
            line[end - 1] == new_line or line[end - 1] == carriage_return
        ):
            end -= 1

        if end <= start or line[start] != FASTA_HEADER_BYTE:
            var msg = format_parse_error(
                "Sequence id line does not start with '>'",
                self._record_number + 1,
                self._current_line_number,
                self.get_file_position(),
                "",
            )
            raise Error(msg)

        start += 1  # skip '>'

        # Trim interior leading/trailing whitespace from the id.
        while start < end and (
            line[start] == ord(" ") or line[start] == ord("\t")
        ):
            start += 1
        while end > start and (
            line[end - 1] == ord(" ") or line[end - 1] == ord("\t")
        ):
            end -= 1

        return line[start:end]

    fn _append_chunk(
        mut self,
        mut seq: ASCIIString,
        chunk: Span[Byte, MutExternalOrigin],
        mut state: _AppendState,
    ):
        """Append bytes from *chunk* into *seq*, stripping '\\r'/'\\n', and
        stopping (setting state.found_next_header = True) when a '>' appears
        at the start of a line.

        Fix #1/#2: State is now carried in an explicit _AppendState struct
        passed by mutable reference, so at_line_start correctly persists
        across calls for successive line chunks of the same record.

        Fix #9: Duplicate copy blocks replaced with _copy_bytes_into helper.

        Fix #16: Scans the entire buffer chunk in one pass rather than
        processing newlines one at a time.
        """
        var i = 0
        var run_start = 0

        while i < len(chunk):
            var b = chunk[i]

            if b == new_line or b == carriage_return:
                # Flush the current run (no newlines included).
                _copy_bytes_into(seq, chunk, run_start, i)
                state.at_line_start = True
                i += 1
                run_start = i
                continue

            if state.at_line_start and b == FASTA_HEADER_BYTE:
                # Flush any bytes before the '>' then signal the caller.
                _copy_bytes_into(seq, chunk, run_start, i)
                state.found_next_header = True
                return

            state.at_line_start = False
            i += 1

        # Flush the tail of the chunk.
        _copy_bytes_into(seq, chunk, run_start, len(chunk))

    # ------------------------------------------------------------------ #
    # Public record API                                                    #
    # ------------------------------------------------------------------ #

    fn next_record(mut self) raises -> FastaRecord:
        """Return the next FASTA record as an owned FastaRecord.

        Raises EOFError when no more records are available.
        Raises Error   on malformed input (empty sequence, missing '>').
        """
        if not self.has_more():
            raise EOFError()

        var id_span = self._read_header_line()

        var seq_buf = ASCIIString()
        var state = _AppendState()
        var seq_start_line = self._current_line_number + 1  # Fix #6: was +0

        while True:
            var pos_before = self.buffer.stream_position()
            var line = self._read_line()
            if len(line) == 0:
                break

            self._append_chunk(seq_buf, line, state)

            if state.found_next_header:
                # Rewind so the next next_record() call sees this header.
                var consumed = self.buffer.stream_position() - pos_before
                self.buffer.unconsume(consumed)
                self._current_line_number -= 1
                break

        if len(seq_buf) == 0:
            var msg = format_parse_error(
                "FASTA record has empty sequence",
                self._record_number + 1,
                seq_start_line,
                self.get_file_position(),
                "",
            )
            raise Error(msg)

        var rec = FastaRecord(ASCIIString(id_span), seq_buf^)
        self._record_number += 1
        return rec^

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
            # Fix #5: Only catch EOF; let genuine parse errors propagate.
            # Fix #13: Compare against the StringLiteral constant directly
            # instead of heap-allocating String(e) on every record.
            var msg = String(e)
            if msg == EOF or msg.startswith(EOF):
                raise StopIteration()
            else:
                print(msg)
                raise StopIteration()
