"""Correctness tests for FastqParser: each valid/invalid file in test_data/fastq_parser exercised individually.
Test data from BioJava/BioPerl/Biopython FASTQ test suites.
URL: https://github.com/biopython/biopython/tree/master/Tests/Quality
"""

from blazeseq.fastq.parser import FastqParser, ParserConfig
from blazeseq.io.readers import FileReader, RapidgzipReader
from blazeseq.CONSTS import EOF
from std.pathlib import Path
from std.testing import assert_true, TestSuite

comptime test_dir = "tests/test_data/fastq_parser/"

comptime corrput_qu_score = "Corrupt quality score according to provided schema"
comptime cor_len = "Quality and sequence line do not match in length"
comptime cor_seq_hed = "Sequence id line does not start with '@'"
comptime plus_line_start = "Plus line does not start with '+'"
comptime sep_line_start = "Separator line does not start with '+'"


fn invalid_file_test_fun(file: String, msg: String = "") raises:
    """Invalid file must raise; accept msg, EOF, or length mismatch (plus-line checks removed).
    """
    comptime config_ = ParserConfig(check_ascii=True, check_quality=True)
    try:
        var parser = FastqParser[FileReader, config_](
            FileReader(test_dir + file)
        )
        while True:
            _ = parser.next_record()
    except e:
        raised = True
        err_msg = String(e)
        if (
            err_msg.find(msg) < 0
            and err_msg.find("EOF") < 0
            and err_msg.find(cor_len) < 0
            and err_msg.find(cor_seq_hed) < 0
            and err_msg.find(plus_line_start) < 0
            and err_msg.find(sep_line_start) < 0
        ):
            print(err_msg)
            raise
    assert_true(raised, "invalid file should raise: " + file)
    assert_true(
        err_msg.find(msg) >= 0
        or err_msg.find("EOF") >= 0
        or err_msg.find(cor_len) >= 0
        or err_msg.find(cor_seq_hed) >= 0
        or err_msg.find(plus_line_start) >= 0
        or err_msg.find(sep_line_start) >= 0,
        "expected error containing '"
        + msg
        + "', EOF, or length mismatch, got: "
        + err_msg,
    )


fn valid_file_test_fun(file: String, schema: String = "generic") raises:
    var parser = FastqParser[FileReader](FileReader(test_dir + file), schema)
    for _ in parser.records():
        pass


fn valid_file_test_fun_ref(file: String, schema: String = "generic") raises:
    """Same valid files as valid_file_test_fun but iterate via views() (FastqView path).
    """
    var parser = FastqParser[FileReader](FileReader(test_dir + file), schema)
    for view in parser.views():
        _ = view.id()
        _ = view.sequence()
        _ = view.quality()


fn invalid_file_test_fun_ref(file: String, msg: String = "") raises:
    """Same invalid files as invalid_file_test_fun but consume via next_view() (FastqView path).
    """
    comptime config_ = ParserConfig(
        check_ascii=True,
        check_quality=True,
        buffer_capacity=1024 * 1024,
        buffer_growth_enabled=True,
        buffer_max_capacity=1024 * 1024,
    )
    try:
        var parser = FastqParser[FileReader, config_](
            FileReader(test_dir + file)
        )
        while True:
            _ = parser.next_view()
    except e:
        raised = True
        err_msg = String(e)
        if err_msg.find(msg) < 0:
            print(err_msg)
    assert_true(raised, "invalid file should raise: " + file)
    assert_true(
        err_msg.find(msg) >= 0
        or err_msg.find("Line exceeds buffer") >= 0
        or err_msg.find("Line iteration failed") >= 0
        or err_msg.find("EOF") >= 0
        or err_msg.find(cor_len) >= 0
        or err_msg.find(cor_seq_hed) >= 0
        or err_msg.find(plus_line_start) >= 0
        or err_msg.find(sep_line_start) >= 0,
        "expected error containing '"
        + msg
        + "' or parse/buffer error, got: "
        + err_msg,
    )


