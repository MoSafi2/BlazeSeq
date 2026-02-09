from blazeseq.iostream import LineIterator
from blazeseq.readers import FileReader
from pathlib import Path
from sys import argv


fn span_to_string(span: Span[Byte, MutExternalOrigin]) -> String:
    """Convert a span to a string for comparison."""
    return String(StringSlice(unsafe_from_utf8=span))


fn main() raises:
    var file_path = argv()[1]
    var reader = FileReader(Path(file_path))
    var line_iter = LineIterator(reader^)
    for line in line_iter:
        print(span_to_string(line))
