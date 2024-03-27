"""Testing for the parser on test suite of valid and invalid FASTQ files provided by BioJava.
'https://github.com/biojava/biojava/tree/master/biojava-genome%2Fsrc%2Ftest%2Fresources%2Forg%2Fbiojava%2Fnbio%2Fgenome%2Fio%2Ffastq'
Truncated files were padded with 1, 2, or 3, extra line terminators to prevent `EOF` errors and to allow for record validation using the `validate_record` function.
Multi-line FASTQ tests are removed as Blazeseq does not support multi-line FASTQ.
"""

from blazeseq import FastqRecord, RecordParser
from blazeseq.helpers import get_next_line
from testing import assert_equal, assert_false, assert_true, assert_raises
from pathlib import Path

alias test_dir = "test/test_data/fastq_parser/"


fn test_invalid_file(file: String, msg: String = "") raises:
    with assert_raises(contains=msg):
        var parser = RecordParser(test_dir + file)
        parser.parse_all()


fn test_invalid_basic() raises:
    alias corrput_qu_score = "Corrput quality score according to proivded schema"
    alias EOF = "EOF"
    alias cor_len = "Corrput Lengths"
    alias cor_seq_hed = "Sequence Header is corrput"
    alias cor_qu_hed = "Quality Header is corrput"
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


fn test_valid_files():
    pass


fn main() raises:
    test_invalid_basic()