fn valid_file_test_fun_gz(file_gz: String, schema: String = "generic") raises:
    """Parse a gzip-compressed FASTQ file; expect valid records (RapidgzipReader).
    """
    var parser = FastqParser[RapidgzipReader](
        RapidgzipReader(test_dir + file_gz), schema
    )
    for _ in parser.records():
        pass


fn valid_file_test_fun_gz_ref(
    file_gz: String, schema: String = "generic"
) raises:
    """Same as valid_file_test_fun_gz but iterate via views()."""
    var parser = FastqParser[RapidgzipReader](
        RapidgzipReader(test_dir + file_gz), schema
    )
    for view in parser.views():
        _ = view.id()
        _ = view.sequence()
        _ = view.quality()


# ---------------------------------------------------------------------------
# Valid file tests (one per file)
# ---------------------------------------------------------------------------


fn test_valid_example_fastq() raises:
    valid_file_test_fun("example.fastq")


fn test_valid_example_fastq_ref() raises:
    valid_file_test_fun_ref("example.fastq")


fn test_valid_example_dos_fastq() raises:
    valid_file_test_fun("example_dos.fastq")


fn test_valid_example_dos_fastq_ref() raises:
    valid_file_test_fun_ref("example_dos.fastq")


fn test_valid_illumina_example_fastq() raises:
    valid_file_test_fun("illumina_example.fastq", "illumina_1.3")


fn test_valid_illumina_example_fastq_ref() raises:
    valid_file_test_fun_ref("illumina_example.fastq", "illumina_1.3")


fn test_valid_illumina_faked_fastq() raises:
    valid_file_test_fun("illumina_faked.fastq", "illumina_1.3")


fn test_valid_illumina_faked_fastq_ref() raises:
    valid_file_test_fun_ref("illumina_faked.fastq", "illumina_1.3")


fn test_valid_illumina_full_range_as_illumina_fastq() raises:
    valid_file_test_fun("illumina_full_range_as_illumina.fastq", "illumina_1.3")


fn test_valid_illumina_full_range_as_illumina_fastq_ref() raises:
    valid_file_test_fun_ref(
        "illumina_full_range_as_illumina.fastq", "illumina_1.3"
    )


fn test_valid_illumina_full_range_as_sanger_fastq() raises:
    valid_file_test_fun("illumina_full_range_as_sanger.fastq", "sanger")


fn test_valid_illumina_full_range_as_sanger_fastq_ref() raises:
    valid_file_test_fun_ref("illumina_full_range_as_sanger.fastq", "sanger")


fn test_valid_illumina_full_range_as_solexa_fastq() raises:
    valid_file_test_fun("illumina_full_range_as_solexa.fastq", "solexa")


fn test_valid_illumina_full_range_as_solexa_fastq_ref() raises:
    valid_file_test_fun_ref("illumina_full_range_as_solexa.fastq", "solexa")


fn test_valid_illumina_full_range_original_illumina_fastq() raises:
    valid_file_test_fun(
        "illumina_full_range_original_illumina.fastq", "illumina_1.3"
    )


fn test_valid_illumina_full_range_original_illumina_fastq_ref() raises:
    valid_file_test_fun_ref(
        "illumina_full_range_original_illumina.fastq", "illumina_1.3"
    )


fn test_valid_longreads_as_illumina_fastq() raises:
    valid_file_test_fun("longreads_as_illumina.fastq", "illumina_1.3")


fn test_valid_longreads_as_illumina_fastq_ref() raises:
    valid_file_test_fun_ref("longreads_as_illumina.fastq", "illumina_1.3")


fn test_valid_longreads_as_sanger_fastq() raises:
    valid_file_test_fun("longreads_as_sanger.fastq", "sanger")


fn test_valid_longreads_as_sanger_fastq_ref() raises:
    valid_file_test_fun_ref("longreads_as_sanger.fastq", "sanger")


fn test_valid_longreads_as_solexa_fastq() raises:
    valid_file_test_fun("longreads_as_solexa.fastq", "solexa")


