from fastq_record import FastqRecord


struct FastqCollection(Stringable, Sized):

    """
    Struct represents a collecion of FastqRecord. 
    it is backed by a dynamic vector and can be passed around for multi-core processing when implemented.
    it provides convience methods for starting trimming and writing of the contained records.
    """

    var data: DynamicVector[FastqRecord]
    var _trimmed_collection: Bool

    fn __init__(inout self):
        self.data = DynamicVector[FastqRecord]()
        self._trimmed_collection = False

    fn write_collection(self, borrowed file_handle: FileHandle) raises -> None:
        
        var written: Int = 0 
        var discarded: Int = 0
        #var out_string: String = ""

        for i in range(len(self)):
            if len(self.data[i]) > 0:
                #out_string = out_string + self.data[i].wirte_record()
                file_handle.write(self.data[i].wirte_record())
                written = written + 1
            else:
                discarded = discarded + 1
        
        #file_handle.write(out_string)

        # print("finished writing: ")
        # print(written)
        # print("records")
        # print(discarded)
        # print("records were discarded")


    fn trim_collection(inout self, direction: String = "end", quality_threshold: Int = 20):
        for i in range(0, len(self)):
            self.data[i].trim_record(direction, quality_threshold)
        self._trimmed_collection = True

        # print("finished record trimming: ")
        # print(len(self))
        # print("records were trimmed.")


    fn add(inout self, record: FastqRecord):
        self.data.push_back(record)

    fn __getitem__(self, index: Int) -> FastqRecord:
        return self.data[index]

    fn __str__(self) -> String:
        var s = String()
        s += "The numebr of records in the collection is: " 
        s += len(self)
        return s

    fn __len__(self) -> Int:
        return len(self.data)



# fn main() raises:
#     let f = open("data/two_reads.fastq", "r")
#     let out = open("data/data_out.fastq", "w")
#     let s = f.read()
#     let v = s.split("\n")
#     let r1 = FastqRecord(v[0], v[1], v[2], v[3])
#     let r2 = FastqRecord(v[4], v[5], v[6], v[7])
#     var collection = FastqCollection()
#     collection.add(r1)
#     collection.add(r2)

#     #print(collection[0])
#     print(len(collection[0]))

#     collection.trim_collection(direction = "both")

#     #print(collection[0])
#     print(len(collection[0]))


#     print(collection[1])
#     print(len(collection[1]))

#     collection.write_collection(out)
#     collection.write_collection(out)
    