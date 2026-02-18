"""Testing for the parser on test suite of valid and invalid FASTQ files used for testing by BioJava, BioPerl, and Biopython projects.
File were downloaded from BioJava.
'https://github.com/biojava/biojava/tree/master/biojava-genome%2Fsrc%2Ftest%2Fresources%2Forg%2Fbiojava%2Fnbio%2Fgenome%2Fio%2Ffastq'
Truncated files were padded with 1, 2, or 3, extra line terminators to prevent `EOF` errors and to allow for record validation via the parser's Validator.
Multi-line FASTQ tests are removed as Blazeseq does not support multi-line FASTQ.
"""

from blazeseq.parser import RecordParser, BatchedParser, RefParser
from blazeseq.readers import FileReader, MemoryReader
from blazeseq.parser import ParserConfig
from blazeseq.utils import generate_synthetic_fastq_buffer
from blazeseq.record import FastqRecord
from blazeseq.device_record import FastqBatch
from blazeseq.CONSTS import EOF
from testing import assert_equal, assert_raises, assert_true, TestSuite

comptime test_dir = "tests/test_data/fastq_parser/"

comptime corrput_qu_score = "Corrupt quality score according to provided schema"
comptime cor_len = "Quality and Sequencing string does not match in lengths"
comptime cor_seq_hed = "Sequence header does not start with '@'"
comptime cor_qu_hed = "Quality header does not start with '+'"
comptime non_mat_hed = "Quality Header is not the same as the Sequencing Header"
comptime len_mismatch = "Quality Header is not the same length as the Sequencing header"


fn invalid_file_test_fun(file: String, msg: String = "") raises:
    comptime config_ = ParserConfig(check_ascii=True, check_quality=True)
    with assert_raises(contains=msg):
        parser = RecordParser[FileReader, config_](FileReader(test_dir + file))
        try:
            while True:
                var record = parser.next()
                parser.validator.validate(record)
        except e:
            var err_msg = String(e)
            print(err_msg)
            raise


fn valid_file_test_fun(file: String, schema: String = "generic") raises:
    var parser = RecordParser[FileReader](FileReader(test_dir + file), schema)
    try:
        for record in parser:
            parser.validator.validate(record)
    except Error:
        var err_msg = String(Error)
        if err_msg == EOF:
            pass
        else:
            print(err_msg)
            raise


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


fn test_valid() raises:
    valid_file_test_fun("example.fastq")
    valid_file_test_fun("illumina_example.fastq", "illumina_1.3")
    valid_file_test_fun("illumina_faked.fastq", "illumina_1.3")
    valid_file_test_fun("illumina_full_range_as_illumina.fastq", "illumina_1.3")
    valid_file_test_fun("illumina_full_range_as_sanger.fastq", "sanger")
    valid_file_test_fun("illumina_full_range_as_solexa.fastq", "solexa")
    valid_file_test_fun(
        "illumina_full_range_original_illumina.fastq", "illumina_1.3"
    )
    valid_file_test_fun("longreads_as_illumina.fastq", "illumina_1.3")
    valid_file_test_fun("longreads_as_sanger.fastq", "sanger")
    valid_file_test_fun("longreads_as_solexa.fastq", "solexa")
    valid_file_test_fun("misc_dna_as_illumina.fastq", "illumina_1.3")
    valid_file_test_fun("misc_dna_as_sanger.fastq", "sanger")
    valid_file_test_fun("misc_dna_as_solexa.fastq", "solexa")
    valid_file_test_fun("misc_dna_original_sanger.fastq", "sanger")
    valid_file_test_fun("misc_rna_as_illumina.fastq", "illumina_1.3")
    valid_file_test_fun("misc_rna_as_sanger.fastq", "sanger")
    valid_file_test_fun("misc_rna_as_solexa.fastq", "solexa")
    valid_file_test_fun("misc_rna_original_sanger.fastq", "sanger")
    valid_file_test_fun("sanger_93.fastq", "sanger")
    valid_file_test_fun("sanger_faked.fastq", "sanger")
    valid_file_test_fun("sanger_full_range_as_illumina.fastq", "illumina_1.3")
    valid_file_test_fun("sanger_full_range_as_sanger.fastq", "sanger")
    valid_file_test_fun("sanger_full_range_as_solexa.fastq", "solexa")
    valid_file_test_fun("sanger_full_range_original_sanger.fastq", "sanger")
    valid_file_test_fun("solexa_example.fastq", "solexa")
    valid_file_test_fun("solexa_faked.fastq", "solexa")
    valid_file_test_fun("solexa_full_range_as_illumina.fastq", "illumina_1.3")
    valid_file_test_fun("solexa_full_range_as_sanger.fastq", "sanger")
    valid_file_test_fun("solexa_full_range_as_solexa.fastq", "solexa")
    valid_file_test_fun("solexa_full_range_original_solexa.fastq", "solexa")
    valid_file_test_fun("test1_sanger.fastq", "sanger")
    valid_file_test_fun("test2_solexa.fastq", "solexa")
    valid_file_test_fun("test3_illumina.fastq", "illumina_1.3")
    valid_file_test_fun("wrapping_as_illumina.fastq", "illumina_1.3")
    valid_file_test_fun("wrapping_as_sanger.fastq", "sanger")
    valid_file_test_fun("wrapping_as_solexa.fastq", "solexa")


