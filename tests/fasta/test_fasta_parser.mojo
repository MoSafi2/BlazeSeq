"""Comprehensive test suite for the public API of FastaParser and FastaRecord.

Coverage:
  - Iteration: for-in iterator and next_record() loop over multiple records
  - Chunk boundaries: records/headers/sequences broken across BufferedReader refills
  - Large records: sequences spanning many chunk deliveries
  - Format enforcement – valid inputs: blank lines, CRLF, whitespace trimming, etc.
  - Format enforcement – invalid inputs: missing header marker, empty sequences, etc.
  - FastaRecord API: byte_len, __len__, __str__, equality
  - Public parser accessors: has_more(), get_record_number(), get_line_number()
"""

from blazeseq import FastaParser, FastaRecord, FileReader, MemoryReader
from blazeseq.CONSTS import EOF
from pathlib import Path
from testing import assert_equal, assert_true, assert_raises, TestSuite
from memory import memcpy, Span
from blazeseq.io.readers import Reader


# ──────────────────────────────────────────────────────────────────────────────
# Test helpers
# ──────────────────────────────────────────────────────────────────────────────


fn _bytes(s: String) -> List[Byte]:
    """Convert a String literal to an owned List[Byte] for MemoryReader."""
    var out = List[Byte]()
    for b in s.as_bytes():
        out.append(b)
    return out^


struct ChunkedMemoryReader(Movable, Reader):
    """In-memory Reader that returns at most `chunk_size` bytes per call.

    Used to simulate chunked I/O so that records and lines span multiple
    BufferedReader refill cycles, exercising the compact_and_fill path in
    FastaParser._read_line().
    """

    var data: List[Byte]
    var position: Int
    var chunk_size: Int

    fn __init__(out self, var data: List[Byte], chunk_size: Int):
        self.data = data^
        self.position = 0
        self.chunk_size = chunk_size

    fn __moveinit__(out self, deinit other: Self):
        self.data = other.data^
        self.position = other.position
        self.chunk_size = other.chunk_size

    fn read_to_buffer(
        mut self,
        mut buf: Span[Byte, MutExternalOrigin],
        amt: Int,
        pos: Int,
    ) raises -> UInt64:
        if pos > len(buf):
            raise Error("Position is outside the buffer")
        if amt < 0:
            raise Error("The amount to be read should be positive")
        if self.position >= len(self.data):
            return 0
        var available = len(self.data) - self.position
        var bytes_to_read = min(min(amt, available), self.chunk_size)
        if bytes_to_read > 0:
            var dest = Span[Byte, MutExternalOrigin](
                ptr=buf.unsafe_ptr() + pos, length=len(buf) - pos
            )
            memcpy(
                dest=dest.unsafe_ptr(),
                src=self.data.unsafe_ptr() + self.position,
                count=bytes_to_read,
            )
            self.position += bytes_to_read
        return UInt64(bytes_to_read)


# ──────────────────────────────────────────────────────────────────────────────
# Original tests (retained verbatim, comments cleaned up)
# ──────────────────────────────────────────────────────────────────────────────


fn test_single_record_single_line() raises:
    """Single-record, single-line sequence."""
    var data = ">id1\nACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(
        String(rec.id()),
        "id1",
        "ID should match header without '>'",
    )
    assert_equal(
        String(rec.sequence()),
        "ACGT",
        "Sequence should match",
    )
    _ = rec


fn test_single_record_multiline() raises:
    """Single-record, multi-line sequence is normalized to a single line."""
    var data = ">id1\nACG\nTTA\nGG\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(
        String(rec.sequence()),
        "ACGTTAGG",
        "Multi-line sequence should be concatenated without newlines",
    )
    _ = rec


fn test_multiple_records_back_to_back() raises:
    """Multiple records where the next header immediately follows a sequence."""
    var data = ">id1\nACGT\n>id2\nTTAA\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)

    var rec1 = parser.next_record()
    assert_equal(String(rec1.id()), "id1")
    assert_equal(String(rec1.sequence()), "ACGT")

    var rec2 = parser.next_record()
    assert_equal(String(rec2.id()), "id2")
    assert_equal(String(rec2.sequence()), "TTAA")
    _ = rec2
    _ = rec1


