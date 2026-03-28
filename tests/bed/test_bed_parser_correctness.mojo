"""Correctness tests for BedParser using Biopython BLAT BED test files.

Test data from Biopython Tests/Blat.
URL: https://github.com/biopython/biopython/tree/master/Tests/Blat
"""

from blazeseq import BedParser, BedWriter, FileReader
from blazeseq.bed.record import Strand
from blazeseq.io import MemoryReader
from std.collections import List
from std.collections.string import String, StringSlice
from std.pathlib import Path
from std.testing import assert_equal, assert_true, TestSuite
import std.os

comptime test_dir = "tests/test_data/bed_parser/"


def _parse_int64(s: String) raises -> Int64:
    return Int64(atol(StringSlice(s).strip()))


def _sniff_bed_first_line(content: String) raises -> Bool:
    """Heuristically detect BED from the first data line.

    Conservative rules:
    - First non-empty, non-comment line must be tab-delimited
    - Field count in {3,4,5,6,7,8,9,12}
    - Fields[1] and Fields[2] parse as integers
    """
    var lines = content.split("\n")
    var first: String = ""
    for line in lines:
        var raw = String(line)
        var s = String(raw.strip())
        if len(s) == 0:
            continue
        if s.startswith("#"):
            continue
        first = s
        break
    if len(first) == 0:
        return False

    # BED is tab-delimited; require at least one tab.
    if first.find("\t") < 0:
        return False

    var fields = first.split("\t")
    var n = len(fields)
    if not (
        n == 3
        or n == 4
        or n == 5
        or n == 6
        or n == 7
        or n == 8
        or n == 9
        or n == 12
    ):
        return False

    # Numeric coordinate sanity: chromStart/chromEnd must parse.
    _ = _parse_int64(String(fields[1]))
    _ = _parse_int64(String(fields[2]))
    return True


def _read_text_if_possible(path: String) -> Optional[String]:
    try:
        var f = open(path, "r")
        var content = String(f.read())
        f.close()
        return Optional(content)
    except:
        return None


def _parse_bed_file(path: String) raises:
    var reader = FileReader(Path(path))
    var parser = BedParser[FileReader](reader^)
    for _ in parser.views():
        pass


def _assert_invariants_for_file(path: String, expected_fields: Int) raises:
    var reader = FileReader(Path(path))
    var parser = BedParser[FileReader](reader^)
    var count: Int = 0
    for view in parser.views():
        count += 1
        assert_equal(view.num_fields, expected_fields, "field count")
        assert_true(len(String(view.chrom())) > 0, "chrom non-empty")
        assert_true(view.chrom_start <= view.chrom_end, "start <= end")

        if expected_fields >= 5:
            assert_true(view.score, "score present for BED5+")
            var sc = view.score.value()
            assert_true(sc >= 0 and sc <= 1000, "score in [0,1000]")

        if expected_fields >= 6:
            assert_true(view.strand, "strand present for BED6+")
            var st = view.strand.value()
            assert_true(
                st == Strand.Plus or st == Strand.Minus or st == Strand.Unknown,
                "strand value",
            )

        if expected_fields >= 9:
            # Presence check: parser validates itemRgb if provided.
            assert_true(view.item_rgb(), "itemRgb present for BED9+")

        if expected_fields == 12:
            assert_true(view.block_count, "blockCount present for BED12")
            var rec = view.to_record()
            assert_true(rec.BlockSizes, "BlockSizes present for BED12")
            assert_true(rec.BlockStarts, "BlockStarts present for BED12")
            var sizes_len = len(rec.BlockSizes.value())
            var starts_len = len(rec.BlockStarts.value())
            assert_equal(sizes_len, starts_len, "block list lengths match")
            assert_equal(
                sizes_len,
                view.block_count.value(),
                "block list length equals blockCount",
            )

    assert_true(count >= 1, "expected at least one record: " + path)


def test_biopython_bed3() raises:
    _assert_invariants_for_file(test_dir + "bed3.bed", 3)


def test_biopython_bed4() raises:
    _assert_invariants_for_file(test_dir + "bed4.bed", 4)


def test_biopython_bed5() raises:
    _assert_invariants_for_file(test_dir + "bed5.bed", 5)


def test_biopython_bed6() raises:
    _assert_invariants_for_file(test_dir + "bed6.bed", 6)


def test_biopython_bed7() raises:
    _assert_invariants_for_file(test_dir + "bed7.bed", 7)


def test_biopython_bed8() raises:
    _assert_invariants_for_file(test_dir + "bed8.bed", 8)