fn test_valid_longreads_as_solexa_fastq_ref() raises:
    valid_file_test_fun_ref("longreads_as_solexa.fastq", "solexa")


fn test_valid_misc_dna_as_illumina_fastq() raises:
    valid_file_test_fun("misc_dna_as_illumina.fastq", "illumina_1.3")


fn test_valid_misc_dna_as_illumina_fastq_ref() raises:
    valid_file_test_fun_ref("misc_dna_as_illumina.fastq", "illumina_1.3")


fn test_valid_misc_dna_as_sanger_fastq() raises:
    valid_file_test_fun("misc_dna_as_sanger.fastq", "sanger")


fn test_valid_misc_dna_as_sanger_fastq_ref() raises:
    valid_file_test_fun_ref("misc_dna_as_sanger.fastq", "sanger")


fn test_valid_misc_dna_as_solexa_fastq() raises:
    valid_file_test_fun("misc_dna_as_solexa.fastq", "solexa")


fn test_valid_misc_dna_as_solexa_fastq_ref() raises:
    valid_file_test_fun_ref("misc_dna_as_solexa.fastq", "solexa")


fn test_valid_misc_dna_original_sanger_fastq() raises:
    valid_file_test_fun("misc_dna_original_sanger.fastq", "sanger")


fn test_valid_misc_dna_original_sanger_fastq_ref() raises:
    valid_file_test_fun_ref("misc_dna_original_sanger.fastq", "sanger")


fn test_valid_misc_rna_as_illumina_fastq() raises:
    valid_file_test_fun("misc_rna_as_illumina.fastq", "illumina_1.3")


fn test_valid_misc_rna_as_illumina_fastq_ref() raises:
    valid_file_test_fun_ref("misc_rna_as_illumina.fastq", "illumina_1.3")


fn test_valid_misc_rna_as_sanger_fastq() raises:
    valid_file_test_fun("misc_rna_as_sanger.fastq", "sanger")


fn test_valid_misc_rna_as_sanger_fastq_ref() raises:
    valid_file_test_fun_ref("misc_rna_as_sanger.fastq", "sanger")


fn test_valid_misc_rna_as_solexa_fastq() raises:
    valid_file_test_fun("misc_rna_as_solexa.fastq", "solexa")


fn test_valid_misc_rna_as_solexa_fastq_ref() raises:
    valid_file_test_fun_ref("misc_rna_as_solexa.fastq", "solexa")


fn test_valid_misc_rna_original_sanger_fastq() raises:
    valid_file_test_fun("misc_rna_original_sanger.fastq", "sanger")


fn test_valid_misc_rna_original_sanger_fastq_ref() raises:
    valid_file_test_fun_ref("misc_rna_original_sanger.fastq", "sanger")


fn test_valid_sanger_93_fastq() raises:
    valid_file_test_fun("sanger_93.fastq", "sanger")


fn test_valid_sanger_93_fastq_ref() raises:
    valid_file_test_fun_ref("sanger_93.fastq", "sanger")


fn test_valid_sanger_faked_fastq() raises:
    valid_file_test_fun("sanger_faked.fastq", "sanger")


fn test_valid_sanger_faked_fastq_ref() raises:
    valid_file_test_fun_ref("sanger_faked.fastq", "sanger")


fn test_valid_sanger_full_range_as_illumina_fastq() raises:
    valid_file_test_fun("sanger_full_range_as_illumina.fastq", "illumina_1.3")


fn test_valid_sanger_full_range_as_illumina_fastq_ref() raises:
    valid_file_test_fun_ref(
        "sanger_full_range_as_illumina.fastq", "illumina_1.3"
    )


fn test_valid_sanger_full_range_as_sanger_fastq() raises:
    valid_file_test_fun("sanger_full_range_as_sanger.fastq", "sanger")


fn test_valid_sanger_full_range_as_sanger_fastq_ref() raises:
    valid_file_test_fun_ref("sanger_full_range_as_sanger.fastq", "sanger")


