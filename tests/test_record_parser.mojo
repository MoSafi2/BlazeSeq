"""Testing for the parser on test suite of valid and invalid FASTQ files used for testing by BioJava, BioPerl, and Biopython projects.
File were downloaded from BioJava.
'https://github.com/biojava/biojava/tree/master/biojava-genome%2Fsrc%2Ftest%2Fresources%2Forg%2Fbiojava%2Fnbio%2Fgenome%2Fio%2Ffastq'
Truncated files were padded with 1, 2, or 3, extra line terminators to prevent `EOF` errors and to allow for record validation via the parser's Validator.
Multi-line FASTQ tests are removed as Blazeseq does not support multi-line FASTQ.
"""

from blazeseq.parser import RecordParser
from blazeseq.readers import FileReader, MemoryReader
from blazeseq.parser import ParserConfig
from blazeseq.record import FastqRecord, Validator
from blazeseq.CONSTS import EOF
from testing import assert_equal, assert_raises, TestSuite

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
            for record in parser:
                parser.validator.validate(record)
        except Error:
            var err_msg = String(Error)
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
# fn test_invalid() raises:
# invalid_file_test_fun("empty.fastq", EOF)
# invalid_file_test_fun("error_diff_ids.fastq", non_mat_hed)
# invalid_file_test_fun("error_long_qual.fastq", cor_len)
# invalid_file_test_fun("error_no_qual.fastq", cor_len)
# invalid_file_test_fun("error_trunc_in_plus.fastq", cor_len)
# invalid_file_test_fun("error_trunc_at_qual.fastq", cor_len)
# invalid_file_test_fun("error_double_qual.fastq", cor_seq_hed)
# invalid_file_test_fun("error_trunc_at_seq.fastq", cor_qu_hed)
# invalid_file_test_fun("error_trunc_in_seq.fastq", cor_qu_hed)
# invalid_file_test_fun("error_trunc_in_title.fastq", cor_qu_hed)
# invalid_file_test_fun("error_double_seq.fastq", cor_qu_hed)
# invalid_file_test_fun("error_trunc_at_plus.fastq", cor_qu_hed)
# invalid_file_test_fun("error_qual_null.fastq", corrput_qu_score)
# invalid_file_test_fun("error_qual_space.fastq", corrput_qu_score)
# invalid_file_test_fun("error_spaces.fastq", corrput_qu_score)
# invalid_file_test_fun("error_qual_vtab.fastq", corrput_qu_score)
# invalid_file_test_fun("error_tabs.fastq", corrput_qu_score)
# invalid_file_test_fun("error_qual_tab.fastq", corrput_qu_score)
# invalid_file_test_fun("error_qual_del.fastq", corrput_qu_score)
# invalid_file_test_fun("error_qual_escape.fastq", corrput_qu_score)
# invalid_file_test_fun("solexa-invalid-description.fastq", cor_seq_hed)
# invalid_file_test_fun(
#     "solexa-invalid-repeat-description.fastq", len_mismatch
# )
# invalid_file_test_fun("sanger-invalid-description.fastq", cor_seq_hed)
# invalid_file_test_fun(
#     "sanger-invalid-repeat-description.fastq", len_mismatch
# )
# invalid_file_test_fun("illumina-invalid-description.fastq", cor_seq_hed)
# invalid_file_test_fun(
#     "illumina-invalid-repeat-description.fastq", len_mismatch
# )
# invalid_file_test_fun("error_qual_unit_sep.fastq", corrput_qu_score)
# invalid_file_test_fun("error_short_qual.fastq", cor_len)
# invalid_file_test_fun("error_trunc_in_qual.fastq", cor_len)


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


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
    # test_invalid()
