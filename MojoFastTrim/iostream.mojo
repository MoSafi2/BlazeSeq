alias DEFAULT_CAPACITY = 64 * 1024


struct BufferedStream:
    """An IO stream buffer which begins can take an underlying resource an FileHandle, Path, Tensor.
    """

    var buffer: Tensor[DType.int8]

    fn __init__(inout self, stream: FileHandle, capacity: Int = DEFAULT_CAPACITY):
        try:
            self.buffer = stream.read_bytes(capacity)
        except:
            pass #TODO: Handle IO errors

    fn __init__(inout self, stream: Path, capacity: Int = DEFAULT_CAPACITY):

        if stream.exists():
            try:
                let f = open(stream.path, "r")
                self.buffer = f.read_bytes(capacity)
            except:
                pass #TODO: Handle IO errors

    fn __init__(inout self, stream: Tensor[DType.int8], capacity: Int = DEFAULT_CAPACITY):

        self.buffer = 