# TODO: The iterator is not working with other errors than StopIteration
fn test_invalid() raises:
    invalid_file_test_fun("empty.fastq", EOF)
    invalid_file_test_fun("error_diff_ids.fastq", non_mat_hed)
    invalid_file_test_fun("error_long_qual.fastq", cor_len)
    invalid_file_test_fun("error_no_qual.fastq", cor_len)
    invalid_file_test_fun("error_trunc_in_plus.fastq", cor_len)
    invalid_file_test_fun("error_trunc_at_qual.fastq", cor_len)
    invalid_file_test_fun("error_double_qual.fastq", cor_seq_hed)
    invalid_file_test_fun("error_trunc_at_seq.fastq", cor_qu_hed)
    invalid_file_test_fun("error_trunc_in_seq.fastq", cor_qu_hed)
    invalid_file_test_fun("error_trunc_in_title.fastq", cor_qu_hed)
    invalid_file_test_fun("error_double_seq.fastq", cor_qu_hed)
    invalid_file_test_fun("error_trunc_at_plus.fastq", cor_qu_hed)
    invalid_file_test_fun("error_qual_null.fastq", corrput_qu_score)
    invalid_file_test_fun("error_qual_space.fastq", corrput_qu_score)
    invalid_file_test_fun("error_spaces.fastq", corrput_qu_score)
    invalid_file_test_fun("error_qual_vtab.fastq", corrput_qu_score)
    invalid_file_test_fun("error_tabs.fastq", corrput_qu_score)
    invalid_file_test_fun("error_qual_tab.fastq", corrput_qu_score)
    invalid_file_test_fun("error_qual_del.fastq", corrput_qu_score)
    invalid_file_test_fun("error_qual_escape.fastq", corrput_qu_score)
    invalid_file_test_fun("solexa-invalid-description.fastq", cor_seq_hed)
    invalid_file_test_fun(
        "solexa-invalid-repeat-description.fastq", len_mismatch
    )
    invalid_file_test_fun("sanger-invalid-description.fastq", cor_seq_hed)
    invalid_file_test_fun(
        "sanger-invalid-repeat-description.fastq", len_mismatch
    )
    invalid_file_test_fun("illumina-invalid-description.fastq", cor_seq_hed)
    invalid_file_test_fun(
        "illumina-invalid-repeat-description.fastq", len_mismatch
    )
    invalid_file_test_fun("error_qual_unit_sep.fastq", corrput_qu_score)
    invalid_file_test_fun("error_short_qual.fastq", cor_len)
    invalid_file_test_fun("error_trunc_in_qual.fastq", cor_len)


fn test_record_parser_for_loop() raises:
    """Basic ``for record in parser`` iteration."""
    var content = "@r1\nACGT\n+\n!!!!\n@r2\nTGCA\n+\n####\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = RecordParser[MemoryReader](reader^, "generic")

    var records = List[FastqRecord]()
    for record in parser:
        records.append(record^)

    assert_equal(len(records), 2, "Should iterate over 2 records")
    assert_equal(
        records[0].SeqHeader.to_string(),
        "@r1",
        "First record header should match",
    )
    assert_equal(
        records[0].SeqStr.to_string(),
        "ACGT",
        "First record sequence should match",
    )
    assert_equal(
        records[1].SeqHeader.to_string(),
        "@r2",
        "Second record header should match",
    )


fn test_record_parser_for_loop_stop_iteration() raises:
    """Iterator raises StopIteration at EOF; second loop yields no records."""
    var content = "@r1\nACGT\n+\n!!!!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = RecordParser[MemoryReader](reader^, "generic")

    var count = 0
    for record in parser:
        count += 1
    assert_equal(count, 1, "Should iterate over 1 record")

    var count_after = 0
    for record in parser:
        count_after += 1
    assert_equal(count_after, 0, "Should not iterate after EOF")