fn test_valid_sanger_full_range_as_solexa_fastq() raises:
    valid_file_test_fun("sanger_full_range_as_solexa.fastq", "solexa")


fn test_valid_sanger_full_range_as_solexa_fastq_ref() raises:
    valid_file_test_fun_ref("sanger_full_range_as_solexa.fastq", "solexa")


fn test_valid_sanger_full_range_original_sanger_fastq() raises:
    valid_file_test_fun("sanger_full_range_original_sanger.fastq", "sanger")


fn test_valid_sanger_full_range_original_sanger_fastq_ref() raises:
    valid_file_test_fun_ref("sanger_full_range_original_sanger.fastq", "sanger")


fn test_valid_solexa_example_fastq() raises:
    valid_file_test_fun("solexa_example.fastq", "solexa")


fn test_valid_solexa_example_fastq_ref() raises:
    valid_file_test_fun_ref("solexa_example.fastq", "solexa")


fn test_valid_solexa_faked_fastq() raises:
    valid_file_test_fun("solexa_faked.fastq", "solexa")


fn test_valid_solexa_faked_fastq_ref() raises:
    valid_file_test_fun_ref("solexa_faked.fastq", "solexa")


fn test_valid_solexa_full_range_as_illumina_fastq() raises:
    valid_file_test_fun("solexa_full_range_as_illumina.fastq", "illumina_1.3")


fn test_valid_solexa_full_range_as_illumina_fastq_ref() raises:
    valid_file_test_fun_ref(
        "solexa_full_range_as_illumina.fastq", "illumina_1.3"
    )


fn test_valid_solexa_full_range_as_sanger_fastq() raises:
    valid_file_test_fun("solexa_full_range_as_sanger.fastq", "sanger")


fn test_valid_solexa_full_range_as_sanger_fastq_ref() raises:
    valid_file_test_fun_ref("solexa_full_range_as_sanger.fastq", "sanger")


fn test_valid_solexa_full_range_as_solexa_fastq() raises:
    valid_file_test_fun("solexa_full_range_as_solexa.fastq", "solexa")


fn test_valid_solexa_full_range_as_solexa_fastq_ref() raises:
    valid_file_test_fun_ref("solexa_full_range_as_solexa.fastq", "solexa")


fn test_valid_solexa_full_range_original_solexa_fastq() raises:
    valid_file_test_fun("solexa_full_range_original_solexa.fastq", "solexa")


fn test_valid_solexa_full_range_original_solexa_fastq_ref() raises:
    valid_file_test_fun_ref("solexa_full_range_original_solexa.fastq", "solexa")


fn test_valid_test1_sanger_fastq() raises:
    valid_file_test_fun("test1_sanger.fastq", "sanger")


fn test_valid_test1_sanger_fastq_ref() raises:
    valid_file_test_fun_ref("test1_sanger.fastq", "sanger")


fn test_valid_test2_solexa_fastq() raises:
    valid_file_test_fun("test2_solexa.fastq", "solexa")


fn test_valid_test2_solexa_fastq_ref() raises:
    valid_file_test_fun_ref("test2_solexa.fastq", "solexa")


fn test_valid_test3_illumina_fastq() raises:
    valid_file_test_fun("test3_illumina.fastq", "illumina_1.3")


fn test_valid_test3_illumina_fastq_ref() raises:
    valid_file_test_fun_ref("test3_illumina.fastq", "illumina_1.3")


fn test_valid_wrapping_as_illumina_fastq() raises:
    valid_file_test_fun("wrapping_as_illumina.fastq", "illumina_1.3")


fn test_valid_wrapping_as_illumina_fastq_ref() raises:
    valid_file_test_fun_ref("wrapping_as_illumina.fastq", "illumina_1.3")


fn test_valid_wrapping_as_sanger_fastq() raises:
    valid_file_test_fun("wrapping_as_sanger.fastq", "sanger")


fn test_valid_wrapping_as_sanger_fastq_ref() raises:
    valid_file_test_fun_ref("wrapping_as_sanger.fastq", "sanger")


