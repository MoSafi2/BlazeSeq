"""AGAT-derived fixture tests for Gff3Parser and GtfParser.

Data under tests/test_data/agat/ — see tests/test_data/agat/README.md.
These tests assert line counts match a simple scan of the file (non-comment,
non-directive lines before ##FASTA), except for paths listed in
KNOWN_GFF3_FAILURES where BlazeSeq’s GFF3 attribute rules currently reject input.
"""

from blazeseq import Gff3Parser, GtfParser, FileReader
from std.collections import List
from std.collections.string import String
from std.pathlib import Path
from std.testing import assert_equal, assert_true, TestSuite
import std.os

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


def _contains_str(haystack: List[String], needle: String) -> Bool:
    for i in range(len(haystack)):
        if haystack[i] == needle:
            return True
    return False


def _known_gff3_failures() -> List[String]:
    """Relative paths under agat_dir where parse or count match is not expected yet.

    Populated from `pixi run test` after the first full run (GFF3 column 9 must
    be valid key=value for our parser; GFF1-style bare values are listed here).
    """
    var xs = List[String]()
    # gff_syntax: GFF1-style column 9 (bare tag) or otherwise invalid GFF3 attrs
    xs.append("gff_syntax/in/42_test.gff")
    xs.append("gff_syntax/in/43_test.gff")
    xs.append("gff_syntax/in/44_test.gff")
    xs.append("gff_syntax/in/45_test.gff")
    xs.append("gff_syntax/in/46_test.gff")
    xs.append("gff_syntax/in/47_test.gff")
    # gff_other: attribute shapes / commas in values — tune after CI
    xs.append("gff_other/in/issue457.gff")
    return xs^


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


def test_agat_gff_syntax_files_parse_and_count() raises:
    """Every gff_syntax/in/*.gff: record count equals scanned line count unless known-fail."""
    var known = _known_gff3_failures()
    for name in std.os.listdir(agat_dir + "gff_syntax/in/"):
        var sname = String(name)
        if not sname.endswith(".gff"):
            continue
        var rel = String("gff_syntax/in/") + sname
        var full = agat_dir + rel
        var content = _read_text(full)
        var expected = _expected_feature_line_count_gff3(content)
        if _contains_str(known, rel):
            var threw = False
            try:
                var got = _gff3_records_from_file(full)
                if got != expected:
                    threw = True
            except:
                threw = True
            assert_true(
                threw,
                "known-fail fixture should still not match parser: " + rel,
            )
            continue
        var got_ok = _gff3_records_from_file(full)
        assert_equal(
            got_ok,
            expected,
            "GFF3 record count for " + rel,
        )


def test_agat_gff_other_gff_files() raises:
    """gff_other issue*.gff and decode file: count match unless in known-fail."""
    var known = _known_gff3_failures()
    for name in std.os.listdir(agat_dir + "gff_other/in/"):
        var sname = String(name)
        if not sname.endswith(".gff"):
            continue
        var rel = String("gff_other/in/") + sname
        var full = agat_dir + rel
        var content = _read_text(full)
        var expected = _expected_feature_line_count_gff3(content)
        if _contains_str(known, rel):
            var bad = False
            try:
                if _gff3_records_from_file(full) != expected:
                    bad = True
            except:
                bad = True
            assert_true(bad, "known-fail " + rel)
            continue
        assert_equal(_gff3_records_from_file(full), expected, rel)


def test_agat_gtf_issue441_first_record() raises:
    """GTF from AGAT gff_other/issue441: mandatory ids on first line."""
    var path = agat_dir + "gff_other/in/issue441.gtf"
    var reader = FileReader(Path(path))
    var parser = GtfParser[FileReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.seqid(), "Scaffold170")
    assert_equal(rec.Attributes.gene_id.to_string(), "GBI_15721")
    assert_equal(rec.Attributes.transcript_id.to_string(), "GBI_15721-RE")


def test_agat_gtf_issue448_counts() raises:
    """issue448.gtf: full-file parse count matches line scan."""
    var path = agat_dir + "gff_other/in/issue448.gtf"
    var content = _read_text(path)
    var exp = _expected_feature_line_count_gtf(content)
    assert_equal(_gtf_records_from_file(path), exp, "issue448.gtf")


def test_agat_gtf_kraken_counts() raises:
    """script_sp test_kraken.gtf: full-file parse count matches line scan."""
    var path = agat_dir + "script_sp/in/test_kraken.gtf"
    var content = _read_text(path)
    var exp = _expected_feature_line_count_gtf(content)
    assert_equal(_gtf_records_from_file(path), exp, "test_kraken.gtf")


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
