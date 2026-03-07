"""Delimited text reader and writer.

This module provides a reader and writer for delimited text files.
"""

from blazeseq.io.readers import Reader
from blazeseq.io.writers import Writer
from blazeseq.io.buffered import BufferedReader, LineIterator
from blazeseq.utils import memchr

struct DelimReader[R: Reader]:
    """Reader for delimited text files."""

    var source: LineIterator[Self.R]

    fn __init__(out self, var reader: Self.R) raises:
        """Initialize the delimited reader."""
        self.source = LineIterator(reader^)


# From Extramojo to avoid version mismatch.
# should be finally used from extramojo if not modified and mojo stabilizes a bit.
struct SplitIterator[is_mutable: Bool, //, origin: Origin[mut=is_mutable]](
    Copyable, Movable
):
    """
    Get an iterator the yields the splits from the input `to_split` string.
    """

    var inner: Span[UInt8, Self.origin]
    var split_on: UInt8
    var current: Int
    var end_pos: Int

    fn __init__(out self, to_split: Span[UInt8, Self.origin], split_on: UInt8):
        self.inner = to_split
        self.split_on = split_on
        self.current = 0
        self.end_pos = len(self.inner)

    fn __iter__(var self) -> Self:
        return self^

    fn __next__(mut self) raises StopIteration -> Span[UInt8, Self.origin]:
        if self.current >= self.end_pos:
            raise StopIteration()

        var start = self.current
        var end = memchr(self.inner, self.split_on, self.current)

        if end != -1:
            self.current = end + 1
        else:
            end = self.end_pos
            self.current = self.end_pos + 1
        return self.inner[start : end]

    fn next(mut self) raises StopIteration -> Span[UInt8, Self.origin]:
        return self.__next__()


fn main() raises:
    var x = "ABCD\tEFGH\tIJKL\nMNOP\nQWERTY"
    var iter = SplitIterator(x.as_bytes(), ord("\t"))
    var i = 0
    for value in iter.copy():
        print(i, String(unsafe_from_utf8=value))
        i += 1