"""The Idea of this implementation is to avoid copying any tensors to the Record. It just referes to everything as position of the buffer.
The read can be as following, Start [U64], Header Offset, Read offset Int32, Qu Header offser, Int32, QuStr Offset, Int32.
Prasing can be done on 
"""

alias new_line: Int = ord("\n")
alias read_header: Int = ord("@")
alias quality_header: Int = ord("+")


@value
struct RecordCoord(Stringable):
    """Struct that represent coordinates of a FastqRecord in a chunk."""

    var SeqHeader: Int32
    var SeqStr: Int32
    var QuHeader: Int32
    var QuStr: Int32
    var end: Int32

    fn __init__(
        inout self,
        SH: Int32,
        SS: Int32,
        QH: Int32,
        QS: Int32,
        end: Int32,
    ):
        """Coordinates of the FastqRecord inside a chunk including the start and the end of the record.
        """
        self.SeqHeader = SH
        self.SeqStr = SS
        self.QuHeader = QH
        self.QuStr = QS
        self.end = end

    @always_inline
    fn validate(self, chunk: Tensor[DType.int8]) raises:
        if chunk[self.SeqHeader.to_int()] != read_header:
            raise Error("Quality Header is corrput.")

        if self.seq_len() != self.qu_len():
            raise Error("Corrupt Lengths.")

    @always_inline
    fn seq_len(self) -> Int32:
        return self.QuHeader - self.SeqStr - 1

    @always_inline
    fn qu_len(self) -> Int32:
        return self.end - self.QuStr - 1

    @always_inline
    fn qu_header_len(self) -> Int32:
        return self.QuStr - self.QuHeader  - 1

    fn __str__(self) -> String:
        return (
            String("SeqHeader: ")
            + self.SeqHeader
            + "\nSeqStr: "
            + self.SeqStr
            + "\nQuHeader: "
            + self.QuHeader
            + "\nQuStr: "
            + self.QuStr
            + "\nend: "
            + self.end
        )
