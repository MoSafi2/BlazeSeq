from fastq_record import FastqRecord


struct FastqCollection(Stringable, Sized):

    """
    Struct represents a collecion of FastqRecord. 
    it is backed by a dynamic vector and can be passed around or multi-core processing.
    it provides convience methods for starting trimming and writing of the contained records.
    """

    var data: DynamicVector[FastqRecord]
    var _trimmed_collection: Bool

    fn __init__(inout self):
        self.data = DynamicVector[FastqRecord]()
        self._trimmed_collection = False

    fn write_collection(self, borrowed file_handle: FileHandle) raises -> None:
        for i in range(len(self)):
            file_handle.write(self.data[i].wirte_record())

        print("finished writing: ")
        print(len(self))
        print("records")


    fn trim_collection(inout self, direction: String = "end", quality_threshold: Int = 20):
        for i in range(len(self)):
            self.data[i].trim_record(direction, quality_threshold)

        self._trimmed_collection = True

        print("finished record trimming: ")
        print(len(self))
        print("records")


    fn __str__(self) -> String:
        var s = String()
        s += "The numebr of records in the collection is: " 
        s += len(self)
        return s

    fn __len__(self) -> Int:
        return len(self.data)

