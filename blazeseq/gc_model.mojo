from tensor import Tensor


@value
struct GCmodel(CollectionElement):
    var read_length: Int
    var percentage: List[Tensor[DType.int64]]
    var increment: List[Tensor[DType.float64]]

    fn __init__(out self, read_length: Int):
        self.read_length = read_length
        self.percentage = List[Tensor[DType.int64]](capacity=read_length)
        self.increment = List[Tensor[DType.float64]](capacity=read_length)

        claimingCounts = List[Int](capacity=101)
        for i in range(read_length + 1):
            low_count = i - 0.5
            high_count = i + 0.5
            if low_count < 0:
                low_count = 0
            if high_count < 0:
                high_count = 0
            if low_count > read_length:
                low_count = read_length
            var low_percentage = int(round((low_count * 100) / read_length))
            var high_percentage = int(round((high_count * 100) / read_length))

            for j in range(low_percentage, high_percentage):
                claimingCounts[j] += 1

        for i in range(read_length + 1):
            low_count = i - 0.5
            high_count = i + 0.5
            if low_count < 0:
                low_count = 0
            if high_count < 0:
                high_count = 0
            if low_count > read_length:
                low_count = read_length
            var low_percentage = int(round((low_count * 100) / read_length))
            var high_percentage = int(round((high_count * 100) / read_length))


@value
struct GCValue(CollectionElement):
    pass