fn test_record_parser_ascii_validation_enabled() raises:
    """Non-ASCII bytes should fail when ParserConfig(check_ascii=True)."""
    var content = create_non_ascii_fastq_data()
    var reader = MemoryReader(content^)

    with assert_raises(contains="Non ASCII letters found"):
        var parser = RecordParser[
            MemoryReader,
            ParserConfig(check_ascii=True, check_quality=False),
        ](reader^)
        _ = parser.next()


fn test_record_parser_ascii_validation_disabled() raises:
    """Non-ASCII bytes should parse when ParserConfig(check_ascii=False)."""
    var content = create_non_ascii_fastq_data()
    var reader = MemoryReader(content^)

    var parser = RecordParser[
        MemoryReader,
        ParserConfig(check_ascii=False, check_quality=False),
    ](reader^)
    var record = parser.next()
    assert_equal(
        record.SeqHeader.to_string(),
        "@r1",
        "Parser should yield record when ASCII validation is disabled",
    )


# ---------------------------------------------------------------------------
# BatchedParser tests (non-GPU: iteration, batch size, content, empty input)
# ---------------------------------------------------------------------------


fn test_batched_parser_for_loop() raises:
    """BatchedParser supports ``for batch in parser`` and yields FastqBatch with correct record count.
    """
    var content = "@r1\nACGT\n+\n!!!!\n@r2\nTGCA\n+\n####\n@r3\nNNNN\n+\n!!!!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = BatchedParser[MemoryReader](reader^, "generic", 2)

    var batches = List[FastqBatch]()
    for batch in parser:
        batches.append(batch^)

    assert_equal(
        len(batches), 2, "Should yield 2 batches (batch_size=2, 3 records)"
    )
    assert_equal(len(batches[0]), 2, "First batch should have 2 records")
    assert_equal(len(batches[1]), 1, "Second batch should have 1 record")


fn test_batched_parser_batch_size_respected() raises:
    """Custom default_batch_size limits records per batch."""
    var content = (
        "@a\nA\n+\n!\n@b\nB\n+\n!\n@c\nC\n+\n!\n@d\nD\n+\n!\n@e\nE\n+\n!\n"
    )
    var reader = MemoryReader(content.as_bytes())
    var parser = BatchedParser[MemoryReader](reader^, "generic", 2)

    var batch1 = parser.next_batch(2)
    var batch2 = parser.next_batch(2)
    var batch3 = parser.next_batch(2)

    assert_equal(len(batch1), 2, "First batch size 2")
    assert_equal(len(batch2), 2, "Second batch size 2")
    assert_equal(len(batch3), 1, "Third batch size 1 (remaining)")
    assert_true(
        not parser._has_more(), "No more input after consuming 5 records"
    )


fn test_batched_parser_single_batch_content() raises:
    """Batch content matches parsed records (get_record / header and sequence).
    """
    var content = "@seq1\nACGT\n+\n!!!!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = BatchedParser[MemoryReader](reader^, "generic", 4)

    var batch = parser.next_batch(4)
    assert_equal(len(batch), 1, "One record in batch")
    var rec = batch.get_record(0)
    assert_equal(rec.SeqHeader.to_string(), "@seq1", "Header should match")
    assert_equal(rec.SeqStr.to_string(), "ACGT", "Sequence should match")
    assert_equal(rec.QuStr.to_string(), "!!!!", "Quality should match")


fn test_batched_parser_empty_input() raises:
    """Empty FASTQ input yields no batches (iterator produces nothing)."""
    var content = ""
    var reader = MemoryReader(content.as_bytes())
    var parser = BatchedParser[MemoryReader](reader^, "generic", 4)

    var count = 0
    for batch in parser:
        count += 1
    assert_equal(count, 0, "No batches from empty input")


fn test_batched_parser_has_more() raises:
    """_has_more() is True before consumption and False after all records consumed.
    """
    var content = "@r1\nA\n+\n!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = BatchedParser[MemoryReader](reader^, "generic", 4)

    assert_true(parser._has_more(), "Should have more before _next_batch")
    _ = parser.next_batch(4)
    assert_true(
        not parser._has_more(),
        "Should have no more after consuming single record",
    )


fn test_batched_parser_schema() raises:
    """BatchedParser accepts quality schema string (e.g. sanger) and parses correctly.
    """
    var content = "@id\nACGT\n+\n!!!!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = BatchedParser[MemoryReader](reader^, "sanger", 4)

    var batch = parser.next_batch(4)
    assert_equal(len(batch), 1, "One record")
    var rec = batch.get_record(0)
    assert_equal(rec.SeqStr.to_string(), "ACGT", "Sequence unchanged by schema")


