"""Testing for the parser on test suite of valid and invalid FASTQ files provided by BioJava.
'https://github.com/biojava/biojava/tree/master/biojava-genome%2Fsrc%2Ftest%2Fresources%2Forg%2Fbiojava%2Fnbio%2Fgenome%2Fio%2Ffastq'
Truncated files were padded with 1, 2, or 3, extra line terminators to prevent `EOF` errors and to allow for record validation using the `validate_record` function.
Multi-line FASTQ tests are removed as Blazeseq does not support multi-line FASTQ.
"""

from blazeseq import FastqRecord, RecordParser
from testing import assert_raises
from pathlib import Path
from collections.set import Set

alias test_dir = "test/test_data/fastq_parser/"


fn test_invalid_file(file: String, msg: String = "") raises:
    with assert_raises(contains=msg):
        var parser = RecordParser(test_dir + file)
        parser.parse_all()


fn test_valid_file(file: String) raises:
    var parser = RecordParser(test_dir + file)
    try:
        parser.parse_all()
    except Error:
        var err_msg = Error._message()
        if err_msg == "EOF":
            pass
        else:
            print(err_msg)
            print(file)
            raise


fn test_valid() raises:
    var valid_files = Set[String](
        "bug2335.fastq",
        "example.fastq",
        "illumina_example.fastq",
        "illumina_faked.fastq",
        "illumina_full_range_as_illumina.fastq",
        "illumina_full_range_as_sanger.fastq",
        "illumina_full_range_as_solexa.fastq",
        "illumina_full_range_original_illumina.fastq",
        "longreads_as_illumina.fastq",
        "longreads_as_sanger.fastq",
        "longreads_as_solexa.fastq",
        "misc_dna_as_illumina.fastq",
        "misc_dna_as_sanger.fastq",
        "misc_dna_as_solexa.fastq",
        "misc_dna_original_sanger.fastq",
        "misc_rna_as_illumina.fastq",
        "misc_rna_as_sanger.fastq",
        "misc_rna_as_solexa.fastq",
        "misc_rna_original_sanger.fastq",
        "sanger_93.fastq",
        "sanger_faked.fastq",
        "sanger_full_range_as_illumina.fastq",
        "sanger_full_range_as_sanger.fastq",
        "sanger_full_range_as_solexa.fastq",
        "sanger_full_range_original_sanger.fastq",
        "solexa_example.fastq",
        "solexa_faked.fastq",
        "solexa_full_range_as_illumina.fastq",
        "solexa_full_range_as_sanger.fastq",
        "solexa_full_range_as_solexa.fastq",
        "solexa_full_range_original_solexa.fastq",
        "test1_sanger.fastq",
        "test2_solexa.fastq",
        "test3_illumina.fastq",
        "wrapping_as_illumina.fastq",
        "wrapping_as_sanger.fastq",
        "wrapping_as_solexa.fastq",
    )

    for i in valid_files:
        test_valid_file(i[])


fn test_invalid() raises:
    alias corrput_qu_score = "Corrput quality score according to proivded schema"
    alias EOF = "EOF"
    alias cor_len = "Corrput Lengths"
    alias cor_seq_hed = "Sequence Header is corrput"
    alias cor_qu_hed = "Quality Header is corrupt"
    alias non_mat_hed = "Non matching headers"

    test_invalid_file("empty.fastq", EOF)
    test_invalid_file("error_diff_ids.fastq", non_mat_hed)
    test_invalid_file("error_long_qual.fastq", cor_len)
    test_invalid_file("error_no_qual.fastq", cor_len)
    test_invalid_file("error_trunc_in_plus.fastq", cor_len)
    test_invalid_file("error_trunc_at_qual.fastq", cor_len)
    test_invalid_file("error_double_qual.fastq", cor_seq_hed)
    test_invalid_file("error_trunc_at_seq.fastq", cor_qu_hed)
    test_invalid_file("error_trunc_in_seq.fastq", cor_qu_hed)
    test_invalid_file("error_trunc_in_title.fastq", cor_qu_hed)
    test_invalid_file("error_double_seq.fastq", cor_qu_hed)
    test_invalid_file("error_trunc_at_plus.fastq", cor_qu_hed)
    test_invalid_file("error_qual_null.fastq", corrput_qu_score)
    test_invalid_file("error_qual_space.fastq", corrput_qu_score)
    test_invalid_file("error_spaces.fastq", corrput_qu_score)
    test_invalid_file("error_qual_vtab.fastq", corrput_qu_score)
    test_invalid_file("error_tabs.fastq", corrput_qu_score)
    test_invalid_file("error_qual_tab.fastq", corrput_qu_score)
    test_invalid_file("error_qual_del.fastq", corrput_qu_score)
    test_invalid_file("error_qual_escape.fastq", corrput_qu_score)
    test_invalid_file("solexa-invalid-description.fastq", cor_seq_hed)
    test_invalid_file("solexa-invalid-repeat-description.fastq", cor_qu_hed)
    test_invalid_file("sanger-invalid-description.fastq", cor_seq_hed)
    test_invalid_file("sanger-invalid-repeat-description.fastq", cor_qu_hed)
    test_invalid_file("illumina-invalid-description.fastq", cor_seq_hed)
    test_invalid_file("illumina-invalid-repeat-description.fastq", cor_qu_hed)
    test_invalid_file("error_qual_unit_sep.fastq", corrput_qu_score)
    test_invalid_file("error_short_qual.fastq", cor_len)
    test_invalid_file("error_trunc_in_qual.fastq", cor_len)


fn main() raises:
    test_invalid()
    test_valid()
