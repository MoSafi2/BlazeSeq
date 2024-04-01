"""Testing for the parser on test suite of valid and invalid FASTQ files used for testing by BioJava, BioPerl, and Biopython projects.
File were downloaded from BioJava.
'https://github.com/biojava/biojava/tree/master/biojava-genome%2Fsrc%2Ftest%2Fresources%2Forg%2Fbiojava%2Fnbio%2Fgenome%2Fio%2Ffastq'
As CoordParser only checks the headers and lengths of the of record component, tests were limited to only those cases.
"""

from blazeseq import CoordParser
from testing import assert_raises


alias test_dir = "test/test_data/fastq_parser/"

alias corrput_qu_score = "Corrput quality score according to proivded schema"
alias EOF = "EOF"
alias cor_len = "Corrput Lengths"
alias cor_seq_hed = "Sequence Header is corrupt"
alias cor_qu_hed = "Quality Header is corrupt"
alias non_mat_hed = "Non matching headers"


fn test_invalid_file(file: String, msg: String = "") raises:
    try:
        var parser = CoordParser(test_dir + file)
        parser.parse_all()
    except Error:
        var err_msg = Error._message()
        if err_msg == msg:
            return
        else:
            print(err_msg)
            print(file)
            raise


fn test_valid_file(file: String, schema: String = "generic") raises:
    try:
        var parser = CoordParser(test_dir + file)
        parser.parse_all()
    except Error:
        var err_msg = Error._message()
        if err_msg == "EOF":
            return
        else:
            print(file)
            print(err_msg)
            raise


fn test_invalid() raises:
    test_invalid_file("empty.fastq", EOF)
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
    test_invalid_file("solexa-invalid-description.fastq", cor_seq_hed)
    test_invalid_file("solexa-invalid-repeat-description.fastq", cor_len)
    test_invalid_file("sanger-invalid-description.fastq", cor_seq_hed)
    test_invalid_file("sanger-invalid-repeat-description.fastq", cor_len)
    test_invalid_file("illumina-invalid-description.fastq", cor_seq_hed)
    test_invalid_file("illumina-invalid-repeat-description.fastq", cor_len)
    test_invalid_file("error_short_qual.fastq", cor_len)
    test_invalid_file("error_trunc_in_qual.fastq", cor_len)

    ### CoordParsers fails fests of the record content, as it can not provide guarantees about record content #####

    # test_invalid_file("error_diff_ids.fastq", non_mat_hed)
    # test_invalid_file("error_qual_null.fastq", corrput_qu_score)
    # test_invalid_file("error_qual_vtab.fastq", corrput_qu_score)
    # test_invalid_file("error_tabs.fastq", cor_seq_hed)
    # test_invalid_file("error_qual_tab.fastq", cor_seq_hed)
    # test_invalid_file("error_qual_unit_sep.fastq", corrput_qu_score)


fn test_valid() raises:
    test_valid_file("example.fastq")
    test_valid_file("illumina_example.fastq", "illumina_1.3")
    test_valid_file("illumina_faked.fastq", "illumina_1.3")
    test_valid_file("illumina_full_range_as_illumina.fastq", "illumina_1.3")
    test_valid_file("illumina_full_range_as_sanger.fastq", "sanger")
    test_valid_file("illumina_full_range_as_solexa.fastq", "solexa")
    test_valid_file("illumina_full_range_original_illumina.fastq", "illumina_1.3")
    test_valid_file("longreads_as_illumina.fastq", "illumina_1.3")
    test_valid_file("longreads_as_sanger.fastq", "sanger")
    test_valid_file("longreads_as_solexa.fastq", "solexa")
    test_valid_file("misc_dna_as_illumina.fastq", "illumina_1.3")
    test_valid_file("misc_dna_as_sanger.fastq", "sanger")
    test_valid_file("misc_dna_as_solexa.fastq", "solexa")
    test_valid_file("misc_dna_original_sanger.fastq", "sanger")
    test_valid_file("misc_rna_as_illumina.fastq", "illumina_1.3")
    test_valid_file("misc_rna_as_sanger.fastq", "sanger")
    test_valid_file("misc_rna_as_solexa.fastq", "solexa")
    test_valid_file("misc_rna_original_sanger.fastq", "sanger")
    test_valid_file("sanger_93.fastq", "sanger")
    test_valid_file("sanger_faked.fastq", "sanger")
    test_valid_file("sanger_full_range_as_illumina.fastq", "illumina_1.3")
    test_valid_file("sanger_full_range_as_sanger.fastq", "sanger")
    test_valid_file("sanger_full_range_as_solexa.fastq", "solexa")
    test_valid_file("sanger_full_range_original_sanger.fastq", "sanger")
    test_valid_file("solexa_example.fastq", "solexa")
    test_valid_file("solexa_faked.fastq", "solexa")
    test_valid_file("solexa_full_range_as_illumina.fastq", "illumina_1.3")
    test_valid_file("solexa_full_range_as_sanger.fastq", "sanger")
    test_valid_file("solexa_full_range_as_solexa.fastq", "solexa")
    test_valid_file("solexa_full_range_original_solexa.fastq", "solexa")
    test_valid_file("test1_sanger.fastq", "sanger")
    test_valid_file("test2_solexa.fastq", "solexa")
    test_valid_file("test3_illumina.fastq", "illumina_1.3")
    test_valid_file("wrapping_as_illumina.fastq", "illumina_1.3")
    test_valid_file("wrapping_as_sanger.fastq", "sanger")
    test_valid_file("wrapping_as_solexa.fastq", "solexa")


fn main() raises:
    test_invalid()
    test_valid()
