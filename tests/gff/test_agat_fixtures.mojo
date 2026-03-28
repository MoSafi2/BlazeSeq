"""AGAT-derived fixture tests for Gff3Parser and GtfParser.

Data under tests/test_data/agat/ — see tests/test_data/agat/README.md.

Expected outcomes (full parse with record count matching scanned non-comment data
lines before ##FASTA, except rows marked fail where we expect a parse error or a
count mismatch vs. that scan):

| Path | Format | Expected |
|------|--------|----------|
| gff_syntax/in/0_test.gff | GFF3 | success |
| gff_syntax/in/1_test.gff | GFF3 | success |
| gff_syntax/in/2_test.gff | GFF3 | success |
| gff_syntax/in/3_test.gff | GFF3 | success |
| gff_syntax/in/4_test.gff | GFF3 | success |
| gff_syntax/in/5_test.gff | GFF3 | success |
| gff_syntax/in/6_test.gff | GFF3 | success |
| gff_syntax/in/7_test.gff | GFF3 | success |
| gff_syntax/in/8_test.gff | GFF3 | success |
| gff_syntax/in/9_test.gff | GFF3 | success |
| gff_syntax/in/10_test.gff | GFF3 | success |
| gff_syntax/in/11_test.gff | GFF3 | success |
| gff_syntax/in/12_test.gff | GFF3 | success |
| gff_syntax/in/13_test.gff | GFF3 | success |
| gff_syntax/in/14_test.gff | GFF3 | success |
| gff_syntax/in/15_test.gff | GFF3 | success |
| gff_syntax/in/16_test.gff | GFF3 | success |
| gff_syntax/in/17_test.gff | GFF3 | success |
| gff_syntax/in/18_test.gff | GFF3 | success |
| gff_syntax/in/19_test.gff | GFF3 | success |
| gff_syntax/in/20_test.gff | GFF3 | success |
| gff_syntax/in/21_test.gff | GFF3 | success |
| gff_syntax/in/22_test.gff | GFF3 | success |
| gff_syntax/in/23_test.gff | GFF3 | success |
| gff_syntax/in/24_test.gff | GFF3 | success |
| gff_syntax/in/25_test.gff | GFF3 | success |
| gff_syntax/in/26_test.gff | GFF3 | success |
| gff_syntax/in/27_test.gff | GFF3 | success |
| gff_syntax/in/28_test.gff | GFF3 | fail |
| gff_syntax/in/29_test.gff | GFF3 | success |
| gff_syntax/in/30_test.gff | GFF3 | success |
| gff_syntax/in/31_test.gff | GFF3 | success |
| gff_syntax/in/32_test.gff | GFF3 | success |
| gff_syntax/in/33_test.gff | GFF3 | success |
| gff_syntax/in/34_test.gff | GFF3 | success |
| gff_syntax/in/35_test.gff | GFF3 | success |
| gff_syntax/in/36_test.gff | GFF3 | success |
| gff_syntax/in/37_test.gff | GFF3 | success |
| gff_syntax/in/38_test.gff | GFF3 | success |
| gff_syntax/in/39_test.gff | GFF3 | success |
| gff_syntax/in/40_test.gff | GFF3 | success |
| gff_syntax/in/41_test.gff | GFF3 | fail |
| gff_syntax/in/42_test.gff | GFF3 | success |
| gff_syntax/in/43_test.gff | GFF3 | fail |
| gff_syntax/in/44_test.gff | GFF3 | fail |
| gff_syntax/in/45_test.gff | GFF3 | success |
| gff_syntax/in/46_test.gff | GFF3 | success |
| gff_syntax/in/47_test.gff | GFF3 | fail |
| gff_other/in/decode_gff3urlescape.gff | GFF3 | success |
| gff_other/in/issue329.gff | GFF3 | success |
| gff_other/in/issue368.gff | GFF3 | success |
| gff_other/in/issue389.gff | GFF3 | fail |
| gff_other/in/issue441.gtf | GTF | success |
| gff_other/in/issue448.gtf | GTF | success |
| gff_other/in/issue457.gff | GFF3 | success |
| script_sp/in/test_kraken.gtf | GTF | success |
"""

from blazeseq import Gff3Parser, GtfParser, FileReader
from std.collections.string import String
from std.pathlib import Path
from std.testing import assert_equal, assert_true, TestSuite

