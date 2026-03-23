"""Correctness tests for FastaParser using Biopython SeqIO FASTA test files.

Test data from Biopython Tests/Fasta (SeqIO-style and .pro / .nu files).
URL: https://github.com/biopython/biopython/tree/master/Tests/Fasta
"""

from blazeseq import FastaParser, FastaRecord, FileReader
from std.pathlib import Path
from std.testing import assert_equal, assert_true, TestSuite
from std.collections import List

comptime test_dir = "tests/test_data/fasta_parser/"


def _parse_fasta_file(path: String) raises -> List[FastaRecord]:
    """Parse a FASTA file and return a list of owned records."""
    var reader = FileReader(Path(path))
    var parser = FastaParser[FileReader](reader^)
    var records = List[FastaRecord]()
    for rec in parser:
        records.append(rec.copy())
    return records^


# ─── SeqIO-style files (f001, f002, f003.fa, fa01) ───


def test_biopython_f001() raises:
    """Biopython f001: 1 protein sequence; long definition line."""
    var records = _parse_fasta_file(test_dir + "f001")
    assert_equal(len(records), 1, "f001 should have 1 record")
    var id_str = String(records[0].id())
    assert_true(
        id_str.find("gi|3318709|pdb|1A91|") >= 0,
        "id should contain gi|3318709|pdb|1A91|",
    )
    assert_equal(
        String(records[0].sequence()),
        "MENLNMDLLYMAAAVMMGLAAIGAAIGIGILGGKFLEGAARQPDLIPLLRTQFFIVMGLVDAIPMIAVGLGLYVMFAVA",
        "sequence should be normalized (no newlines)",
    )


def test_biopython_f002() raises:
    """Biopython f002: 3 DNA sequences; multi-line sequences."""
    var records = _parse_fasta_file(test_dir + "f002")
    assert_equal(len(records), 3, "f002 should have 3 records")
    var id0 = String(records[0].id())
    var id2 = String(records[2].id())
    assert_true(id0.find("gi|1348912|gb|G26680|") >= 0, "first id")
    assert_true(id2.find("gi|1592936|gb|G29385|") >= 0, "last id")
    var seq0 = String(records[0].sequence())
    assert_true(
        seq0.find("CGGACCAGACGGACACAGGGAGAAGCTAGTTTCTTTCATGTGATTGA") >= 0,
        "first sequence start",
    )
    assert_true(len(seq0) > 100, "first sequence concatenated")


def test_biopython_f003_fa() raises:
    """Biopython f003.fa: 2 proteins with comments."""
    var records = _parse_fasta_file(test_dir + "f003.fa")
    assert_equal(len(records), 2, "f003.fa should have 2 records")
    assert_equal(String(records[0].id()), "gi|3318709|pdb|1A91|", "first id")
    assert_equal(String(records[1].id()), "gi|whatever|whatever", "second id")
    assert_equal(
        String(records[0].sequence()),
        "MENLNMDLLYMAAAVMMGLAAIGAAIGIGILGGKFLEGAARQPDLIPLLRTQFFIVMGLVDAIPMIAVGLGLYVMFAVA",
        "first sequence",
    )
    assert_equal(
        String(records[1].sequence()),
        "MENLNMDLLYMAAAVMMGLAAIGAAIGIGILGG",
        "second sequence",
    )


def test_biopython_fa01() raises:
    """Biopython fa01: 2 aligned sequences with gap characters."""
    var records = _parse_fasta_file(test_dir + "fa01")
    assert_equal(len(records), 2, "fa01 should have 2 records")
    assert_equal(String(records[0].id()), "AK1H_ECOLI/1-378", "first id")
    assert_equal(String(records[1].id()), "AKH_HAEIN/1-382", "second id")
    var seq0 = String(records[0].sequence())
    var seq1 = String(records[1].sequence())
    assert_true(seq0.find("-") >= 0, "first sequence should contain gaps")
    assert_true(seq1.find("-") >= 0, "second sequence should contain gaps")
    assert_true(
        seq0.find("CPDSINAALICRGEKMSIAIMAGVLEARGH") >= 0,
        "first sequence content",
    )
    assert_true(
        seq1.find("VEDAVKATIDCRGEKLSIAMMKAWFEARGY") >= 0,
        "second sequence content",
    )


# ─── Protein (.pro) files (standard FASTA; exclude those with leading comments) ───


def test_biopython_pro_aster() raises:
    """Biopython aster.pro: single protein record."""
    var records = _parse_fasta_file(test_dir + "aster.pro")
    assert_true(len(records) >= 1, "aster.pro should have at least 1 record")
    assert_true(len(String(records[0].id())) > 0, "first id non-empty")
    assert_true(
        len(String(records[0].sequence())) > 0, "first sequence non-empty"
    )
    assert_true(
        String(records[0].id()).find("gi|3298468|dbj|BAA31520.1|") >= 0,
        "id should contain gi|3298468|dbj|BAA31520.1|",
    )


def test_biopython_pro_aster_no_wrap() raises:
    """Biopython aster_no_wrap.pro: single line sequence."""
    var records = _parse_fasta_file(test_dir + "aster_no_wrap.pro")
    assert_true(
        len(records) >= 1, "aster_no_wrap.pro should have at least 1 record"
    )
    assert_true(len(String(records[0].sequence())) > 0, "sequence non-empty")


