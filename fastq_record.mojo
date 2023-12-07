#TODO: Implement a quality trimming algorithm as by Cutadapt.
#TODO: Implement 

@value
struct FastqRecord(CollectionElement, Stringable, Sized):
    """Struct that represent a single FastaQ record."""
    var SeqHeader: String
    var SeqStr: String
    var QuHeader: String
    var QuStr: String
    var QuInt: DynamicVector[Int8]

    fn __init__(inout self, SH: String,
     SS: String,
     QH: String,
     QS: String,
     infer_quality: Bool = False) raises -> None:

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
        self.QuInt = DynamicVector[Int8](capacity =len(SS))

        if infer_quality:
            self.infer_qualities()
        

    fn infer_qualities(inout self):
        for i in range(len(self.SeqStr)):
            self.QuInt.push_back(ord(self.QuStr[i]) - 33)

    fn trim_record(inout self, quality_threshold: Int = 20):
        pass

    fn wirte_record(self) -> String:
        var s = String()
        s += "@"+self.SeqHeader +"\n"
        s += self.SeqStr + "\n"
        s += "+"+self.QuHeader+"\n"
        s += self.QuStr

        print(s)

        return s


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

        for i in range(len(self.QuInt)):
            str_repr += self.QuInt[i]
            str_repr += "_"

        return str_repr

    fn __len__(self) -> Int:
        return len(self.SeqStr)
 

struct FastqCollection(Stringable, Sized):

    """
    Struct represents a collecion of FastqRecord. 
    it is backed by a dynamic vector and can be passed around or multi-core processing.
    it provides convience methods for starting trimming and writing of the contained records.
    """

    var data: DynamicVector[FastqRecord]

    fn __init__(inout self):
        self.data = DynamicVector[FastqRecord]()

    fn write_collection(self, borrowed file_handle: FileHandle) raises -> None:
        for i in range(len(self)):
            file_handle.write(self.data[i].wirte_record())

        print("finished writing: ")
        print(len(self))
        print("Records")

    fn __str__(self) -> String:
        var s = String()
        s += "The numebr of records in the collection is: " 
        s += len(self)
        return s

    fn __len__(self) -> Int:
        return len(self.data)