comptime agat_dir = "tests/test_data/agat/"


def _read_text(path: String) raises -> String:
    var f = open(path, "r")
    var content = f.read()
    f.close()
    return content


def _expected_feature_line_count_gff3(content: String) -> Int:
    """Count data lines: non-empty, not #/## comment or directive, before ##FASTA."""
    var lines = content.split("\n")
    var n: Int = 0
    for line in lines:
        var s = String(line.strip())
        if len(s) == 0:
            continue
        if s.startswith("##FASTA"):
            break
        if s.startswith("#"):
            continue
        n += 1
    return n


def _expected_feature_line_count_gtf(content: String) -> Int:
    """GTF: skip blanks and # comments only."""
    var lines = content.split("\n")
    var n: Int = 0
    for line in lines:
        var s = String(line.strip())
        if len(s) == 0:
            continue
        if s.startswith("##FASTA"):
            break
        if s.startswith("#"):
            continue
        n += 1
    return n


def _gff3_records_from_file(path: String) raises -> Int:
    var reader = FileReader(Path(path))
    var parser = Gff3Parser[FileReader](reader^)
    var n: Int = 0
    while parser.has_more():
        _ = parser.next_record()
        n += 1
    return n


def _gtf_records_from_file(path: String) raises -> Int:
    var reader = FileReader(Path(path))
    var parser = GtfParser[FileReader](reader^)
    var n: Int = 0
    while parser.has_more():
        _ = parser.next_record()
        n += 1
    return n


def _agat_gff3_fixture(rel: String, expect_success: Bool) raises:
    """Assert full parse and line-count match (success) or non-matching outcome (fail)."""
    var full = agat_dir + rel
    var content = _read_text(full)
    var expected = _expected_feature_line_count_gff3(content)
    if expect_success:
        assert_equal(_gff3_records_from_file(full), expected, rel)
    else:
        var bad = False
        try:
            if _gff3_records_from_file(full) != expected:
                bad = True
        except:
            bad = True
        assert_true(bad, "expected parse failure or count mismatch: " + rel)


def _agat_gtf_fixture(rel: String) raises:
    """GTF fixtures: full parse; record count matches scanned data lines."""
    var full = agat_dir + rel
    var content = _read_text(full)
    var expected = _expected_feature_line_count_gtf(content)
    assert_equal(_gtf_records_from_file(full), expected, rel)



def test_agat_fixture_gff_syntax_in_0_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/0_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_1_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/1_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_2_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/2_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_3_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/3_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_4_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/4_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_5_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/5_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_6_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/6_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_7_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/7_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_8_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/8_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_9_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/9_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_10_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/10_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_11_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/11_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_12_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/12_test.gff", expect_success=False)

def test_agat_fixture_gff_syntax_in_13_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/13_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_14_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/14_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_15_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/15_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_16_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/16_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_17_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/17_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_18_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/18_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_19_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/19_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_20_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/20_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_21_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/21_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_22_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/22_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_23_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/23_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_24_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/24_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_25_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/25_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_26_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/26_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_27_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/27_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_28_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/28_test.gff", expect_success=False)

def test_agat_fixture_gff_syntax_in_29_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/29_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_30_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/30_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_31_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/31_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_32_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/32_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_33_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/33_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_34_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/34_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_35_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/35_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_36_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/36_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_37_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/37_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_38_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/38_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_39_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/39_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_40_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/40_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_41_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/41_test.gff", expect_success=False)

def test_agat_fixture_gff_syntax_in_42_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/42_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_43_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/43_test.gff", expect_success=False)

def test_agat_fixture_gff_syntax_in_44_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/44_test.gff", expect_success=False)

def test_agat_fixture_gff_syntax_in_45_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/45_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_46_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/46_test.gff", expect_success=True)

def test_agat_fixture_gff_syntax_in_47_test_gff() raises:
    _agat_gff3_fixture("gff_syntax/in/47_test.gff", expect_success=False)

def test_agat_fixture_gff_other_in_decode_gff3urlescape_gff() raises:
    _agat_gff3_fixture("gff_other/in/decode_gff3urlescape.gff", expect_success=True)

def test_agat_fixture_gff_other_in_issue329_gff() raises:
    _agat_gff3_fixture("gff_other/in/issue329.gff", expect_success=True)

