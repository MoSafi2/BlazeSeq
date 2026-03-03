from blazeseq import FastaParser, FastaRecord, FileReader, MemoryReader
from blazeseq.CONSTS import EOF
from pathlib import Path
from testing import assert_equal, assert_true, assert_raises, TestSuite


fn _bytes(s: String) -> List[Byte]:
    var out = List[Byte]()
    for b in s.as_bytes():
        out.append(b)
    return out^


fn test_single_record_single_line() raises:
    """Single-record, single-line sequence."""
    var data = ">id1\nACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(
        String(StringSlice(unsafe_from_utf8=rec.id())),
        "id1",
        "ID should match header without '>'",
    )
    assert_equal(
        String(StringSlice(unsafe_from_utf8=rec.sequence())),
        "ACGT",
        "Sequence should match",
    )
    # assert_raises(contains="EOFError", parser.next_record() )


fn test_single_record_multiline() raises:
    """Single-record, multi-line sequence is normalized to single line."""
    var data = ">id1\nACG\nTTA\nGG\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(
        String(StringSlice(unsafe_from_utf8=rec.sequence())),
        "ACGTTAGG",
        "Multi-line sequence should be concatenated without newlines",
    )
    # assert_raises(EOFError, fn() raises { _ = parser.next_record() })


fn test_multiple_records_back_to_back() raises:
    """Multiple records where next header immediately follows sequence line."""
    var data = ">id1\nACGT\n>id2\nTTAA\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)

    var rec1 = parser.next_record()
    assert_equal(
        String(StringSlice(unsafe_from_utf8=rec1.id())),
        "id1",
    )
    assert_equal(
        String(StringSlice(unsafe_from_utf8=rec1.sequence())),
        "ACGT",
    )

    var rec2 = parser.next_record()
    assert_equal(
        String(StringSlice(unsafe_from_utf8=rec2.id())),
        "id2",
    )
    assert_equal(
        String(StringSlice(unsafe_from_utf8=rec2.sequence())),
        "TTAA",
    )

    # assert_raises(EOFError, fn() raises { _ = parser.next_record() })


fn test_record_end_at_eof_without_newline() raises:
    """Record ending at EOF without terminal newline."""
    var data = ">id1\nACGT"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(
        String(StringSlice(unsafe_from_utf8=rec.sequence())),
        "ACGT",
    )
    # assert_raises(contains="EOFError", parser.next_record() )


fn test_invalid_first_line_not_header() raises:
    """Invalid input: first non-empty line not starting with '>'."""
    var data = "ACGT\n>id1\nACGT\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    # assert_raises(contains="Error", fn() raises { _ = parser.next_record() })


fn test_records_iterator() raises:
    """Iterator over FastaParser.records()."""
    var data = ">id1\nAC\nGT\n>id2\nTT\nAA\n"
    var reader = MemoryReader(_bytes(data))
    var parser = FastaParser[MemoryReader](reader^)
    var ids = List[String]()
    var seqs = List[String]()
    for rec in parser:
        ids.append(String(StringSlice(unsafe_from_utf8=rec.id())))
        seqs.append(String(StringSlice(unsafe_from_utf8=rec.sequence())))
    assert_equal(len(ids), 2)
    assert_equal(ids[0], "id1")
    assert_equal(ids[1], "id2")
    assert_equal(seqs[0], "ACGT")
    assert_equal(seqs[1], "TTAA")


fn main() raises:
    var suite = TestSuite.discover_tests[__functions_in_module()]().run()
    