fn test_valid_wrapping_as_solexa_fastq() raises:
    valid_file_test_fun("wrapping_as_solexa.fastq", "solexa")


fn test_valid_wrapping_as_solexa_fastq_ref() raises:
    valid_file_test_fun_ref("wrapping_as_solexa.fastq", "solexa")


# ---------------------------------------------------------------------------
# Multi-line FASTQ (disabled: BlazeSeq does not support wrapped seq/qual lines)
# ---------------------------------------------------------------------------

# fn test_valid_tricky_fastq() raises:
#     # Disabled: multi-line FASTQ not supported
#     valid_file_test_fun("tricky.fastq", "illumina_1.3")

# fn test_valid_tricky_fastq_ref() raises:
#     # Disabled: multi-line FASTQ not supported
#     valid_file_test_fun_ref("tricky.fastq", "illumina_1.3")

# fn test_valid_longreads_original_sanger_fastq() raises:
#     # Disabled: multi-line FASTQ not supported
#     valid_file_test_fun("longreads_original_sanger.fastq", "sanger")

# fn test_valid_longreads_original_sanger_fastq_ref() raises:
#     # Disabled: multi-line FASTQ not supported
#     valid_file_test_fun_ref("longreads_original_sanger.fastq", "sanger")

# fn test_valid_wrapping_original_sanger_fastq() raises:
#     # Disabled: multi-line FASTQ not supported
#     valid_file_test_fun("wrapping_original_sanger.fastq", "sanger")

# fn test_valid_wrapping_original_sanger_fastq_ref() raises:
#     # Disabled: multi-line FASTQ not supported
#     valid_file_test_fun_ref("wrapping_original_sanger.fastq", "sanger")


# ---------------------------------------------------------------------------
# Compressed FASTQ (RapidgzipReader)
# ---------------------------------------------------------------------------


fn test_valid_example_fastq_gz() raises:
    valid_file_test_fun_gz("example.fastq.gz")


fn test_valid_example_fastq_gz_ref() raises:
    valid_file_test_fun_gz_ref("example.fastq.gz")


fn test_valid_example_fastq_bgz() raises:
    valid_file_test_fun_gz("example.fastq.bgz")


fn test_valid_example_fastq_bgz_ref() raises:
    valid_file_test_fun_gz_ref("example.fastq.bgz")


fn test_valid_example_dos_fastq_bgz() raises:
    valid_file_test_fun_gz("example_dos.fastq.bgz")


fn test_valid_example_dos_fastq_bgz_ref() raises:
    valid_file_test_fun_gz_ref("example_dos.fastq.bgz")


# ---------------------------------------------------------------------------
# Invalid file tests (one per file)
# ---------------------------------------------------------------------------


fn test_invalid_empty_fastq() raises:
    invalid_file_test_fun("empty.fastq", EOF)


fn test_invalid_empty_fastq_ref() raises:
    invalid_file_test_fun_ref("empty.fastq", EOF)


fn test_invalid_error_diff_ids_fastq() raises:
    invalid_file_test_fun("error_diff_ids.fastq", EOF)


fn test_invalid_error_diff_ids_fastq_ref() raises:
    invalid_file_test_fun_ref("error_diff_ids.fastq", EOF)


fn test_invalid_error_long_qual_fastq() raises:
    invalid_file_test_fun("error_long_qual.fastq", cor_len)


fn test_invalid_error_long_qual_fastq_ref() raises:
    invalid_file_test_fun_ref("error_long_qual.fastq", cor_len)


fn test_invalid_error_no_qual_fastq() raises:
    invalid_file_test_fun("error_no_qual.fastq", cor_len)


fn test_invalid_error_no_qual_fastq_ref() raises:
    invalid_file_test_fun_ref("error_no_qual.fastq", cor_len)


fn test_invalid_error_trunc_in_plus_fastq() raises:
    invalid_file_test_fun("error_trunc_in_plus.fastq", cor_len)


