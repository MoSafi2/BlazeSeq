"""Testing for the parser on test suite of valid and invalid FASTQ files used for testing by BioJava, BioPerl, and Biopython projects.
File were downloaded from BioJava.
'https://github.com/biojava/biojava/tree/master/biojava-genome%2Fsrc%2Ftest%2Fresources%2Forg%2Fbiojava%2Fnbio%2Fgenome%2Fio%2Ffastq'
Truncated files were padded with 1, 2, or 3, extra line terminators to prevent `EOF` errors and to allow for record validation via the parser's Validator.
Multi-line FASTQ tests are removed as Blazeseq does not support multi-line FASTQ.
"""

from blazeseq.fastq.parser import FastqParser, ParserConfig
from blazeseq.io.readers import FileReader, MemoryReader
from blazeseq.utils import generate_synthetic_fastq_buffer
from blazeseq.fastq.record import FastqRecord
from blazeseq.fastq.record_batch import FastqBatch
from blazeseq.CONSTS import EOF
from testing import assert_equal, assert_raises, assert_true, TestSuite

comptime test_dir = "tests/test_data/fastq_parser/"


fn create_non_ascii_fastq_data() -> List[Byte]:
    var data = List[Byte]()
    data.append(ord("@"))
    data.append(ord("r"))
    data.append(ord("1"))
    data.append(ord("\n"))
    data.append(ord("A"))
    data.append(Byte(200))
    data.append(ord("C"))
    data.append(ord("\n"))
    data.append(ord("+"))
    data.append(ord("\n"))
    data.append(ord("!"))
    data.append(ord("!"))
    data.append(ord("!"))
    data.append(ord("\n"))
    return data^


fn test_record_parser_for_loop() raises:
    """Basic ``for record in parser.records()`` iteration."""
    var content = "@r1\nACGT\n+\n!!!!\n@r2\nTGCA\n+\n####\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader](reader^, "generic")

    var records = List[FastqRecord]()
    for record in parser.records():
        records.append(record^)

    assert_equal(len(records), 2, "Should iterate over 2 records")
    assert_equal(
        records[0]._id.to_string(),
        "r1",
        "First record header should match",
    )
    assert_equal(
        records[0]._sequence.to_string(),
        "ACGT",
        "First record sequence should match",
    )
    assert_equal(
        records[1]._id.to_string(),
        "r2",
        "Second record header should match",
    )


fn test_record_parser_for_loop_stop_iteration() raises:
    """Iterator raises StopIteration at EOF; second loop yields no records."""
    var content = "@r1\nACGT\n+\n!!!!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader](reader^, "generic")

    var count = 0
    for record in parser.records():
        count += 1
    assert_equal(count, 1, "Should iterate over 1 record")

    var count_after = 0
    for record in parser.records():
        count_after += 1
    assert_equal(count_after, 0, "Should not iterate after EOF")


fn test_record_parser_ascii_validation_enabled() raises:
    """Non-ASCII bytes should fail when ParserConfig(check_ascii=True)."""
    var content = create_non_ascii_fastq_data()
    var reader = MemoryReader(content^)

    with assert_raises(contains="Non ASCII letters found"):
        var parser = FastqParser[
            MemoryReader,
            ParserConfig(check_ascii=True, check_quality=False),
        ](reader^)
        _ = parser.next_record()


fn test_record_parser_ascii_validation_disabled() raises:
    """Non-ASCII bytes should parse when ParserConfig(check_ascii=False)."""
    var content = create_non_ascii_fastq_data()
    var reader = MemoryReader(content^)

    var parser = FastqParser[
        MemoryReader,
        ParserConfig(check_ascii=False, check_quality=False),
    ](reader^)
    var record = parser.next_record()
    assert_equal(
        record._id.to_string(),
        "r1",
        "Parser should yield record when ASCII validation is disabled",
    )


# ---------------------------------------------------------------------------
# FastqParser batches() / next_batch() tests (non-GPU: iteration, batch size, content, empty input)
# ---------------------------------------------------------------------------