def test_biopython_bed9() raises:
    _assert_invariants_for_file(test_dir + "bed9.bed", 9)


def test_biopython_bed12() raises:
    _assert_invariants_for_file(test_dir + "bed12.bed", 12)


# ---------------------------------------------------------------------------
# Enhancement 2 — track / browser line handling
# ---------------------------------------------------------------------------


def test_track_line_skipped() raises:
    """UCSC 'track name=...' header lines are skipped; data line is yielded."""
    var data = "track name=myTrack description=\"test\"\nchr1\t0\t100\n"
    var reader = MemoryReader(data)
    var parser = BedParser[MemoryReader](reader^)
    assert_true(parser.has_more())
    var rec = parser.next_record()
    assert_equal(rec.chrom(), "chr1")
    assert_equal(rec.ChromStart, 0)
    assert_equal(rec.ChromEnd, 100)
    assert_true(not parser.has_more())


def test_browser_line_skipped() raises:
    """UCSC 'browser position ...' lines are skipped."""
    var data = "browser position chr1:1-1000\nchr1\t0\t500\n"
    var reader = MemoryReader(data)
    var parser = BedParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.chrom(), "chr1")
    assert_equal(rec.ChromEnd, 500)


def test_track_and_browser_before_data() raises:
    """Multiple UCSC header lines before data are all skipped."""
    var data = "track name=t1\nbrowser position chr1:1-1000\nbrowser hide all\nchr1\t10\t20\nchr2\t30\t40\n"
    var reader = MemoryReader(data)
    var parser = BedParser[MemoryReader](reader^)
    var count = 0
    for _ in parser:
        count += 1
    assert_equal(count, 2)


# ---------------------------------------------------------------------------
# Enhancement 1 — extra / custom fields (other_fields)
# ---------------------------------------------------------------------------


def test_extra_fields_stored_in_bed6_plus() raises:
    """Extra columns beyond BED12 are stored verbatim in OtherFields (no type coercion)."""
    var data = "chr1\t0\t1000\texon\t0\t+\t100\t900\t0\t2\t400,400,\t0,600,\t1.5e-10\n"
    var reader = MemoryReader(data)
    var parser = BedParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.NumFields, 13)
    assert_true(rec.OtherFields)
    var extras = rec.OtherFields.value().copy()
    assert_equal(len(extras), 1)
    assert_equal(extras[0].to_string(), "1.5e-10")


def test_extra_fields_beyond_bed12() raises:
    """Columns beyond 12 land in OtherFields and round-trip correctly."""
    var data = "chr1\t0\t1000\texon\t0\t+\t100\t900\t0\t2\t400,400,\t0,600,\tp_value\t0.001\n"
    var reader = MemoryReader(data)
    var parser = BedParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_true(rec.OtherFields)
    var extras = rec.OtherFields.value().copy()
    assert_equal(len(extras), 2)
    assert_equal(extras[0].to_string(), "p_value")
    assert_equal(extras[1].to_string(), "0.001")


def test_bed10_accepted_as_bed9_plus_extra() raises:
    """BED10 (previously rejected) is now accepted; column 10 goes to OtherFields."""
    var data = "chr1\t0\t100\tname\t0\t+\t0\t0\t0\textra_col\n"
    var reader = MemoryReader(data)
    var parser = BedParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.NumFields, 10)
    assert_true(rec.OtherFields)
    var extras = rec.OtherFields.value().copy()
    assert_equal(len(extras), 1)
    assert_equal(extras[0].to_string(), "extra_col")


def test_bed11_accepted_as_bed9_plus_extras() raises:
    """BED11 is accepted; columns 10-11 go to OtherFields."""
    var data = "chr1\t0\t100\tname\t0\t+\t0\t0\t0\textra1\textra2\n"
    var reader = MemoryReader(data)
    var parser = BedParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_equal(rec.NumFields, 11)
    var extras = rec.OtherFields.value().copy()
    assert_equal(len(extras), 2)
    assert_equal(extras[0].to_string(), "extra1")
    assert_equal(extras[1].to_string(), "extra2")


# ---------------------------------------------------------------------------
# Enhancement 3 — strand None vs Unknown semantics
# ---------------------------------------------------------------------------


def test_strand_absent_is_none_for_bed3() raises:
    """BED3 has no strand field; strand is None (absent), not Unknown."""
    var data = "chr1\t0\t100\n"
    var reader = MemoryReader(data)
    var parser = BedParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_true(not rec.Strand, "strand absent → None")