fn test_record_end_at_eof_without_newline() raises:
    """Record ending at EOF without a terminal newline is accepted."""
    var data = ">id1\nACGT"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(
        String(rec.sequence()),
        "ACGT",
    )
    _ = rec


fn test_invalid_first_line_not_header() raises:
    """A first non-empty line not starting with '>' must raise a parse error."""
    var data = "ACGT\n>id1\nACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var raised = False
    try:
        _ = parser.next_record()
    except e:
        raised = True
        assert_true(
            String(e).find("does not start with") >= 0,
            "Expected 'does not start with' in error, got: " + String(e),
        )
    assert_true(raised, "Expected a parse error for a non-header first line")


fn test_records_iterator() raises:
    """For-in iterator over FastaParser yields all records with correct data."""
    var data = ">id1\nAC\nGT\n>id2\nTT\nAA\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var ids = List[String]()
    var seqs = List[String]()
    for rec in parser:
        ids.append(String(rec.id()))
        seqs.append(String(rec.sequence()))
    assert_equal(len(ids), 2)
    assert_equal(ids[0], "id1")
    assert_equal(ids[1], "id2")
    assert_equal(seqs[0], "ACGT")
    assert_equal(seqs[1], "TTAA")


# ──────────────────────────────────────────────────────────────────────────────
# Iteration over multiple records
# ──────────────────────────────────────────────────────────────────────────────


fn test_iterator_ten_records() raises:
    """`for-in` iterator yields exactly ten records with correct sequences."""
    var data = String("")
    for i in range(10):
        data += ">seq" + String(i) + "\n" + "ACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var count = 0
    for rec in parser:
        assert_equal(
            String(rec.sequence()),
            "ACGT",
        )
        count += 1
    assert_equal(count, 10, "Iterator should yield exactly 10 records")


fn test_next_record_loop_ten_records() raises:
    """`next_record()` with `has_more()` correctly reads ten records in a loop.
    """
    var data = String("")
    for i in range(10):
        data += ">seq" + String(i) + "\n" + "ACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var count = 0
    while parser.has_more():
        var rec = parser.next_record()
        assert_equal(
            String(rec.sequence()),
            "ACGT",
        )
        count += 1
        _ = rec
    assert_equal(count, 10, "next_record loop should yield exactly 10 records")


fn test_next_record_exhausted_raises_eof() raises:
    """`next_record()` raises EOFError once all records have been consumed."""
    var data = ">id1\nACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    _ = parser.next_record()
    var raised = False
    try:
        _ = parser.next_record()
    except e:
        raised = True
        assert_true(
            String(e).startswith(EOF),
            "Expected EOFError, got: " + String(e),
        )
    assert_true(raised, "Expected EOFError after all records consumed")


fn test_has_more_semantics() raises:
    """Has_more() is True before reads and False after all records consumed."""
    var data = ">id1\nACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    assert_true(parser.has_more(), "has_more() should be True before any reads")
    _ = parser.next_record()
    assert_true(
        not parser.has_more(),
        "has_more() should be False after all records consumed",
    )


fn test_get_record_number_tracking() raises:
    """Get_record_number() returns the 1-based count of successfully read records.
    """
    var data = ">id1\nACGT\n>id2\nTTAA\n>id3\nGGCC\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    assert_equal(parser.get_record_number(), 0, "Initially 0 records read")
    _ = parser.next_record()
    assert_equal(parser.get_record_number(), 1)
    _ = parser.next_record()
    assert_equal(parser.get_record_number(), 2)
    _ = parser.next_record()
    assert_equal(parser.get_record_number(), 3)


