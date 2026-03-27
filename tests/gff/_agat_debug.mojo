from blazeseq import Gff3Parser, FileReader
from std.pathlib import Path


def main() raises:
    var path = Path("tests/test_data/agat/gff_syntax/in/0_test.gff")
    var reader = FileReader(path)
    print("reader ok")
    var parser = Gff3Parser[FileReader](reader^)
    print("parser ok")
    var n: Int = 0
    while parser.has_more():
        _ = parser.next_record()
        n += 1
    print("records", n)