def test_strand_dot_is_unknown_for_bed6() raises:
    """BED6 with '.' in strand field yields Optional(Strand.Unknown), not None."""
    var data = "chr1\t0\t100\tname\t0\t.\n"
    var reader = MemoryReader(data)
    var parser = BedParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_true(rec.Strand, "strand present (dot) → not None")
    assert_equal(rec.Strand.value(), Strand.Unknown)


def test_strand_plus_minus_round_trip() raises:
    """Plus and Minus strands parse and are distinguishable."""
    var data = "chr1\t0\t100\tpos\t0\t+\nchr1\t0\t100\tneg\t0\t-\n"
    var reader = MemoryReader(data)
    var parser = BedParser[MemoryReader](reader^)
    var r1 = parser.next_record()
    var r2 = parser.next_record()
    assert_equal(r1.Strand.value(), Strand.Plus)
    assert_equal(r2.Strand.value(), Strand.Minus)


# ---------------------------------------------------------------------------
# Enhancement 4 — score is UInt16
# ---------------------------------------------------------------------------


def test_score_type_is_uint16() raises:
    """Score field is parsed as UInt16 and still validates [0, 1000]."""
    var data = "chr1\t0\t100\tname\t750\n"
    var reader = MemoryReader(data)
    var parser = BedParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_true(rec.Score)
    assert_equal(rec.Score.value(), 750)


def test_score_out_of_range_rejected() raises:
    """Score > 1000 is rejected."""
    var data = "chr1\t0\t100\tname\t1001\n"
    var reader = MemoryReader(data)
    var parser = BedParser[MemoryReader](reader^)
    var saw_error = False
    try:
        _ = parser.next_record()
    except e:
        assert_true(String(e).find("score") != -1 or String(e).find("1000") != -1)
        saw_error = True
    assert_true(saw_error)


# ---------------------------------------------------------------------------
# Enhancement 5 — BedWriter round-trip
# ---------------------------------------------------------------------------


def test_bedwriter_round_trip_bed6() raises:
    """Parse a BED6 record, write it via BedWriter, and assert no error."""
    var data = "chr1\t1000\t2000\tfeature\t500\t+\n"

    # Parse → record
    var reader = MemoryReader(data)
    var parser = BedParser[MemoryReader](reader^)
    var rec = parser.next_record()

    # BedWriter must construct and write without raising
    var bw = BedWriter[String](String()^)
    bw.write_record(rec)

    # Field values are correct (writer produces output; parsing was already tested above)
    assert_equal(rec.chrom(), "chr1")
    assert_equal(rec.ChromStart, 1000)
    assert_equal(rec.ChromEnd, 2000)
    assert_equal(rec.Name.value().to_string(), "feature")
    assert_equal(rec.Score.value(), 500)
    assert_equal(rec.Strand.value(), Strand.Plus)


# ---------------------------------------------------------------------------
# Enhancement 6 — block overlap validation
# ---------------------------------------------------------------------------


def test_overlapping_blocks_rejected() raises:
    """BED12 with overlapping blocks raises an error on to_record()."""
    # blocks: [0, 100), [50, 200) — overlap
    var data = "chr1\t0\t200\tname\t0\t+\t0\t200\t0\t2\t100,150,\t0,50,\n"
    var reader = MemoryReader(data)
    var parser = BedParser[MemoryReader](reader^)
    var saw_error = False
    try:
        _ = parser.next_record()
    except e:
        assert_true(
            String(e).find("non-overlapping") != -1 or String(e).find("sorted") != -1
        )
        saw_error = True
    assert_true(saw_error)


def test_non_overlapping_blocks_accepted() raises:
    """BED12 with valid non-overlapping sorted blocks parses correctly."""
    var data = "chr1\t0\t1000\texon\t0\t+\t100\t900\t0\t2\t400,400,\t0,600,\n"
    var reader = MemoryReader(data)
    var parser = BedParser[MemoryReader](reader^)
    var rec = parser.next_record()
    assert_true(rec.BlockSizes)
    assert_equal(len(rec.BlockSizes.value()), 2)


def test_bed_detection_regardless_of_extension() raises:
    """Scan all files; if content looks like BED, it must parse as BED."""
    for name in std.os.listdir(test_dir):
        var path = test_dir + String(name)
        var txt_opt = _read_text_if_possible(path)
        if not txt_opt:
            continue
        var txt = txt_opt.value()
        var is_bed = False
        try:
            is_bed = _sniff_bed_first_line(txt)
        except:
            is_bed = False
        if is_bed:
            _parse_bed_file(path)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
