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
        for pos in range(read_length + 1):
            low_count = pos - 0.5
            high_count = pos + 0.5
            if low_count < 0:
                low_count = 0
            if high_count < 0:
                high_count = 0
            if low_count > read_length:
                low_count = read_length
            var low_percentage = int(round((low_count * 100) / read_length))
            var high_percentage = int(round((high_count * 100) / read_length))

            for p in range(low_percentage, high_percentage):
                claimingCounts[p] += 1

        for pos in range(read_length + 1):
            low_count = pos - 0.5
            high_count = pos + 0.5
            if low_count < 0:
                low_count = 0
            if high_count < 0:
                high_count = 0
            if low_count > read_length:
                low_count = read_length
            var low_percentage = int(round((low_count * 100) / read_length))
            var high_percentage = int(round((high_count * 100) / read_length))
            var percentage_row = Tensor[DType.int64](
                (high_percentage - low_percentage) + 1
            )
            var increment_row = Tensor[DType.float64](
                (high_percentage - low_percentage) + 1
            )

            for p in range(low_percentage, high_percentage):
                percentage_row[p - low_percentage] = p
                increment_row[p - low_percentage] = Float64(
                    1 / claimingCounts[p]
                )

            # TODO: Consider Changing this to a struct to avoid accessing two pointers
            self.percentage[pos] = percentage_row
            self.increment[pos] = increment_row