fn test_generate_synthetic_fastq_buffer() raises:
    """Synthetic FASTQ buffer from utils produces valid FASTQ; MemoryReader + BatchedParser yield expected counts and lengths.
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
    var parser = BatchedParser[MemoryReader](reader^, "generic", 8)
    var total = 0
    for batch in parser:
        total += len(batch)
        for i in range(len(batch)):
            var rec = batch.get_record(i)
            var seq_len = len(rec.SeqStr)
            assert_true(
                seq_len >= min_len and seq_len <= max_len,
                "Record sequence length in [min_length, max_length]",
            )
    assert_equal(total, num_reads, "Total records equals num_reads")


comptime ref_parser_large_config = ParserConfig(buffer_capacity=256)


fn test_ref_parser_fast_path_all_lines_in_buffer() raises:
    """RefParser parses records when all four lines fit in buffer (fast path)."""
    var content = "@r1\nACGT\n+\n!!!!\n@r2\nTGCA\n+\n!!!!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = RefParser[MemoryReader, ref_parser_large_config](reader^)

    var r1 = parser.next()
    assert_equal(String(r1.get_header()), "r1", "First record header")
    assert_equal(String(r1.get_seq()), "ACGT", "First record seq")
    assert_equal(String(r1.get_quality()), "!!!!", "First record quality")
    var r2 = parser.next()
    assert_equal(String(r2.get_header()), "r2", "Second record header")
    assert_equal(String(r2.get_seq()), "TGCA", "Second record seq")
    with assert_raises(contains="EOF"):
        _ = parser.next()

    print("✓ test_ref_parser_fast_path_all_lines_in_buffer passed")


comptime ref_parser_small_config = ParserConfig(buffer_capacity=8)

comptime ref_parser_growth_config = ParserConfig(
    buffer_capacity=16,
    buffer_growth_enabled=True,
    buffer_max_capacity=256,
)


fn test_ref_parser_fallback_record_span_chunks() raises:
    """RefParser parses correctly when record spans two chunks (fallback path)."""
    var content = "@r1\nACGT\n+\n!!!!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = RefParser[MemoryReader, ref_parser_small_config](reader^)

    var r = parser.next()
    assert_equal(
        String(r.get_header()), "r1", "Header should match"
    )
    assert_equal(
        String(r.get_seq()), "ACGT", "Sequence should match"
    )
    assert_equal(
        String(r.get_quality()), "!!!!", "Quality should match"
    )
    with assert_raises(contains="EOF"):
        _ = parser.next()

    print("✓ test_ref_parser_fallback_record_span_chunks passed")


fn test_ref_parser_multiple_records_next_loop() raises:
    """RefParser: two records via next(), then EOF (mirror RecordParser for-loop)."""
    var content = "@r1\nACGT\n+\n!!!!\n@r2\nTGCA\n+\n####\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = RefParser[MemoryReader, ref_parser_large_config](reader^)

    var r1 = parser.next()
    assert_equal(String(r1.get_header()), "r1", "First record header")
    assert_equal(String(r1.get_seq()), "ACGT", "First record seq")
    assert_equal(String(r1.get_quality()), "!!!!", "First record quality")
    var r2 = parser.next()
    assert_equal(String(r2.get_header()), "r2", "Second record header")
    assert_equal(String(r2.get_seq()), "TGCA", "Second record seq")
    assert_equal(String(r2.get_quality()), "####", "Second record quality")
    with assert_raises(contains="EOF"):
        _ = parser.next()


fn test_ref_parser_eof_after_one_record() raises:
    """RefParser: single record, second next() raises EOF."""
    var content = "@r1\nACGT\n+\n!!!!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = RefParser[MemoryReader, ref_parser_large_config](reader^)

    var r = parser.next()
    assert_equal(String(r.get_header()), "r1", "Header should match")
    assert_equal(String(r.get_seq()), "ACGT", "Sequence should match")
    assert_equal(String(r.get_quality()), "!!!!", "Quality should match")
    with assert_raises(contains="EOF"):
        _ = parser.next()


fn test_ref_parser_empty_input() raises:
    """RefParser: empty input, first next() raises EOF."""
    var content = ""
    var reader = MemoryReader(content.as_bytes())
    var parser = RefParser[MemoryReader, ref_parser_large_config](reader^)

    with assert_raises(contains="EOF"):
        _ = parser.next()


fn test_ref_parser_invalid_header() raises:
    """RefParser: first line not starting with @ raises."""
    var content = "r1\nACGT\n+\n!!!!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = RefParser[MemoryReader, ref_parser_large_config](reader^)

    with assert_raises(contains="Invalid record header"):
        _ = parser.next()


fn test_ref_parser_multiple_records_span_chunks() raises:
    """RefParser: three records with small buffer so at least one spans chunks."""
    var content = "@r1\nA\n+\n!\n@r2\nB\n+\n!\n@r3\nC\n+\n!\n"
    var reader = MemoryReader(content.as_bytes())
    var parser = RefParser[MemoryReader, ref_parser_small_config](reader^)

    var r1 = parser.next()
    assert_equal(String(r1.get_header()), "r1", "First record header")
    assert_equal(String(r1.get_seq()), "A", "First record seq")
    assert_equal(String(r1.get_quality()), "!", "First record quality")
    var r2 = parser.next()
    assert_equal(String(r2.get_header()), "r2", "Second record header")
    assert_equal(String(r2.get_seq()), "B", "Second record seq")
    var r3 = parser.next()
    assert_equal(String(r3.get_header()), "r3", "Third record header")
    assert_equal(String(r3.get_seq()), "C", "Third record seq")
    assert_equal(String(r3.get_quality()), "!", "Third record quality")
    with assert_raises(contains="EOF"):
        _ = parser.next()


fn _ref_parser_long_record_content() -> String:
    """One FASTQ record with sequence and quality length 20 (longer than small buffer)."""
    var seq = String("")
    for i in range(20):
        seq += "A"
    var qual = String("")
    for i in range(20):
        qual += "!"
    return "@id\n" + seq + "\n+\n" + qual + "\n"


fn test_ref_parser_long_line_with_growth() raises:
    """RefParser: one record with line longer than buffer, buffer_growth_enabled=True."""
    var content = _ref_parser_long_record_content()
    var reader = MemoryReader(content.as_bytes())
    var parser = RefParser[MemoryReader, ref_parser_growth_config](reader^)

    var r = parser.next()
    assert_equal(String(r.get_header()), "id", "Header should match")
    assert_equal(r.len_record(), 20, "Sequence length 20")
    assert_equal(r.len_quality(), 20, "Quality length 20")
    assert_equal(String(r.get_seq()), "AAAAAAAAAAAAAAAAAAAA", "Sequence content")
    assert_equal(String(r.get_quality()), "!!!!!!!!!!!!!!!!!!!!", "Quality content")
    with assert_raises(contains="EOF"):
        _ = parser.next()


fn test_ref_parser_long_line_without_growth() raises:
    """RefParser: line longer than buffer and buffer_growth_enabled=False raises."""
    var content = _ref_parser_long_record_content()
    var reader = MemoryReader(content.as_bytes())
    comptime no_growth_config = ParserConfig(
        buffer_capacity=16,
        buffer_growth_enabled=False,
    )
    var parser = RefParser[MemoryReader, no_growth_config](reader^)

    with assert_raises(contains="Line exceeds buffer capacity"):
        _ = parser.next()


fn test_ref_parser_ascii_validation_enabled() raises:
    """RefParser: non-ASCII bytes fail when ParserConfig(check_ascii=True)."""
    var content = create_non_ascii_fastq_data()
    var reader = MemoryReader(content^)

    with assert_raises(contains="Non ASCII"):
        var parser = RefParser[
            MemoryReader,
            ParserConfig(check_ascii=True, check_quality=False),
        ](reader^)
        _ = parser.next()


fn test_ref_parser_ascii_validation_disabled() raises:
    """RefParser: non-ASCII bytes parse when ParserConfig(check_ascii=False)."""
    var content = create_non_ascii_fastq_data()
    var reader = MemoryReader(content^)

    var parser = RefParser[
        MemoryReader,
        ParserConfig(check_ascii=False, check_quality=False),
    ](reader^)
    var record = parser.next()
    assert_equal(
        String(record.get_header()),
        "r1",
        "Parser should yield record when ASCII validation is disabled",
    )


comptime ref_parser_file_config = ParserConfig(
    quality_schema=Optional[String]("generic"),
)


fn test_ref_parser_valid_file_parity() raises:
    """RefParser: parse valid test_data file, count records and spot-check first."""
    var parser = RefParser[FileReader, ref_parser_file_config](
        FileReader(test_dir + "example.fastq")
    )
    var first = parser.next()
    assert_true(len(String(first.get_header())) > 0, "First record has header")
    assert_true(first.len_record() > 0, "First record has sequence")
    var count = 1
    while True:
        try:
            _ = parser.next()
            count += 1
        except Error:
            var err_msg = String(Error)
            if err_msg.find("EOF") >= 0:
                break
            raise
    assert_true(count >= 1, "At least one record from valid file")


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
