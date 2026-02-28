"""
Test Python bindings for BlazeSeq FASTQ parser.

Expects the blazeseq package to be installed (e.g. pip install -e python/
after building the Mojo extension, or install a wheel from CI/PyPI).

Run from project root:
  pip install -e python/   # after building .so into python/blazeseq/_extension/
  python tests/test_python_bindings.py

Or with pixi (after building the extension and wheel):
  pixi run python tests/test_python_bindings.py
"""
import os
import sys

# Ensure project root is on path for test data paths
_repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _repo_root not in sys.path:
    sys.path.insert(0, _repo_root)

import blazeseq

FASTQ_PATH = os.path.join(_repo_root, "tests", "test_data", "fastq_parser", "example.fastq")


def test_create_parser_and_next_record():
    """Loop with next_record until EOF; check first record id and sequence."""
    parser = blazeseq.create_parser(FASTQ_PATH, "generic")
    assert blazeseq.has_more(parser)

    count = 0
    while True:
        try:
            rec = blazeseq.next_record(parser)
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
    parser = blazeseq.create_parser(FASTQ_PATH, "generic")
    batch = blazeseq.next_batch(parser, 2)
    assert batch.num_records() == 2
    first = batch.get_record(0)
    assert first.id() == "EAS54_6_R1_2_1_413_324"
    second = batch.get_record(1)
    assert second.id() == "EAS54_6_R1_2_1_540_792"

    batch2 = blazeseq.next_batch(parser, 10)
    assert batch2.num_records() == 1
    assert batch2.get_record(0).id() == "EAS54_6_R1_2_1_443_348"


def test_eof_raises():
    """Calling next_record past EOF raises."""
    parser = blazeseq.create_parser(FASTQ_PATH, "generic")
    for _ in range(3):
        blazeseq.next_record(parser)
    try:
        blazeseq.next_record(parser)
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
