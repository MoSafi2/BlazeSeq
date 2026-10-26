"""Records hash the same sequence bytes used by their equality contract."""

from blazeseq import FastqRecord, FastaRecord
from std.testing import assert_equal, TestSuite


def test_fastq_hash_ignores_identifier_and_quality() raises:
    var a = FastqRecord("first", "ACGTN", "!!!!!")
    var b = FastqRecord("second", "ACGTN", "IIIII")
    assert_equal(a, b)
    assert_equal(hash(a), hash(b))
    var records = Dict[FastqRecord, Int]()
    records[a.copy()] = 42
    assert_equal(records[b], 42)


def test_fasta_hash_ignores_identifier() raises:
    var a = FastaRecord("first", "ACGTN")
    var b = FastaRecord("second", "ACGTN")
    assert_equal(a, b)
    assert_equal(hash(a), hash(b))
    var records = Dict[FastaRecord, Int]()
    records[a.copy()] = 42
    assert_equal(records[b], 42)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
