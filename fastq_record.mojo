

@value
struct FastqRecord(CollectionElement, Stringable, Sized):
    """Struct that represent a single FastaQ record."""
    var SeqHeader: String
    var SeqStr: String
    var QuHeader: String
    var QuStr: String
    var qu_int: QuInt
    var _quality_infered: Bool
    var _trimmed_record: Bool

    fn __init__(inout self, SH: String,
     SS: String,
     QH: String,
     QS: String,
     infer_quality: Bool = True) raises -> None:

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
        self.qu_int = QuInt(len(self.QuStr))
        self._quality_infered = False
        self._trimmed_record = False

        if infer_quality:
            self._quality_infered = True
            self._infer_qualities()
        


    fn trim_record(inout self, direction: String = "end", quality_threshold: Int = 20):
        """Algorithm for record trimming replicating trimming method implemented by BWA and cutadapt."""

        if not self._quality_infered:
                self._infer_qualities()
            
        if direction == "end":
            self.qu_int.lf_rolling_sum(threshold = quality_threshold)
            let end = self.qu_int.min_val("left").get[0, Int]()
            self.SeqStr = self.SeqStr[0:end]
            self.QuStr = self.QuStr[0:end]

        if direction == "start":
            self.qu_int.rt_rolling_sum(threshold = quality_threshold)
            let start = self.qu_int.min_val("right").get[0, Int]()
            self.SeqStr = self.SeqStr[start+1: len(self)-1]
            self.QuStr = self.QuStr[start+1:len(self)-1]
            

        if direction == "both":
            self.qu_int.lf_rolling_sum(threshold = quality_threshold)
            self.qu_int.rt_rolling_sum(threshold = quality_threshold)
            
            let start = self.qu_int.min_val("right").get[0, Int]()
            let end = self.qu_int.min_val("left").get[0, Int]()

            self.SeqStr = self.SeqStr[start+1: end]
            self.QuStr = self.QuStr[start+1:end]

        self._trimmed_record = True
        self._infer_qualities()



    fn wirte_record(self) -> String:
        var s = String()
        s += "@"+self.SeqHeader +"\n"
        s += self.SeqStr + "\n"
        s += "+"+self.QuHeader+"\n"
        s += self.QuStr

        print(s)
        return s



    fn _infer_qualities(inout self):
        for i in range(len(self.SeqStr)):
            self.qu_int[i] = (ord(self.QuStr[i]) - 33)


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

        for i in range(len(self.qu_int)):
            str_repr += self.qu_int.data[i]
            str_repr += "-"
        return str_repr


    fn __len__(self) -> Int:
        return len(self.SeqStr)
 


@value
struct QuInt(Sized):
    var data: Tensor[DType.int32]
    var rt_rolling: Tensor[DType.int32]
    var lf_rolling: Tensor[DType.int32]

    fn __init__(inout self, tensor_length: Int):
        self.data = Tensor[DType.int32](tensor_length)
        self.rt_rolling = Tensor[DType.int32](tensor_length)
        self.lf_rolling = Tensor[DType.int32](tensor_length)

    
    fn min_val(self, which: String) -> ListLiteral[Int, Int32]:
        var min: Int32 = 9999 #Max value for Illumina in 40  
        var index: Int = -1
        let shape = self.data.shape()[0]

        if which == "right":
            for i in range(shape):
                if self.rt_rolling[i] < min:
                    min = self.rt_rolling[i]
                    index = i

        elif which == "left":
            for i in range(shape):
                if self.lf_rolling[i] < min:
                    min = self.lf_rolling[i]
                    index = i

        else:
            print("Please choose either 'left' or 'right'.")

        return ListLiteral(index, min)
 
    fn lf_rolling_sum(inout self, threshold: Int32 = 20):

        self.lf_rolling = self.lf_rolling - threshold

        let shape = self.data.shape()[0]
        for i in range(2, shape + 1):
            self.lf_rolling[shape - i] = self.lf_rolling[shape - i ] + self.lf_rolling[shape - (i-1)]


    fn rt_rolling_sum(inout self, threshold: Int32 = 20):

        self.rt_rolling = self.rt_rolling - threshold
        let shape = self.data.shape()[0]
        for i in range(1, shape):
            self.rt_rolling[i] = self.rt_rolling[i] + self.rt_rolling[i-1]

    fn __setitem__(inout self, index: Int,  value: Int32):
        self.data[index] = value
        self.rt_rolling[index] = value
        self.lf_rolling[index] = value


    fn __len__(self) -> Int:
        return self.data.shape()[0]



fn main() raises -> None:
    let f = open("data/single_read.fastq", "r")
    let s = f.read()
    let v = s.split("\n")
    var r = FastqRecord(v[0], v[1], v[2], v[3])
    print(r)
    print(len(r))

    r.trim_record(direction = "both")
    
    print(r)
    print(len(r))