fn test_batched_parser_for_loop() raises:
    """FastqParser.batches() yields FastqBatch with correct record count."""
    var content = "@r1\nACGT\n+\n!!!!\n@r2\nTGCA\n+\n####\n@r3\nNNNN\n+\n!!!!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader](
        reader^, schema="generic", batch_size=2
    )

    var batches = List[FastqBatch]()
    for batch in parser.batches():
        batches.append(batch^)

    assert_equal(
        len(batches), 2, "Should yield 2 batches (batch_size=2, 3 records)"
    )
    assert_equal(len(batches[0]), 2, "First batch should have 2 records")
    assert_equal(len(batches[1]), 1, "Second batch should have 1 record")


fn test_batched_parser_batch_size_respected() raises:
    """Custom batch_size limits records per batch."""
    var content = (
        "@a\nA\n+\n!\n@b\nB\n+\n!\n@c\nC\n+\n!\n@d\nD\n+\n!\n@e\nE\n+\n!\n"
    )
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader](
        reader^, schema="generic", batch_size=2
    )

    var batch1 = parser.next_batch(2)
    var batch2 = parser.next_batch(2)
    var batch3 = parser.next_batch(2)

    assert_equal(len(batch1), 2, "First batch size 2")
    assert_equal(len(batch2), 2, "Second batch size 2")
    assert_equal(len(batch3), 1, "Third batch size 1 (remaining)")
    assert_true(
        not parser.has_more(), "No more input after consuming 5 records"
    )


fn test_batched_parser_single_batch_content() raises:
    """Batch content matches parsed records (get_record / header and sequence).
    """
    var content = "@seq1\nACGT\n+\n!!!!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader](
        reader^, schema="generic", batch_size=4
    )

    var batch = parser.next_batch(4)
    assert_equal(len(batch), 1, "One record in batch")
    var rec = batch.get_record(0)
    assert_equal(rec._id.to_string(), "seq1", "Id should match")
    assert_equal(rec._sequence.to_string(), "ACGT", "Sequence should match")
    assert_equal(rec._quality.to_string(), "!!!!", "Quality should match")


fn test_batched_parser_empty_input() raises:
    """Empty FASTQ input yields no batches (iterator produces nothing)."""
    var content = ""
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader](
        reader^, schema="generic", batch_size=4
    )

    var count = 0
    for batch in parser.batches():
        count += 1
    assert_equal(count, 0, "No batches from empty input")


fn test_batched_parser_has_more() raises:
    """`has_more()` is True before consumption and False after all records consumed.
    """
    var content = "@r1\nA\n+\n!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader](
        reader^, schema="generic", batch_size=4
    )

    assert_true(parser.has_more(), "Should have more before next_batch")
    _ = parser.next_batch(4)
    assert_true(
        not parser.has_more(),
        "Should have no more after consuming single record",
    )


fn test_batched_parser_schema() raises:
    """FastqParser accepts quality schema string (e.g. sanger) and parses correctly.
    """
    var content = "@id\nACGT\n+\n!!!!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader](
        reader^, schema="sanger", batch_size=4
    )

    var batch = parser.next_batch(4)
    assert_equal(len(batch), 1, "One record")
    var rec = batch.get_record(0)
    assert_equal(
        rec._sequence.to_string(), "ACGT", "Sequence unchanged by schema"
    )


fn test_generate_synthetic_fastq_buffer() raises:
    """Synthetic FASTQ buffer from utils produces valid FASTQ; MemoryReader + FastqParser.batches() yield expected counts and lengths.
    """
    var num_reads = 20
    var min_len = 5
    var max_len = 12
    var min_phred = 2
    var max_phred = 25
    var buf = generate_synthetic_fastq_buffer(
        num_reads, min_len, max_len, min_phred, max_phred, "generic"
    )
    assert_true(len(buf) > 0, "Buffer non-empty")

    var reader = MemoryReader(buf^)
    var parser = FastqParser[MemoryReader](
        reader^, schema="generic", batch_size=8
    )
    var total = 0
    for batch in parser.batches():
        total += len(batch)
        for i in range(len(batch)):
            var rec = batch.get_record(i)
            var seq_len = len(rec._sequence)
            assert_true(
                seq_len >= min_len and seq_len <= max_len,
                "Record sequence length in [min_length, max_length]",
            )
    assert_equal(total, num_reads, "Total records equals num_reads")