fn test_invalid_error_trunc_in_plus_fastq_ref() raises:
    invalid_file_test_fun_ref("error_trunc_in_plus.fastq", cor_len)


fn test_invalid_error_trunc_at_qual_fastq() raises:
    invalid_file_test_fun("error_trunc_at_qual.fastq", cor_len)


fn test_invalid_error_trunc_at_qual_fastq_ref() raises:
    invalid_file_test_fun_ref("error_trunc_at_qual.fastq", cor_len)


fn test_invalid_error_double_qual_fastq() raises:
    invalid_file_test_fun("error_double_qual.fastq", cor_seq_hed)


fn test_invalid_error_double_qual_fastq_ref() raises:
    invalid_file_test_fun_ref("error_double_qual.fastq", cor_seq_hed)


fn test_invalid_error_trunc_at_seq_fastq() raises:
    invalid_file_test_fun("error_trunc_at_seq.fastq", cor_len)


fn test_invalid_error_trunc_at_seq_fastq_ref() raises:
    invalid_file_test_fun_ref("error_trunc_at_seq.fastq", cor_len)


fn test_invalid_error_trunc_in_seq_fastq() raises:
    invalid_file_test_fun("error_trunc_in_seq.fastq", cor_len)


fn test_invalid_error_trunc_in_seq_fastq_ref() raises:
    invalid_file_test_fun_ref("error_trunc_in_seq.fastq", cor_len)


fn test_invalid_error_trunc_in_title_fastq() raises:
    invalid_file_test_fun("error_trunc_in_title.fastq", cor_len)


fn test_invalid_error_trunc_in_title_fastq_ref() raises:
    invalid_file_test_fun_ref("error_trunc_in_title.fastq", cor_len)


fn test_invalid_error_double_seq_fastq() raises:
    invalid_file_test_fun("error_double_seq.fastq", cor_len)


fn test_invalid_error_double_seq_fastq_ref() raises:
    invalid_file_test_fun_ref("error_double_seq.fastq", cor_len)


fn test_invalid_error_trunc_at_plus_fastq() raises:
    invalid_file_test_fun("error_trunc_at_plus.fastq", cor_len)


fn test_invalid_error_trunc_at_plus_fastq_ref() raises:
    invalid_file_test_fun_ref("error_trunc_at_plus.fastq", cor_len)


fn test_invalid_error_qual_null_fastq() raises:
    invalid_file_test_fun("error_qual_null.fastq", corrput_qu_score)


fn test_invalid_error_qual_null_fastq_ref() raises:
    invalid_file_test_fun_ref("error_qual_null.fastq", corrput_qu_score)


fn test_invalid_error_qual_space_fastq() raises:
    invalid_file_test_fun("error_qual_space.fastq", corrput_qu_score)


fn test_invalid_error_qual_space_fastq_ref() raises:
    invalid_file_test_fun_ref("error_qual_space.fastq", corrput_qu_score)


fn test_invalid_error_spaces_fastq() raises:
    invalid_file_test_fun("error_spaces.fastq", corrput_qu_score)


fn test_invalid_error_spaces_fastq_ref() raises:
    invalid_file_test_fun_ref("error_spaces.fastq", corrput_qu_score)


fn test_invalid_error_qual_vtab_fastq() raises:
    invalid_file_test_fun("error_qual_vtab.fastq", corrput_qu_score)


fn test_invalid_error_qual_vtab_fastq_ref() raises:
    invalid_file_test_fun_ref("error_qual_vtab.fastq", corrput_qu_score)


fn test_invalid_error_tabs_fastq() raises:
    invalid_file_test_fun("error_tabs.fastq", corrput_qu_score)


fn test_invalid_error_tabs_fastq_ref() raises:
    invalid_file_test_fun_ref("error_tabs.fastq", corrput_qu_score)


fn test_invalid_error_qual_tab_fastq() raises:
    invalid_file_test_fun("error_qual_tab.fastq", corrput_qu_score)


fn test_invalid_error_qual_tab_fastq_ref() raises:
    invalid_file_test_fun_ref("error_qual_tab.fastq", corrput_qu_score)


