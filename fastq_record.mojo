from helpers import slice_tensor
from memory.unsafe import DTypePointer
from memory.memory import memcpy
from tensor import Tensor

alias USE_SIMD = True


@value
struct FastqRecord(CollectionElement, Sized, Stringable):
    """Struct that represent a single FastaQ record."""

    var SeqHeader: Tensor[DType.int8]
    var SeqStr: Tensor[DType.int8]
    var QuHeader: Tensor[DType.int8]
    var QuStr: Tensor[DType.int8]
    var total_length: Int

    fn __init__(
        inout self,
        SH: Tensor[DType.int8],
        SS: Tensor[DType.int8],
        QH: Tensor[DType.int8],
        QS: Tensor[DType.int8],
    ) raises -> None:
        if SH[0] != ord("@"):
            #print(SH, "Sequence Header is corrput")
            raise Error("Sequence Header is corrput")

        if QH[0] != ord("+"):
            #print(QH, "Quality Header is corrput")
            raise Error("Quality Header is corrput")

        if SS.num_elements() != QS.num_elements():
            #print(SS, QS, "Corrput Lengths")
            raise Error("Corrput Lengths")

        self.SeqHeader = SH
        self.QuHeader = QH

        if self.QuHeader.num_elements() > 1:
            if self.QuHeader.num_elements() != self.SeqHeader.num_elements():
                #print(QH, "Quality Header is corrupt")
                raise Error("Quality Header is corrupt")

        self.SeqStr = SS
        self.QuStr = QS

        self.total_length = (
            SH.num_elements()
            + SS.num_elements()
            + QH.num_elements()
            + QS.num_elements()
            + 4  # Addition of 4 \n again
        )

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
            self.SeqStr = slice_tensor[USE_SIMD=USE_SIMD](self.SeqStr, 0, stop)
            self.QuStr = slice_tensor[USE_SIMD=USE_SIMD](self.QuStr, 0, stop)

        if direction == "start":
            self.SeqStr = slice_tensor[USE_SIMD=USE_SIMD](self.SeqStr, start, n)
            self.QuStr = slice_tensor[USE_SIMD=USE_SIMD](self.QuStr, start, n)

        if direction == "both":
            self.SeqStr = slice_tensor[USE_SIMD=USE_SIMD](self.SeqStr, start, stop)
            self.QuStr = slice_tensor[USE_SIMD=USE_SIMD](self.QuStr, start, stop)

        self.total_length = (
            self.SeqHeader.num_elements()
            + self.SeqStr.num_elements()
            + self.QuHeader.num_elements()
            + self.QuStr.num_elements()
        )

    @always_inline
    fn wirte_record(self) -> Tensor[DType.int8]:
        return self.__concat_record()

    @always_inline
    fn _empty_record(inout self):
        self.SeqStr = Tensor[DType.int8](0)

    @always_inline
    fn __concat_record(self) -> Tensor[DType.int8]:
        var offset = 0
        var t = Tensor[DType.int8](self.total_length)

        for i in range(self.SeqHeader.num_elements()):
            t[i] = self.SeqHeader[i]
        offset = offset + self.SeqHeader.num_elements() + 1
        t[offset - 1] = 10

        for i in range(self.SeqStr.num_elements()):
            t[i + offset] = self.SeqStr[i]
        offset = offset + self.SeqStr.num_elements() + 1
        t[offset - 1] = 10

        for i in range(self.QuHeader.num_elements()):
            t[i + offset] = self.QuHeader[i]
        offset = offset + self.QuHeader.num_elements() + 1
        t[offset - 1] = 10

        for i in range(self.QuStr.num_elements()):
            t[i + offset] = self.QuStr[i]
        offset = offset + self.QuStr.num_elements() + 1
        t[offset - 1] = 10

        return t

    fn __str__(self) -> String:
        var concat = self.__concat_record()
        let s = DTypePointer[DType.int8]().alloc(self.total_length)
        memcpy[DType.int8](s, concat._steal_ptr(), self.total_length)
        return String(s, self.total_length)

    fn __len__(self) -> Int:
        return self.SeqStr.num_elements()
