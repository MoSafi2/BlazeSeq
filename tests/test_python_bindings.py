"""
Test Python bindings for BlazeSeq FASTQ parser.

Run from project root with Python that has mojo.importer (e.g. pymodo):
  python tests/test_python_bindings.py

Or with pixi (adds project root to path):
  pixi run python tests/test_python_bindings.py
"""
import os
import sys

# Ensure we can import the Mojo module: add 'python' dir (contains blazeseq_parser.mojo) to path.
_repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_python_dir = os.path.join(_repo_root, "python")
if _python_dir not in sys.path:
    sys.path.insert(0, _python_dir)

# Mojo importer compiles .mojo on first import
import mojo.importer
import blazeseq_parser

FASTQ_PATH = os.path.join(_repo_root, "tests", "test_data", "fastq_parser", "example.fastq")


def test_create_parser_and_next_record():
    """Loop with next_record until EOF; check first record id and sequence."""
    parser = blazeseq_parser.create_parser(FASTQ_PATH, "generic")
    assert blazeseq_parser.has_more(parser)

    count = 0
    while True:
        try:
            rec = blazeseq_parser.next_record(parser)
            count += 1
            if count == 1:
                assert rec.id() == "EAS54_6_R1_2_1_413_324"
                assert "CCCTTCTTGTCTTCAGCGTTTCTCC" in rec.sequence()
                seq_len = len(rec.sequence())
                assert seq_len > 0
                assert int(rec.__len__()) >= seq_len
                assert len(rec.phred_scores()) >= seq_len
        except Exception as e:
            if "EOF" in str(e):
                break
            raise
    assert count == 3


def test_next_batch_and_get_record():
    """Loop with next_batch; check num_records and get_record(i)."""
    parser = blazeseq_parser.create_parser(FASTQ_PATH, "generic")
    batch = blazeseq_parser.next_batch(parser, 2)
    assert batch.num_records() == 2
    first = batch.get_record(0)
    assert first.id() == "EAS54_6_R1_2_1_413_324"
    second = batch.get_record(1)
    assert second.id() == "EAS54_6_R1_2_1_540_792"

    batch2 = blazeseq_parser.next_batch(parser, 10)
    assert batch2.num_records() == 1
    assert batch2.get_record(0).id() == "EAS54_6_R1_2_1_443_348"


def test_eof_raises():
    """Calling next_record past EOF raises."""
    parser = blazeseq_parser.create_parser(FASTQ_PATH, "generic")
    for _ in range(3):
        blazeseq_parser.next_record(parser)
    try:
        blazeseq_parser.next_record(parser)
        assert False, "expected exception"
    except Exception as e:
        assert "EOF" in str(e)


def main():
    test_create_parser_and_next_record()
    print("test_create_parser_and_next_record passed")
    test_next_batch_and_get_record()
    print("test_next_batch_and_get_record passed")
    test_eof_raises()
    print("test_eof_raises passed")
    print("All Python binding tests passed.")


if __name__ == "__main__":
    main()
