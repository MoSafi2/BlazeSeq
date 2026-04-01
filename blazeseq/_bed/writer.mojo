"""BED writer — symmetric counterpart to BedParser.

BedWriter[W] wraps any movable Writer and serialises BedRecord / BedView
values as tab-delimited BED lines, preserving the original column count.
"""

from blazeseq.bed.record import BedRecord, BedView
from blazeseq.io.writers import Writer


struct BedWriter[W: Writer & Movable](Movable):
    """Streaming BED writer.

    Wraps a Writer and provides record-level write methods that emit
    tab-delimited BED lines via BedRecord.write_to().

    Example::

        var out = String()
        var writer = BedWriter[String](out^)
        writer.write_record(rec)
    """

    var _writer: Self.W

    def __init__(out self, var writer: Self.W):
        self._writer = writer^

    def write_record(mut self, ref rec: BedRecord) raises:
        """Write one BED record as a tab-delimited line."""
        rec.write_to(self._writer)

    def write_view(mut self, view: BedView[_]) raises:
        """Materialise view into an owned record and write it as a tab-delimited line."""
        var rec = view.to_record()
        rec.write_to(self._writer)
