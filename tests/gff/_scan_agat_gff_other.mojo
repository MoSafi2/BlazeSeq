"""One-off scanner: which gff_other/in/*.gff fails Gff3Parser? Run: pixi run mojo run -I . -D ASSERT=all tests/gff/_scan_agat_gff_other.mojo"""

from blazeseq import Gff3Parser, FileReader
from std.pathlib import Path
from std.collections.string import String
import std.os

comptime agat_other = "tests/test_data/agat/gff_other/in/"


def main() raises:
    for name in std.os.listdir(agat_other):
        var sname = String(name)
        if not sname.endswith(".gff"):
            continue
        var full = agat_other + sname
        var n_ok: Int = 0
        try:
            var reader = FileReader(Path(full))
            var parser = Gff3Parser[FileReader](reader^)
            while parser.has_more():
                _ = parser.next_record()
                n_ok += 1
            print(String("OK ") + sname + String(" n=") + String(n_ok))
        except:
            print(String("FAIL ") + sname + String(" after n=") + String(n_ok))
