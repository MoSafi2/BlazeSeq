from blazeseq.fastq.record import FastqRecord, FastqView
from blazeseq.byte_string import BString
from std.memory import Pointer
from std.collections.string import String

# Default max records per batch for parser.batches() / next_batch() and FastqBatch preallocation.
comptime DEFAULT_BATCH_SIZE = 4096


struct FastqBatch(Copyable, Deinitable, Sized, Writable):
    var _id_bytes: List[UInt8]
    var _quality_bytes: List[UInt8]
    var _sequence_bytes: List[UInt8]
    var _id_ends: List[Int64]
    var _ends: List[Int64]
    var _quality_offset: UInt8

    def __init__(
        out self,
        batch_size: Int = DEFAULT_BATCH_SIZE,
        avg_record_size: Int = 150,
        quality_offset: UInt8 = 33,
    ):
        self._id_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._id_ends = List[Int64](capacity=batch_size)
        self._quality_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._sequence_bytes = List[UInt8](
            capacity=avg_record_size * batch_size
        )
        self._ends = List[Int64](capacity=batch_size)
        self._quality_offset = quality_offset

    def __init__(
        out self,
        records: List[FastqRecord],
        avg_record_size: Int = 150,
        quality_offset: UInt8 = 33,
    ) raises:
        if len(records) == 0:
            raise Error("FastqBatch cannot be empty")

        var batch_size = len(records)
        self._id_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._id_ends = List[Int64](capacity=batch_size)
        self._quality_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._sequence_bytes = List[UInt8](
            capacity=avg_record_size * batch_size
        )
        self._ends = List[Int64](capacity=batch_size)
        self._quality_offset = quality_offset
        for i in range(batch_size):
            self.add(records[i])

    def add(mut self, record: FastqRecord):
        self._quality_bytes.extend(record._quality.as_span())
        self._sequence_bytes.extend(record._sequence.as_span())
        self._id_bytes.extend(record._id.as_span())

        if self.num_records() == 0:
            self._id_ends.append(Int64(len(record._id)))
            self._ends.append(Int64(len(record._quality)))
        else:
            var last_idx = len(self._id_ends) - 1
            self._id_ends.append(
                Int64(len(record._id)) + self._id_ends[last_idx]
            )
            self._ends.append(
                Int64(len(record._quality)) + self._ends[len(self._ends) - 1]
            )

    def add[origin: Origin[mut=True]](mut self, record: FastqView[origin]):
        self._quality_bytes.extend(record._quality)
        self._sequence_bytes.extend(record._sequence)
        self._id_bytes.extend(record._id)

        if self.num_records() == 0:
            self._id_ends.append(Int64(len(record._id)))
            self._ends.append(Int64(len(record._quality)))
        else:
            var last_idx = len(self._id_ends) - 1
            self._id_ends.append(
                Int64(len(record._id)) + self._id_ends[last_idx]
            )
            self._ends.append(
                Int64(len(record._quality)) + self._ends[len(self._ends) - 1]
            )

    def num_records(self) -> Int:
        return len(self._ends)

    def seq_len(self) -> Int:
        return Int(self._ends[len(self._ends) - 1])

    def quality_offset(self) -> UInt8:
        return self._quality_offset

    def __len__(self) -> Int:
        return self.num_records()

    def __repr__(self) -> String:
        return (
            "FastqBatch(records="
            + String(self.num_records())
            + ", quality_offset="
            + String(self._quality_offset)
            + ")"
        )

    def get_record(self, index: Int) raises -> FastqRecord:
        var n = self.num_records()
        if index < 0 or index >= n:
            raise Error("FastqBatch.get_record index out of range")

        def get_offsets(ends: List[Int64], idx: Int) -> Tuple[Int, Int]:
            var start = Int(0) if idx == 0 else Int(ends[idx - 1])
            var end = Int(ends[idx])
            return start, end

        def unsafe_span_to_ascii_string[
            origin: Origin
        ](bs: Span[Byte, origin]) -> BString:
            var len_bs = len(bs)
            var new_ptr = (
                bs.unsafe_ptr()
                .unsafe_mut_cast[True]()
                .unsafe_origin_cast[MutUntrackedOrigin]()
            )
            var span = Span[Byte, MutUntrackedOrigin](
                unsafe_ptr=new_ptr, length=len_bs
            )
            return BString(span)

        var id_range = get_offsets(self._id_ends, index)
        var id_bs = self._id_bytes[id_range[0] : id_range[1]]

        var range = get_offsets(self._ends, index)
        var seq_bs = self._sequence_bytes[range[0] : range[1]]
        var qual_bs = self._quality_bytes[range[0] : range[1]]

        var id_str = unsafe_span_to_ascii_string(id_bs)
        var seq = unsafe_span_to_ascii_string(seq_bs)
        var qual = unsafe_span_to_ascii_string(qual_bs)

        return FastqRecord(
            id_str^,
            seq^,
            qual^,
            Int8(self._quality_offset),
        )

    def get_ref(self, index: Int) raises -> FastqView[origin_of(self)]:
        var n = self.num_records()
        if index < 0 or index >= n:
            raise Error("FastqBatch.get_ref index out of range")

        def get_offsets(ends: List[Int64], idx: Int) -> Tuple[Int, Int]:
            var start = Int(0) if idx == 0 else Int(ends[idx - 1])
            var end = Int(ends[idx])
            return start, end

        var id_range = get_offsets(self._id_ends, index)
        var range = get_offsets(self._ends, index)

        var id_span = Span[Byte, origin_of(self)](
            unsafe_ptr=self._id_bytes.unsafe_ptr()
            .unsafe_origin_cast[origin_of(self)]()
            .unsafe_offset(id_range[0]),
            length=id_range[1] - id_range[0],
        )
        var seq_span = Span[Byte, origin_of(self)](
            unsafe_ptr=self._sequence_bytes.unsafe_ptr()
            .unsafe_origin_cast[origin_of(self)]()
            .unsafe_offset(range[0]),
            length=range[1] - range[0],
        )
        var qual_span = Span[Byte, origin_of(self)](
            unsafe_ptr=self._quality_bytes.unsafe_ptr()
            .unsafe_origin_cast[origin_of(self)]()
            .unsafe_offset(range[0]),
            length=range[1] - range[0],
        )

        return FastqView[origin=origin_of(self)](
            id_span,
            seq_span,
            qual_span,
            UInt8(self._quality_offset),
        )

    def to_records(self) raises -> List[FastqRecord]:
        var n = self.num_records()
        var out = List[FastqRecord](capacity=n)
        for i in range(n):
            out.append(self.get_record(i))
        return out^

    def write_to(self, mut w: Some[Writer]) raises:
        for i in range(self.num_records()):
            self.get_ref(i).write_to(w)
