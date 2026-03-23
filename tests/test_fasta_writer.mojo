from std.testing import assert_equal, TestSuite
from std.collections.string import String

from blazeseq import FastaRecord


def _repeat(pattern: String, n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += pattern
    return s


def test_fasta_write_wraps_long_lines_default_width() raises:
    # 130 bases => 60 + 60 + 10 (each terminated by '\n')
    var seq = _repeat("ACGT", 32) + "AC"
    assert_equal(len(seq), 130)

    var rec = FastaRecord("id1", seq)
    var out = String()
    rec.write(out)  # default 60

    var expected = (
        ">id1\n"
        + seq[byte=0:60]
        + "\n"
        + seq[byte=60:120]
        + "\n"
        + seq[byte=120:]
        + "\n"
    )
    assert_equal(String(out), expected)


def test_fasta_write_exact_multiple_of_width() raises:
    # exactly 120 bases => 60 + 60 (with trailing '\n')
    var seq = _repeat("ACGT", 30)
    assert_equal(len(seq), 120)

    var rec = FastaRecord("id2", seq)
    var out = String()
    rec.write(out, line_width=60)

    var expected = ">id2\n" + seq[byte=0:60] + "\n" + seq[byte=60:] + "\n"
    assert_equal(String(out), expected)


def test_fasta_write_custom_small_width() raises:
    # 10 bases at width 4 => 4 + 4 + 2
    var seq = "ACGTACGTAA"
    var rec = FastaRecord("id3", seq)
    var out = String()
    rec.write(out, line_width=4)

    var expected = ">id3\nACGT\nACGT\nAA\n"
    assert_equal(String(out), expected)


def test_fasta_write_line_width_lte_zero_no_wrap() raises:
    # Treat non-positive widths as "no wrap" (single sequence line).
    var seq = _repeat("ACGT", 25)
    assert_equal(len(seq), 100)

    var rec = FastaRecord("id4", seq)
    var out0 = String()
    rec.write(out0, line_width=0)
    assert_equal(String(out0), ">id4\n" + seq + "\n")

    var outneg = String()
    rec.write(outneg, line_width=-1)
    assert_equal(String(outneg), ">id4\n" + seq + "\n")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

