from blazeseq import FastqRecord, RecordParser
from blazeseq.helpers import get_next_line
from testing import assert_equal, assert_false, assert_true, assert_raises


fn test_invalid() raises:
    with assert_raises(contains="Non matching headers"):
        var parser = RecordParser[validate_ascii=True](
            "test/test_data/fastq_parser/error_diff_ids.fastq"
        )
        parser.parse_all()


fn main() raises:
    test_invalid()