comptime ref_parser_large_config = ParserConfig(buffer_capacity=256)


fn test_ref_parser_fast_path_all_lines_in_buffer() raises:
    """FastqParser.next_ref() parses records when all four lines fit in buffer (fast path).
    """
    var content = "@r1\nACGT\n+\n!!!!\n@r2\nTGCA\n+\n!!!!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader, ref_parser_large_config](reader^)

    var r1 = parser.next_ref()
    assert_equal(String(r1.id()), "r1", "First record id")
    assert_equal(String(r1.sequence()), "ACGT", "First record seq")
    assert_equal(String(r1.quality()), "!!!!", "First record quality")
    var r2 = parser.next_ref()
    assert_equal(String(r2.id()), "r2", "Second record id")
    assert_equal(String(r2.sequence()), "TGCA", "Second record seq")
    with assert_raises(contains="EOF"):
        _ = parser.next_ref()

    print("✓ test_ref_parser_fast_path_all_lines_in_buffer passed")


# Buffer large enough that one record fits after one refill (fallback path).
comptime ref_parser_small_config = ParserConfig(buffer_capacity=32)

# Same small buffer for record path (next_record/records) so lines span chunks.
comptime record_parser_small_config = ParserConfig(buffer_capacity=32)

comptime ref_parser_growth_config = ParserConfig(
    buffer_capacity=16,
    buffer_growth_enabled=True,
    buffer_max_capacity=256,
)


fn test_ref_parser_fallback_record_span_chunks() raises:
    """FastqParser.next_ref() parses correctly when record spans two chunks (fallback path).
    """
    var content = "@r1\nACGT\n+\n!!!!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader, ref_parser_small_config](reader^)

    var r = parser.next_ref()
    assert_equal(String(r.id()), "r1", "Id should match")
    assert_equal(String(r.sequence()), "ACGT", "Sequence should match")
    assert_equal(String(r.quality()), "!!!!", "Quality should match")
    with assert_raises(contains="EOF"):
        _ = parser.next_ref()

    print("✓ test_ref_parser_fallback_record_span_chunks passed")


# ---------------------------------------------------------------------------
# Record path (next_record / records) parsing across chunks
# ---------------------------------------------------------------------------


fn test_record_parser_fallback_record_span_chunks() raises:
    """FastqParser.next_record() parses correctly when record spans two chunks.
    """
    var content = "@r1\nACGT\n+\n!!!!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader, record_parser_small_config](reader^)

    var r = parser.next_record()
    assert_equal(r._id.to_string(), "r1", "Id should match")
    assert_equal(r._sequence.to_string(), "ACGT", "Sequence should match")
    assert_equal(r._quality.to_string(), "!!!!", "Quality should match")
    with assert_raises(contains="EOF"):
        _ = parser.next_record()


fn test_record_parser_multiple_records_span_chunks() raises:
    """FastqParser.next_record(): multiple records with small buffer so lines span chunks.
    """
    var content = "@r1\nA\n+\n!\n@r2\nB\n+\n!\n@r3\nC\n+\n!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader, record_parser_small_config](reader^)

    var r1 = parser.next_record()
    assert_equal(r1._id.to_string(), "r1", "First record id")
    assert_equal(r1._sequence.to_string(), "A", "First record seq")
    assert_equal(r1._quality.to_string(), "!", "First record quality")
    var r2 = parser.next_record()
    assert_equal(r2._id.to_string(), "r2", "Second record id")
    assert_equal(r2._sequence.to_string(), "B", "Second record seq")
    var r3 = parser.next_record()
    assert_equal(r3._id.to_string(), "r3", "Third record id")
    assert_equal(r3._sequence.to_string(), "C", "Third record seq")
    assert_equal(r3._quality.to_string(), "!", "Third record quality")
    with assert_raises(contains="EOF"):
        _ = parser.next_record()