fn test_iterator_five_records_ids_and_sequences() raises:
    """Iterator yields correct IDs and sequences for 5 heterogeneous records."""
    var data = ">alpha\nAAAA\n>beta\nCCCC\n>gamma\nGGGG\n>delta\nTTTT\n>epsilon\nACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var expected_ids = List[String]()
    expected_ids.append("alpha")
    expected_ids.append("beta")
    expected_ids.append("gamma")
    expected_ids.append("delta")
    expected_ids.append("epsilon")
    var expected_seqs = List[String]()
    expected_seqs.append("AAAA")
    expected_seqs.append("CCCC")
    expected_seqs.append("GGGG")
    expected_seqs.append("TTTT")
    expected_seqs.append("ACGT")
    var index = 0
    for rec in parser:
        assert_equal(
            String(rec.id()),
            expected_ids[index],
        )
        assert_equal(
            String(rec.sequence()),
            expected_seqs[index],
        )
        index += 1
    assert_equal(index, 5, "Should have iterated over exactly 5 records")


# ──────────────────────────────────────────────────────────────────────────────
# Records broken across chunk boundaries
# ──────────────────────────────────────────────────────────────────────────────


fn test_record_broken_across_chunks() raises:
    """A record is correctly parsed when data arrives 4 bytes at a time.

    With chunk_size=4 the BufferedReader must call compact_and_fill() several
    times to assemble a complete line, exercising the refill path.
    """
    var data = ">id1\nACGTACGT\n"
    var reader = ChunkedMemoryReader(_bytes(data), chunk_size=4)
    var parser = FastaParser[ChunkedMemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(
        String(rec.id()),
        "id1",
    )
    assert_equal(
        String(rec.sequence()),
        "ACGTACGT",
    )
    _ = rec


fn test_header_broken_across_chunks() raises:
    """A long header line spanning multiple chunk deliveries is parsed correctly.
    """
    # ">long_identifier_name\n" is 22 bytes; chunk_size=5 forces 5 refills.
    var data = ">long_identifier_name\nACGT\n"
    var reader = ChunkedMemoryReader(_bytes(data), chunk_size=5)
    var parser = FastaParser[ChunkedMemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(
        String(rec.id()),
        "long_identifier_name",
    )
    assert_equal(
        String(rec.sequence()),
        "ACGT",
    )
    _ = rec


fn test_sequence_larger_than_chunk_size() raises:
    """A 100-base sequence delivered 7 bytes at a time is accumulated correctly.
    """
    var seq = String("")
    for i in range(25):
        seq += "ACGT"
    var data = ">id1\n" + seq + "\n"
    var reader = ChunkedMemoryReader(_bytes(data), chunk_size=7)
    var parser = FastaParser[ChunkedMemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(
        String(rec.sequence()),
        seq,
        (
            "100-base sequence should be accumulated correctly across chunk"
            " refills"
        ),
    )
    _ = rec


fn test_large_multiline_sequence_with_chunks() raises:
    """A multi-line sequence totalling 60 bases, delivered 8 bytes at a time.

    Tests that _AppendState correctly persists across multiple chunk deliveries
    during multi-line sequence accumulation.
    """
    var data = ">id1\nACGTACGTAC\nGTACGTACGT\nACGTACGTAC\nGTACGTACGT\nACGTACGTAC\nGTACGTACGT\n"
    var expected_seq = (
        "ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGT"
    )
    var reader = ChunkedMemoryReader(_bytes(data), chunk_size=8)
    var parser = FastaParser[ChunkedMemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(
        String(rec.sequence()),
        expected_seq,
        "60-base multi-line sequence should be normalized correctly",
    )
    _ = rec


fn test_multiple_records_broken_across_chunks() raises:
    """Three records are correctly parsed with 6-byte chunk delivery."""
    var data = ">r1\nAAAA\n>r2\nCCCC\n>r3\nGGGG\n"
    var reader = ChunkedMemoryReader(_bytes(data), chunk_size=6)
    var parser = FastaParser[ChunkedMemoryReader](reader^)
    var ids = List[String]()
    var seqs = List[String]()
    for rec in parser:
        ids.append(String(rec.id()))
        seqs.append(String(rec.sequence()))
    assert_equal(len(ids), 3, "Should have read exactly 3 records")
    assert_equal(ids[0], "r1")
    assert_equal(seqs[0], "AAAA")
    assert_equal(ids[1], "r2")
    assert_equal(seqs[1], "CCCC")
    assert_equal(ids[2], "r3")
    assert_equal(seqs[2], "GGGG")


fn test_chunk_boundary_on_newline() raises:
    """Chunk boundary lands exactly on the newline separating header from sequence.
    """
    # ">ab\n" = 4 bytes exactly; with chunk_size=4 first chunk ends on '\n'.
    var data = ">ab\nACGT\n"
    var reader = ChunkedMemoryReader(_bytes(data), chunk_size=4)
    var parser = FastaParser[ChunkedMemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(String(rec.id()), "ab")
    assert_equal(String(rec.sequence()), "ACGT")
    _ = rec


fn test_chunk_boundary_splits_sequence_line() raises:
    """Chunk boundary falls in the middle of a sequence line."""
    # ">id\n" = 4 bytes, "ACGT" = 4 bytes, "\n" = 1 byte
    # chunk_size=3: ">id", "\nAC", "GT\n" – boundary inside both header and sequence.
    var data = ">id\nACGT\n"
    var reader = ChunkedMemoryReader(_bytes(data), chunk_size=3)
    var parser = FastaParser[ChunkedMemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(String(rec.id()), "id")
    assert_equal(String(rec.sequence()), "ACGT")
    _ = rec


fn test_record_larger_than_many_chunks() raises:
    """A single record whose total byte size exceeds many chunk deliveries."""
    # Build a record with a 200-base single-line sequence.
    var seq = String("")
    for i in range(50):
        seq += "ACGT"
    var data = ">longseq\n" + seq + "\n"
    # chunk_size=9: data is ~210 bytes, requires ~24 chunk fills.
    var reader = ChunkedMemoryReader(_bytes(data), chunk_size=9)
    var parser = FastaParser[ChunkedMemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(
        String(rec.id()),
        "longseq",
    )
    assert_equal(
        String(rec.sequence()),
        seq,
        "200-base sequence must survive many chunk-boundary crossings",
    )
    _ = rec


# ──────────────────────────────────────────────────────────────────────────────
# Format enforcement – valid inputs
# ──────────────────────────────────────────────────────────────────────────────


fn test_format_valid_leading_blank_lines() raises:
    """Blank lines before the first record header are silently skipped."""
    var data = "\n\n\n>id1\nACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(String(rec.id()), "id1")
    assert_equal(String(rec.sequence()), "ACGT")
    _ = rec


fn test_format_valid_blank_lines_between_records() raises:
    """Blank lines separating records do not corrupt subsequent records."""
    var data = ">id1\nACGT\n\n\n>id2\nTTAA\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec1 = parser.next_record()
    var rec2 = parser.next_record()
    assert_equal(String(rec1.id()), "id1")
    assert_equal(String(rec1.sequence()), "ACGT")
    assert_equal(String(rec2.id()), "id2")
    assert_equal(String(rec2.sequence()), "TTAA")
    _ = rec1
    _ = rec2


fn test_format_valid_crlf_line_endings() raises:
    """Windows-style CRLF line endings are accepted and stripped from ID/sequence.
    """
    var data = ">id1\r\nACGT\r\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(String(rec.id()), "id1")
    assert_equal(String(rec.sequence()), "ACGT")
    _ = rec


fn test_format_valid_crlf_multiple_records() raises:
    """CRLF line endings work correctly across multiple records."""
    var data = ">id1\r\nACGT\r\n>id2\r\nTTAA\r\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec1 = parser.next_record()
    var rec2 = parser.next_record()
    assert_equal(String(rec1.sequence()), "ACGT")
    assert_equal(String(rec2.sequence()), "TTAA")
    _ = rec1
    _ = rec2


fn test_format_valid_id_leading_spaces_trimmed() raises:
    """Leading spaces after '>' are stripped from the record ID."""
    var data = ">  spaced_id\nACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(
        String(rec.id()),
        "spaced_id",
        "Leading spaces should be stripped from ID",
    )
    _ = rec


fn test_format_valid_id_trailing_spaces_trimmed() raises:
    """Trailing spaces in the ID line are stripped."""
    var data = ">seq_id   \nACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(
        String(rec.id()),
        "seq_id",
        "Trailing spaces should be stripped from ID",
    )
    _ = rec


fn test_format_valid_id_tabs_trimmed() raises:
    """Tab characters surrounding the ID are stripped."""
    var data = ">\ttab_id\t\nACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(
        String(rec.id()),
        "tab_id",
        "Tab characters should be stripped from ID",
    )
    _ = rec


fn test_format_valid_empty_id() raises:
    """A header consisting of only '>' produces an empty ID."""
    var data = ">\nACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(String(rec.id()), "")
    assert_equal(String(rec.sequence()), "ACGT")
    _ = rec


fn test_format_valid_single_char_sequence() raises:
    """A sequence consisting of a single nucleotide is valid."""
    var data = ">id1\nA\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(String(rec.sequence()), "A")
    assert_equal(len(rec), 1)
    _ = rec


fn test_format_valid_lowercase_sequence() raises:
    """The parser accepts lowercase nucleotides (no content validation)."""
    var data = ">id1\nacgt\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(String(rec.sequence()), "acgt")
    _ = rec


fn test_format_valid_mixed_case_sequence() raises:
    """Mixed-case sequences are stored exactly as they appear."""
    var data = ">id1\nAcGtAcGt\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(
        String(rec.sequence()), "AcGtAcGt"
    )
    _ = rec


fn test_format_valid_many_single_base_lines() raises:
    """A sequence split into many single-base lines is normalised correctly."""
    var data = ">id1\nA\nC\nG\nT\nA\nC\nG\nT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(
        String(rec.sequence()),
        "ACGTACGT",
        "8 single-base lines should be normalised to one 8-base sequence",
    )
    _ = rec


fn test_format_valid_no_trailing_newline_multiline() raises:
    """Multi-line sequence whose last line has no trailing newline is accepted.
    """
    var data = ">id1\nACG\nTTA"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(
        String(rec.sequence()),
        "ACGTTA",
    )
    _ = rec


# ──────────────────────────────────────────────────────────────────────────────
# Format enforcement – invalid inputs
# ──────────────────────────────────────────────────────────────────────────────


fn test_format_invalid_first_line_not_header() raises:
    """A first non-blank line not starting with '>' raises a parse error."""
    var data = "ACGT\n>id1\nACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var raised = False
    var err_msg = String("")
    try:
        _ = parser.next_record()
    except e:
        raised = True
        err_msg = String(e)
    assert_true(raised, "Expected a parse error for a non-header first line")
    assert_true(
        err_msg.find("does not start with") >= 0,
        "Error message should indicate bad header marker, got: " + err_msg,
    )


fn test_format_invalid_empty_sequence_at_eof() raises:
    """A header at EOF with no following sequence raises an empty-sequence error.
    """
    var data = ">id1\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var raised = False
    var err_msg = String("")
    try:
        _ = parser.next_record()
    except e:
        raised = True
        err_msg = String(e)
    assert_true(raised, "Expected empty-sequence error for header-only input")
    assert_true(
        err_msg.find("empty sequence") >= 0,
        "Error should mention 'empty sequence', got: " + err_msg,
    )


fn test_format_invalid_empty_sequence_before_next_header() raises:
    """A header immediately followed by another header raises empty-sequence error.
    """
    var data = ">id1\n>id2\nACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var raised = False
    var err_msg = String("")
    try:
        _ = parser.next_record()
    except e:
        raised = True
        err_msg = String(e)
    assert_true(
        raised,
        "Expected empty-sequence error when a header has no sequence",
    )
    assert_true(
        err_msg.find("empty sequence") >= 0,
        "Error should mention 'empty sequence', got: " + err_msg,
    )


fn test_format_invalid_empty_file() raises:
    """An empty file raises EOFError on the first next_record() call."""
    var data = ""
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var raised = False
    try:
        _ = parser.next_record()
    except e:
        raised = True
        assert_true(
            String(e).startswith(EOF),
            "Expected EOFError for empty file, got: " + String(e),
        )
    assert_true(raised, "Expected EOFError for empty file")


fn test_format_invalid_whitespace_only_file() raises:
    """A file containing only whitespace/blank lines raises EOFError."""
    var data = "\n\n   \n\t\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var raised = False
    try:
        _ = parser.next_record()
    except e:
        raised = True
        assert_true(
            String(e).startswith(EOF),
            "Expected EOFError for whitespace-only file, got: " + String(e),
        )
    assert_true(raised, "Expected EOFError for whitespace-only file")


fn test_format_invalid_sequence_only_no_header() raises:
    """Data with no header marker at all raises a parse error."""
    var data = "ACGTACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var raised = False
    var err_msg = String("")
    try:
        _ = parser.next_record()
    except e:
        raised = True
        err_msg = String(e)
    assert_true(raised, "Expected a parse error for input with no '>' header")
    assert_true(
        err_msg.find("does not start with") >= 0 or err_msg.startswith(EOF),
        "Error should indicate missing header marker, got: " + err_msg,
    )


fn test_format_invalid_second_record_empty_sequence() raises:
    """The second record in a file having an empty sequence raises an error."""
    var data = ">id1\nACGT\n>id2\n>id3\nGGGG\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    _ = parser.next_record()  # id1 is valid
    var raised = False
    var err_msg = String("")
    try:
        _ = parser.next_record()  # id2 has no sequence
    except e:
        raised = True
        err_msg = String(e)
    assert_true(raised, "Expected empty-sequence error for second record")
    assert_true(
        err_msg.find("empty sequence") >= 0,
        "Error should mention 'empty sequence', got: " + err_msg,
    )


# ──────────────────────────────────────────────────────────────────────────────
# FastaRecord public API
# ──────────────────────────────────────────────────────────────────────────────


fn test_record_byte_len() raises:
    """`byte_len()` equals 1 + len(id) + 1 + len(seq) + 1 (the FASTA on-disk size).
    """
    var data = ">abc\nACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    # ">abc\nACGT\n" → 1 + 3 + 1 + 4 + 1 = 10
    assert_equal(
        rec.byte_len(), 10, "byte_len should be 10 for '>abc\\nACGT\\n'"
    )
    _ = rec


fn test_record_sequence_len() raises:
    """`len(rec)` returns the number of bases in the normalised sequence."""
    var data = ">id1\nACGT\nACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(len(rec), 8, "len(rec) should be sequence length = 8")
    _ = rec


fn test_record_write_format() raises:
    """`String(rec)` produces standard '>id\\nsequence\\n' FASTA text."""
    var data = ">id1\nACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(
        String(rec),
        ">id1\nACGT\n",
        "String(rec) should round-trip to standard FASTA format",
    )
    _ = rec


fn test_record_equality_same_sequence() raises:
    """Two records with identical sequences compare equal regardless of ID."""
    var r1 = FastaRecord("id1", "ACGT")
    var r2 = FastaRecord("id2", "ACGT")
    assert_true(
        r1 == r2,
        (
            "Records with the same sequence should be equal (equality is"
            " seq-based)"
        ),
    )


fn test_record_inequality_different_sequence() raises:
    """Two records with different sequences compare unequal."""
    var r1 = FastaRecord("id1", "ACGT")
    var r2 = FastaRecord("id1", "TTAA")
    assert_true(
        r1 != r2, "Records with different sequences should not be equal"
    )


fn test_record_byte_len_multiline_normalised() raises:
    """`byte_len()` reflects the normalised (single-line) sequence length."""
    var data = ">id\nAC\nGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    # After normalisation: ">id\nACGT\n" → 1 + 2 + 1 + 4 + 1 = 9
    assert_equal(rec.byte_len(), 9)
    _ = rec


fn test_record_accessors_consistent() raises:
    """`id()`, `sequence()`, `__len__()`, and `byte_len()` are internally consistent.
    """
    var data = ">myid\nGATTACA\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    var id_str = String(rec.id())
    var seq_str = String(rec.sequence())
    assert_equal(id_str, "myid")
    assert_equal(seq_str, "GATTACA")
    assert_equal(len(rec), 7)
    # byte_len = 1 + len(id) + 1 + len(sequence) + 1 = 1 + 4 + 1 + 7 + 1 = 14
    assert_equal(rec.byte_len(), 14)
    _ = rec


fn main() raises:
    var suite = TestSuite.discover_tests[__functions_in_module()]().run()
    # test_single_record_single_line()