def test_biopython_pro_loveliesbleeding() raises:
    """Biopython loveliesbleeding.pro: single protein record."""
    var records = _parse_fasta_file(test_dir + "loveliesbleeding.pro")
    assert_true(
        len(records) >= 1, "loveliesbleeding.pro should have at least 1 record"
    )
    assert_true(String(records[0].id()).find("gi|2781234|pdb|1JLY|") >= 0, "id")


def test_biopython_pro_rose() raises:
    """Biopython rose.pro: single protein; spot-check id prefix."""
    var records = _parse_fasta_file(test_dir + "rose.pro")
    assert_true(len(records) >= 1, "rose.pro should have at least 1 record")
    assert_true(
        String(records[0].id()).find("gi|4959044|gb|AAD34209.1|") >= 0,
        "id should contain gi|4959044|gb|AAD34209.1|",
    )
    assert_true(
        String(records[0].sequence()).find(
            "MENSDSNDKGSDQSAAQRRSQMDRLDREEAFYQFVNNLSEEDYRLMRDNNLLGTPGESTEEELLRRLQQI"
        )
        >= 0,
        "sequence start",
    )


def test_biopython_pro_rosemary() raises:
    """Biopython rosemary.pro: single protein (rubisco large subunit)."""
    var records = _parse_fasta_file(test_dir + "rosemary.pro")
    assert_true(len(records) >= 1, "rosemary.pro should have at least 1 record")
    assert_true(
        String(records[0].id()).find("gi|671626|emb|CAA85685.1|") >= 0, "id"
    )
    assert_true(
        String(records[0].sequence()).find(
            "MSPQTETKASVGFKAGVKEYKLTYYTPEYETKDTDILAAFRVTPQPGVPPEEAGAAVAAESSTGTWTTVW"
        )
        >= 0,
        "sequence start",
    )


# ─── Nucleotide (.nu) files ───


def test_biopython_nu_centaurea() raises:
    """Biopython centaurea.nu: single nucleotide record."""
    var records = _parse_fasta_file(test_dir + "centaurea.nu")
    assert_true(len(records) >= 1, "centaurea.nu should have at least 1 record")
    assert_true(len(String(records[0].id())) > 0, "id non-empty")
    assert_true(len(String(records[0].sequence())) > 0, "sequence non-empty")


def test_biopython_nu_elderberry() raises:
    """Biopython elderberry.nu: single nucleotide record."""
    var records = _parse_fasta_file(test_dir + "elderberry.nu")
    assert_true(
        len(records) >= 1, "elderberry.nu should have at least 1 record"
    )
    assert_true(
        String(records[0].sequence()).find(
            "ATGAAGTTAAGCACTCTTCTCATCTTATCTTTTCCTTTCCTGCTCGGTACTATTGTCTTTGCAGATGATG"
        )
        >= 0,
        "sequence start",
    )


def test_biopython_nu_lavender() raises:
    """Biopython lavender.nu: single nucleotide record."""
    var records = _parse_fasta_file(test_dir + "lavender.nu")
    assert_true(len(records) >= 1, "lavender.nu should have at least 1 record")
    assert_true(len(String(records[0].sequence())) > 0, "sequence non-empty")


def test_biopython_nu_lupine() raises:
    """Biopython lupine.nu: single nucleotide; sequence starts with known prefix.
    """
    var records = _parse_fasta_file(test_dir + "lupine.nu")
    assert_true(len(records) >= 1, "lupine.nu should have at least 1 record")
    assert_true(
        String(records[0].sequence()).find("GAAAATTCATTTTCTTTGG") >= 0,
        "sequence should start with GAAAATTCATTTTCTTTGG...",
    )


def test_biopython_nu_phlox() raises:
    """Biopython phlox.nu: single nucleotide record."""
    var records = _parse_fasta_file(test_dir + "phlox.nu")
    assert_true(len(records) >= 1, "phlox.nu should have at least 1 record")
    assert_true(
        String(records[0].sequence()).find(
            "TCGAAACCTGCCTAGCAGAACGACCCGCGAACTTGTATTCAAAACTTGGGTTGTGCGTGCTTCTGCTTCG"
        )
        >= 0,
        "sequence start",
    )


def test_biopython_nu_sweetpea() raises:
    """Biopython sweetpea.nu: single nucleotide record."""
    var records = _parse_fasta_file(test_dir + "sweetpea.nu")
    assert_true(len(records) >= 1, "sweetpea.nu should have at least 1 record")
    assert_true(len(String(records[0].sequence())) > 0, "sequence non-empty")


def test_biopython_nu_wisteria() raises:
    """Biopython wisteria.nu: single nucleotide record."""
    var records = _parse_fasta_file(test_dir + "wisteria.nu")
    assert_true(len(records) >= 1, "wisteria.nu should have at least 1 record")
    assert_true(
        String(records[0].sequence()).find(
            "GCTCCATTTTTTACACATTTCTATGAACTAATTGGTTCATCCATACCATCGGTAGGGTTTGTAAGACCAC"
        )
        >= 0,
        "sequence start",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