fn test_record_parser_records_iterator_span_chunks() raises:
    """FastqParser.records() yields correct records when parsing across chunks.
    """
    var content = "@a\nAC\n+\n!!\n@b\nTG\n+\n##\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader, record_parser_small_config](reader^)

    var records = List[FastqRecord]()
    for record in parser.records():
        records.append(record^)

    assert_equal(len(records), 2, "Should yield two records")
    assert_equal(records[0]._id.to_string(), "a", "First record id")
    assert_equal(records[0]._sequence.to_string(), "AC", "First record seq")
    assert_equal(records[0]._quality.to_string(), "!!", "First record quality")
    assert_equal(records[1]._id.to_string(), "b", "Second record id")
    assert_equal(records[1]._sequence.to_string(), "TG", "Second record seq")
    assert_equal(records[1]._quality.to_string(), "##", "Second record quality")


fn test_ref_parser_multiple_records_next_loop() raises:
    """FastqParser: two records via next_ref(), then EOF (mirror records() for-loop).
    """
    var content = "@r1\nACGT\n+\n!!!!\n@r2\nTGCA\n+\n####\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader, ref_parser_large_config](reader^)

    var r1 = parser.next_ref()
    assert_equal(String(r1.id()), "r1", "First record id")
    assert_equal(String(r1.sequence()), "ACGT", "First record seq")
    assert_equal(String(r1.quality()), "!!!!", "First record quality")
    var r2 = parser.next_ref()
    assert_equal(String(r2.id()), "r2", "Second record id")
    assert_equal(String(r2.sequence()), "TGCA", "Second record seq")
    assert_equal(String(r2.quality()), "####", "Second record quality")
    with assert_raises(contains="EOF"):
        _ = parser.next_ref()


fn test_ref_parser_for_loop_iteration() raises:
    """FastqParser: for ref in parser.ref_records() yields records; count and content match.
    """
    var content = "@r1\nACGT\n+\n!!!!\n@r2\nTGCA\n+\n####\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader, ref_parser_large_config](reader^)

    var count: Int = 0
    var first_id: String = ""
    var last_seq: String = ""
    for ref_record in parser.ref_records():
        if count == 0:
            first_id = String(ref_record.id())
        last_seq = String(ref_record.sequence())
        count += 1

    assert_equal(count, 2, "Should yield two records")
    assert_equal(first_id, "r1", "First record id")
    assert_equal(last_seq, "TGCA", "Last record sequence")


fn test_ref_parser_eof_after_one_record() raises:
    """FastqParser: single record, second next_ref() raises EOF."""
    var content = "@r1\nACGT\n+\n!!!!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader, ref_parser_large_config](reader^)

    var r = parser.next_ref()
    assert_equal(String(r.id()), "r1", "Id should match")
    assert_equal(String(r.sequence()), "ACGT", "Sequence should match")
    assert_equal(String(r.quality()), "!!!!", "Quality should match")
    with assert_raises(contains="EOF"):
        _ = parser.next_ref()


fn test_ref_parser_empty_input() raises:
    """FastqParser: empty input, first next_ref() raises EOF."""
    var content = ""
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader, ref_parser_large_config](reader^)

    with assert_raises(contains="EOF"):
        _ = parser.next_ref()


fn test_ref_parser_invalid_header() raises:
    """FastqParser: first line not starting with @ raises."""
    var content = "r1\nACGT\n+\n!!!!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader, ref_parser_large_config](reader^)

    with assert_raises(contains="Sequence id line does not start with '@'"):
        _ = parser.next_ref()


fn test_ref_parser_mismatched_seq_qual_length() raises:
    """FastqParser: seq and qual line length mismatch raises in hot loop."""
    var content = "@r1\nACGT\n+\n!!!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader, ref_parser_large_config](reader^)

    with assert_raises(
        contains="Quality and sequence line do not match in length"
    ):
        _ = parser.next_ref()


