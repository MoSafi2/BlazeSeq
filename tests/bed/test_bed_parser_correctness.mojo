"""Correctness tests for BedParser using Biopython BLAT BED test files.

Test data from Biopython Tests/Blat.
URL: https://github.com/biopython/biopython/tree/master/Tests/Blat
"""

from blazeseq import BedParser, FileReader
from blazeseq.bed.record import Strand
from std.collections import List
from std.collections.string import String, StringSlice
from std.pathlib import Path
from std.testing import assert_equal, assert_true, TestSuite
import std.os

comptime test_dir = "tests/test_data/bed_parser/"


fn _parse_int64(s: String) raises -> Int64:
    return Int64(atol(StringSlice(s).strip()))


fn _sniff_bed_first_line(content: String) raises -> Bool:
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


fn _read_text_if_possible(path: String) -> Optional[String]:
    try:
        var f = open(path, "r")
        var content = String(f.read())
        f.close()
        return Optional(content)
    except:
        return None


fn _parse_bed_file(path: String) raises:
    var reader = FileReader(Path(path))
    var parser = BedParser[FileReader](reader^)
    for _ in parser.views():
        pass


fn _assert_invariants_for_file(path: String, expected_fields: Int) raises:
    var reader = FileReader(Path(path))
    var parser = BedParser[FileReader](reader^)
    var count: Int = 0
    for view in parser.views():
        count += 1
        assert_equal(view.num_fields(), expected_fields, "field count")
        assert_true(len(String(view.chrom())) > 0, "chrom non-empty")
        assert_true(view.chrom_start() <= view.chrom_end(), "start <= end")

        if expected_fields >= 5:
            assert_true(view.score(), "score present for BED5+")
            var sc = view.score().value()
            assert_true(sc >= 0 and sc <= 1000, "score in [0,1000]")

        if expected_fields >= 6:
            assert_true(view.strand(), "strand present for BED6+")
            var st = view.strand().value()
            assert_true(
                st == Strand.Plus or st == Strand.Minus or st == Strand.Unknown,
                "strand value",
            )

        if expected_fields >= 9:
            # Presence check: parser validates itemRgb if provided.
            assert_true(view.item_rgb(), "itemRgb present for BED9+")

        if expected_fields == 12:
            assert_true(view.block_count(), "blockCount present for BED12")
            var rec = view.to_record()
            assert_true(rec.BlockSizes, "BlockSizes present for BED12")
            assert_true(rec.BlockStarts, "BlockStarts present for BED12")
            var sizes_len = len(rec.BlockSizes.value())
            var starts_len = len(rec.BlockStarts.value())
            assert_equal(sizes_len, starts_len, "block list lengths match")
            assert_equal(
                sizes_len,
                view.block_count().value(),
                "block list length equals blockCount",
            )

    assert_true(count >= 1, "expected at least one record: " + path)


fn test_biopython_bed3() raises:
    _assert_invariants_for_file(test_dir + "bed3.bed", 3)


fn test_biopython_bed4() raises:
    _assert_invariants_for_file(test_dir + "bed4.bed", 4)


fn test_biopython_bed5() raises:
    _assert_invariants_for_file(test_dir + "bed5.bed", 5)


fn test_biopython_bed6() raises:
    _assert_invariants_for_file(test_dir + "bed6.bed", 6)


fn test_biopython_bed7() raises:
    _assert_invariants_for_file(test_dir + "bed7.bed", 7)


fn test_biopython_bed8() raises:
    _assert_invariants_for_file(test_dir + "bed8.bed", 8)


fn test_biopython_bed9() raises:
    _assert_invariants_for_file(test_dir + "bed9.bed", 9)


fn test_biopython_bed12() raises:
    _assert_invariants_for_file(test_dir + "bed12.bed", 12)


fn test_bed_detection_regardless_of_extension() raises:
    """Scan all files; if content looks like BED, it must parse as BED."""
    for name in os.listdir(test_dir):
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


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