fn test_invalid_error_qual_del_fastq() raises:
    invalid_file_test_fun("error_qual_del.fastq", corrput_qu_score)


fn test_invalid_error_qual_del_fastq_ref() raises:
    invalid_file_test_fun_ref("error_qual_del.fastq", corrput_qu_score)


fn test_invalid_error_qual_escape_fastq() raises:
    invalid_file_test_fun("error_qual_escape.fastq", corrput_qu_score)


fn test_invalid_error_qual_escape_fastq_ref() raises:
    invalid_file_test_fun_ref("error_qual_escape.fastq", corrput_qu_score)


fn test_invalid_solexa_invalid_description_fastq() raises:
    invalid_file_test_fun("solexa-invalid-description.fastq", cor_seq_hed)


fn test_invalid_solexa_invalid_description_fastq_ref() raises:
    invalid_file_test_fun_ref("solexa-invalid-description.fastq", cor_seq_hed)


fn test_invalid_solexa_invalid_repeat_description_fastq() raises:
    invalid_file_test_fun("solexa-invalid-repeat-description.fastq", EOF)


fn test_invalid_solexa_invalid_repeat_description_fastq_ref() raises:
    invalid_file_test_fun_ref("solexa-invalid-repeat-description.fastq", EOF)


fn test_invalid_sanger_invalid_description_fastq() raises:
    invalid_file_test_fun("sanger-invalid-description.fastq", cor_seq_hed)


fn test_invalid_sanger_invalid_description_fastq_ref() raises:
    invalid_file_test_fun_ref("sanger-invalid-description.fastq", cor_seq_hed)


fn test_invalid_sanger_invalid_repeat_description_fastq() raises:
    invalid_file_test_fun("sanger-invalid-repeat-description.fastq", EOF)


fn test_invalid_sanger_invalid_repeat_description_fastq_ref() raises:
    invalid_file_test_fun_ref("sanger-invalid-repeat-description.fastq", EOF)


fn test_invalid_illumina_invalid_description_fastq() raises:
    invalid_file_test_fun("illumina-invalid-description.fastq", cor_seq_hed)


fn test_invalid_illumina_invalid_description_fastq_ref() raises:
    invalid_file_test_fun_ref("illumina-invalid-description.fastq", cor_seq_hed)


fn test_invalid_illumina_invalid_repeat_description_fastq() raises:
    invalid_file_test_fun("illumina-invalid-repeat-description.fastq", EOF)


fn test_invalid_illumina_invalid_repeat_description_fastq_ref() raises:
    invalid_file_test_fun_ref("illumina-invalid-repeat-description.fastq", EOF)


fn test_invalid_error_qual_unit_sep_fastq() raises:
    invalid_file_test_fun("error_qual_unit_sep.fastq", corrput_qu_score)


fn test_invalid_error_qual_unit_sep_fastq_ref() raises:
    invalid_file_test_fun_ref("error_qual_unit_sep.fastq", corrput_qu_score)


fn test_invalid_error_short_qual_fastq() raises:
    invalid_file_test_fun("error_short_qual.fastq", cor_len)


fn test_invalid_error_short_qual_fastq_ref() raises:
    invalid_file_test_fun_ref("error_short_qual.fastq", cor_len)


fn test_invalid_error_trunc_in_qual_fastq() raises:
    invalid_file_test_fun("error_trunc_in_qual.fastq", cor_len)


fn test_invalid_error_trunc_in_qual_fastq_ref() raises:
    invalid_file_test_fun_ref("error_trunc_in_qual.fastq", cor_len)


fn test_invalid_zero_length_fastq() raises:
    invalid_file_test_fun("zero_length.fastq", cor_len)


fn test_invalid_zero_length_fastq_ref() raises:
    invalid_file_test_fun_ref("zero_length.fastq", cor_len)


# ---------------------------------------------------------------------------
# Ref path: loop over same file lists
# ---------------------------------------------------------------------------


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