fn test_ref_parser_multiple_records_span_chunks() raises:
    """FastqParser: three records with small buffer so at least one spans chunks.
    """
    var content = "@r1\nA\n+\n!\n@r2\nB\n+\n!\n@r3\nC\n+\n!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader, ref_parser_small_config](reader^)

    var r1 = parser.next_ref()
    assert_equal(String(r1.id()), "r1", "First record id")
    assert_equal(String(r1.sequence()), "A", "First record seq")
    assert_equal(String(r1.quality()), "!", "First record quality")
    var r2 = parser.next_ref()
    assert_equal(String(r2.id()), "r2", "Second record id")
    assert_equal(String(r2.sequence()), "B", "Second record seq")
    var r3 = parser.next_ref()
    assert_equal(String(r3.id()), "r3", "Third record header")
    assert_equal(String(r3.sequence()), "C", "Third record seq")
    assert_equal(String(r3.quality()), "!", "Third record quality")
    with assert_raises(contains="EOF"):
        _ = parser.next_ref()


fn _ref_parser_long_record_content() -> String:
    """One FASTQ record with sequence and quality length 20 (longer than small buffer).
    """
    var seq = String("")
    for i in range(20):
        seq += "A"
    var qual = String("")
    for i in range(20):
        qual += "!"
    return "@id\n" + seq + "\n+\n" + qual + "\n"


# Disabled for now
fn test_ref_parser_long_line_with_growth() raises:
    """FastqParser: one record with line longer than buffer, buffer_growth_enabled=True.
    """
    var content = _ref_parser_long_record_content()
    var reader = MemoryReader(content.as_bytes())
    var parser = FastqParser[MemoryReader, ref_parser_growth_config](reader^)

    var r = parser.next_ref()
    assert_equal(String(r.id()), "id", "Id should match")
    assert_equal(len(r.sequence()), 20, "Sequence length 20")
    assert_equal(len(r.quality()), 20, "Quality length 20")
    assert_equal(
        String(r.sequence()), "AAAAAAAAAAAAAAAAAAAA", "Sequence content"
    )
    assert_equal(String(r.quality()), "!!!!!!!!!!!!!!!!!!!!", "Quality content")
    with assert_raises(contains="EOF"):
        _ = parser.next_ref()


fn test_ref_parser_long_line_without_growth() raises:
    """FastqParser: line longer than buffer and buffer_growth_enabled=False raises.
    """
    var content = _ref_parser_long_record_content()
    var reader = MemoryReader(content.as_bytes())
    comptime no_growth_config = ParserConfig(
        buffer_capacity=16,
        buffer_growth_enabled=False,
    )
    var parser = FastqParser[MemoryReader, no_growth_config](reader^)

    with assert_raises(contains="record exceeds buffer capacity"):
        _ = parser.next_ref()


fn test_ref_parser_ascii_validation_enabled() raises:
    """FastqParser: non-ASCII bytes fail when ParserConfig(check_ascii=True)."""
    var content = create_non_ascii_fastq_data()
    var reader = MemoryReader(content^)

    with assert_raises(contains="Non ASCII"):
        var parser = FastqParser[
            MemoryReader,
            ParserConfig(check_ascii=True, check_quality=False),
        ](reader^)
        _ = parser.next_ref()


# Failing Test, TODO: Fix
# fn test_ref_parser_ascii_validation_disabled() raises:
#     """FastqParser: non-ASCII bytes parse when ParserConfig(check_ascii=False).
#     """
#     var content = create_non_ascii_fastq_data()
#     var reader = MemoryReader(content^)

#     var parser = FastqParser[
#         MemoryReader,
#         ParserConfig(check_ascii=False, check_quality=False),
#     ](reader^)
#     var record = parser.next_ref()
#     print(record)
#     assert_equal(
#         String(record.get_header()),
#         "@r1",
#         "Parser should yield record when ASCII validation is disabled",
#     )


comptime ref_parser_file_config = ParserConfig(
    quality_schema=Optional[String]("generic"),
)


fn test_ref_parser_valid_file_parity() raises:
    """FastqParser: parse valid test_data file, count records and spot-check first.
    """
    var parser = FastqParser[FileReader, ref_parser_file_config](
        FileReader(test_dir + "example.fastq")
    )
    var first = parser.next_ref()
    assert_true(len(String(first.id())) > 0, "First record has id")
    assert_true(len(first) > 0, "First record has sequence")
    var count = 1
    while True:
        try:
            _ = parser.next_ref()
            count += 1
        except Error:
            var err_msg = String(Error)
            if err_msg.find("EOF") >= 0:
                break
            raise
    assert_true(count >= 1, "At least one record from valid file")


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
