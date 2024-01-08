from helpers import slice_tensor
from memory.unsafe import DTypePointer
from memory.memory import memcpy


@value
struct FastqRecord(CollectionElement, Stringable, Sized):
    """Struct that represent a single FastaQ record."""

    var SeqHeader: String
    var SeqStr: String
    var QuHeader: String
    var QuStr: String

    fn __init__(
        inout self, SH: String, SS: String, QH: String, QS: String
    ) raises -> None:
        # if SH[0] != "@":
        #     print("Sequence Header is corrput")

        if QH[0] != "+":
            print("Quality Header is corrput")

        self.SeqHeader = SH
        self.QuHeader = QH

        if len(self.QuHeader) > 1:
            if self.QuHeader != self.SeqHeader:
                print("Quality Header is corrupt")

        self.SeqStr = SS
        self.QuStr = QS

    fn trim_record(inout self, direction: String = "end", quality_threshold: Int = 20):
        """Algorithm for record trimming replicating trimming method implemented by BWA and cutadapt.
        """

        var s: Int16 = 0
        var min_qual: Int16 = 0
        let n = len(self.QuStr)
        var stop: Int = n
        var start: Int = 0
        let i: Int

        ## minimum of Rolling sum algorithm used by Cutadapt and BWA
        # Find trim position in 5' end
        for i in range(n):
            s += (ord(self.QuStr[i]) - 33) - quality_threshold
            if s > 0:
                break
            if s < min_qual:
                min_qual = s
                start = i + 1

        # Find trim position in 3' end
        min_qual = 0
        s = 0
        for i in range(1, n):
            s += (ord(self.QuStr[n - i]) - 33) - quality_threshold
            if s > 0:
                break
            if s < min_qual:
                min_qual = s
                stop = stop - 1

        if start >= stop:
            self._empty_record()
            return

        if direction == "end":
            self.SeqStr = self.SeqStr[0:stop]
            self.QuStr = self.QuStr[0:stop]

        if direction == "start":
            self.SeqStr = self.SeqStr[start:n]
            self.QuStr = self.QuStr[start:n]

        if direction == "both":
            self.SeqStr = self.SeqStr[start:stop]
            self.QuStr = self.QuStr[start:stop]

    @always_inline
    fn wirte_record(self) -> String:
        var s: String = "\n"
        s = s.join(self.SeqHeader, self.SeqStr, self.QuHeader, self.QuStr)
        return s

    fn _empty_record(inout self):
        self.SeqStr = ""

    fn __str__(self) -> String:
        var str_repr = String()
        str_repr += "Record:"
        str_repr += self.SeqHeader
        str_repr += "\nSeq:"
        str_repr += self.SeqStr
        str_repr += " \n"
        str_repr += "Quality: "
        str_repr += self.QuStr
        str_repr += "\nInfered Quality: "
        return str_repr

    fn __len__(self) -> Int:
        return len(self.SeqStr)


@value
struct FastqRecord_Tensor(CollectionElement, Sized, Stringable):
    """Struct that represent a single FastaQ record."""

    var SeqHeader: Tensor[DType.int8]
    var SeqStr: Tensor[DType.int8]
    var QuHeader: Tensor[DType.int8]
    var QuStr: Tensor[DType.int8]

    fn __init__(
        inout self,
        SH: Tensor[DType.int8],
        SS: Tensor[DType.int8],
        QH: Tensor[DType.int8],
        QS: Tensor[DType.int8],
    ) raises -> None:
        if SH[0] != ord("@"):
            print(SH)
            raise Error("Sequence Header is corrput")
        if QH[0] != ord("+"):
            print(QH)
            raise Error("Quality Header is corrput")

        if SS.num_elements() != QS.num_elements():
            raise Error("Corrput Lengths")

        self.SeqHeader = SH
        self.QuHeader = QH

        if self.QuHeader.num_elements() > 1:
            if self.QuHeader.num_elements() != self.SeqHeader.num_elements():
                raise Error("Quality Header is corrupt")

        self.SeqStr = SS
        self.QuStr = QS

    fn trim_record(inout self, direction: String = "end", quality_threshold: Int = 20):
        """Algorithm for record trimming replicating trimming method implemented by BWA and cutadapt.
        """

        var s: Int8 = 0
        var min_qual: Int8 = 0
        let n = self.QuStr.num_elements()
        var stop: Int = n
        var start: Int = 0
        let i: Int

        ## minimum of Rolling sum algorithm used by Cutadapt and BWA
        # Find trim position in 5' end
        for i in range(n):
            s += (self.QuStr[i] - 33) - quality_threshold
            if s > 0:
                break
            if s < min_qual:
                min_qual = s
                start = i + 1

        # Find trim position in 3' end
        min_qual = 0
        s = 0
        for i in range(1, n):
            s += (ord(self.QuStr[n - i]) - 33) - quality_threshold
            if s > 0:
                break
            if s < min_qual:
                min_qual = s
                stop = stop - 1

        if start >= stop:
            self._empty_record()
            return

        if direction == "end":
            self.SeqStr = slice_tensor(self.SeqStr, 0, stop)
            self.QuStr = slice_tensor(self.QuStr, 0, stop)

        if direction == "start":
            self.SeqStr = slice_tensor(self.SeqStr, start, n)
            self.QuStr = slice_tensor(self.QuStr, start, n)

        if direction == "both":
            self.SeqStr = slice_tensor(self.SeqStr, start, stop)
            self.QuStr = slice_tensor(self.QuStr, start, stop)

    @always_inline
    fn wirte_record(self) -> String:
        return self.__str__()

    fn _empty_record(inout self):
        self.SeqStr = Tensor[DType.int8](0)

    fn __str__(self) -> String:
        var str_repr = String()
        for i in range(self.SeqHeader.num_elements()):
            str_repr._buffer.push_back(self.SeqHeader[i])
        str_repr._buffer.push_back(10)

        for i in range(self.SeqStr.num_elements()):
            str_repr._buffer.push_back(self.SeqStr[i])
        str_repr._buffer.push_back(10)

        for i in range(self.QuHeader.num_elements()):
            str_repr._buffer.push_back(self.QuHeader[i])
        str_repr._buffer.push_back(10)

        for i in range(self.QuStr.num_elements()):
            str_repr._buffer.push_back(self.QuStr[i])
        str_repr._buffer.push_back(10)

        return str_repr


    fn __len__(self) -> Int:
        return self.SeqStr.num_elements()
