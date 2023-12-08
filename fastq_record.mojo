

@value
struct FastqRecord(CollectionElement, Stringable, Sized):
    """Struct that represent a single FastaQ record."""
    var SeqHeader: String
    var SeqStr: String
    var QuHeader: String
    var QuStr: String

    fn __init__(
    inout self,
     SH: String,
     SS: String,
     QH: String,
     QS: String) raises -> None:

        if SH[0] != "@":
            pass
            #print("Sequence Header is corrput")
            #print(SH)

        if QH[0] != "+":
            print("Quality Header is corrput")

        self.SeqHeader = SH[1:]
        self.QuHeader = QH[1:]

        if len(self.QuHeader) > 0:
            if self.QuHeader != self.SeqHeader:
                print("Quality Header is corrupt")

        self.SeqStr = SS
        self.QuStr = QS

    fn trim_record(inout self, direction: String = "end", quality_threshold: Int = 20):
        """Algorithm for record trimming replicating trimming method implemented by BWA and cutadapt."""


        var s: Int = 0
        var min_qual: Int = 0
        let n = len(self.QuStr)
        var stop: Int = n
        var start: Int = 0
        let i: Int

        
        #Find trim position in 5' end
        for i in range(n):
            s +=  (ord(self.QuStr[i]) - 33) - quality_threshold
            if s > 0:
                break
            if s < min_qual:
                min_qual = s
                start = i +1
            
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
        
        self.SeqStr = self.SeqStr[start:stop]
        self.QuStr = self.QuStr[start:stop]


    fn wirte_record(self) -> String:
        var s = String()
        s += "@"+self.SeqHeader +"\n"
        s += self.SeqStr + "\n"
        s += "+"+self.QuHeader+"\n"
        s += self.QuStr+"\n"
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
 


fn main() raises -> None:
    let f = open("data/single_read.fastq", "r")
    let s = f.read()
    let v = s.split("\n")
    var r = FastqRecord(v[0], v[1], v[2], v[3])

    r.trim_record(direction = "both", quality_threshold = 15)
    print(r.wirte_record())