def test_agat_fixture_gff_other_in_issue368_gff() raises:
    _agat_gff3_fixture("gff_other/in/issue368.gff", expect_success=True)

def test_agat_fixture_gff_other_in_issue389_gff() raises:
    _agat_gff3_fixture("gff_other/in/issue389.gff", expect_success=False)

def test_agat_fixture_gff_other_in_issue441_gtf() raises:
    _agat_gtf_fixture("gff_other/in/issue441.gtf")

def test_agat_fixture_gff_other_in_issue448_gtf() raises:
    _agat_gtf_fixture("gff_other/in/issue448.gtf")

def test_agat_fixture_gff_other_in_issue457_gff() raises:
    _agat_gff3_fixture("gff_other/in/issue457.gff", expect_success=True)

def test_agat_fixture_script_sp_in_test_kraken_gtf() raises:
    _agat_gtf_fixture("script_sp/in/test_kraken.gtf")



def test_agat_gtf_issue441_first_record() raises:
    """GTF from AGAT gff_other/issue441: mandatory ids on first line."""
    var path = agat_dir + "gff_other/in/issue441.gtf"
    var reader = FileReader(Path(path))
    var parser = GtfParser[FileReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.seqid(), "Scaffold170")
    assert_equal(rec.Attributes.gene_id.to_string(), "GBI_15721")
    assert_equal(rec.Attributes.transcript_id.to_string(), "GBI_15721-RE")


def test_agat_gff_syntax_0_first_record_fields() raises:
    """Sanity check on 0_test.gff first feature line."""
    var path = agat_dir + "gff_syntax/in/0_test.gff"
    var reader = FileReader(Path(path))
    var parser = Gff3Parser[FileReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.seqid(), "scaffold625")
    assert_equal(rec.feature_type(), "gene")
    assert_equal(rec.Start, 337818)
    assert_equal(rec.End, 343277)


def test_agat_gtf_issue448_first_record_fields() raises:
    """Issue448.gtf: first line gene coordinates and ids (pipes in attribute values)."""
    var path = agat_dir + "gff_other/in/issue448.gtf"
    var reader = FileReader(Path(path))
    var parser = GtfParser[FileReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.seqid(), "chr10p")
    assert_equal(rec.feature_type(), "gene")
    assert_equal(rec.Start, 697815)
    assert_equal(rec.End, 769805)
    assert_equal(rec.Attributes.gene_id.to_string(), "AMEX60DD000004")


def test_agat_gtf_kraken_first_record_fields() raises:
    """Test_kraken.gtf: first feature mRNA with Kraken_mapped attribute."""
    var path = agat_dir + "script_sp/in/test_kraken.gtf"
    var reader = FileReader(Path(path))
    var parser = GtfParser[FileReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.seqid(), "DS544898.1")
    assert_equal(rec.feature_type(), "mRNA")
    assert_equal(rec.Attributes.gene_id.to_string(), "PP1S9_164V6")
    assert_equal(rec.Attributes.transcript_id.to_string(), "PP1S9_164V6.1")
    var km = rec.get_attribute("Kraken_mapped")
    assert_true(km)
    assert_equal(km.value().to_string(), "FALSE")


def test_agat_issue368_gff_empty_seqid_first_gene() raises:
    """Issue368.gff: AGAT issue with leading tab — empty seqid on first features."""
    var path = agat_dir + "gff_other/in/issue368.gff"
    var reader = FileReader(Path(path))
    var parser = Gff3Parser[FileReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.seqid(), "")
    assert_equal(rec.feature_type(), "gene")
    assert_equal(rec.Start, 337818)
    var id_attr = rec.get_attribute("ID")
    assert_true(id_attr)
    assert_equal(id_attr.value().to_string(), "CLUHARG00000005458")


def test_agat_decode_gff3urlescape_gene_synonym_percent_decoded() raises:
    """Decode_gff3urlescape.gff: %3B in gene_synonym becomes ';' after percent-decode."""
    var path = agat_dir + "gff_other/in/decode_gff3urlescape.gff"
    var reader = FileReader(Path(path))
    var parser = Gff3Parser[FileReader](reader^)
    while parser.has_more():
        var rec = parser.next_record()
        var syn = rec.get_attribute("gene_synonym")
        if syn:
            assert_equal(syn.value().to_string(), "F6F3.24; F6F3_24")
            return
    assert_true(False, "expected a feature with gene_synonym")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()

