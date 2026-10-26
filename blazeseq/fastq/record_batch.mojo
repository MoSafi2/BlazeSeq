from blazeseq.fastq.record import FastqRecord, FastqView
from blazeseq.byte_string import BString
from std.memory import Pointer, unsafe_memcpy
from max.gpu.host import DeviceContext, DeviceBuffer, HostBuffer
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

    def to_device(self, ctx: DeviceContext) raises -> DeviceFastqBatch:
        """Upload all batch buffers; the transfer completes before returning."""
        return upload_batch_to_device(self, ctx)

    def stage(self, ctx: DeviceContext) raises -> StagedFastqBatch:
        """Copy this batch into owned, pinned host buffers."""
        return stage_batch_to_host(self, ctx)

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


@fieldwise_init
struct DeviceFastqBatch(Deinitable, Movable):
    """Owned device buffers and metadata for a FASTQ structure-of-arrays batch.
    """

    var num_records: Int
    var seq_len: Int64
    var quality_offset: UInt8
    var total_id_bytes: Int64
    var qual_buffer: DeviceBuffer[.uint8]
    var sequence_buffer: DeviceBuffer[.uint8]
    var ends: DeviceBuffer[.int64]
    var id_buffer: DeviceBuffer[.uint8]
    var id_ends: DeviceBuffer[.int64]

    def copy_to_host(self, ctx: DeviceContext) raises -> FastqBatch:
        var staged = download_device_batch_to_staged(self, ctx)
        var batch = FastqBatch(quality_offset=self.quality_offset, batch_size=0)
        batch._quality_bytes = List[UInt8](capacity=Int(staged.total_seq_bytes))
        batch._ends = List[Int64](capacity=staged.num_records)
        batch._quality_bytes.extend(staged.quality_data.as_span())
        batch._ends.extend(staged.ends.as_span())
        batch._sequence_bytes = List[UInt8](
            capacity=Int(staged.total_seq_bytes)
        )
        batch._sequence_bytes.extend(staged.sequence_data.as_span())
        batch._id_bytes = List[UInt8](capacity=Int(staged.total_id_bytes))
        batch._id_ends = List[Int64](capacity=staged.num_records)
        batch._id_bytes.extend(staged.id_data.as_span())
        batch._id_ends.extend(staged.id_ends.as_span())
        return batch^

    def to_records(self, ctx: DeviceContext) raises -> List[FastqRecord]:
        return self.copy_to_host(ctx).to_records()


@fieldwise_init
struct StagedFastqBatch:
    """Owned pinned host buffers, ready for a synchronized device upload."""

    var num_records: Int
    var total_seq_bytes: Int64
    var total_id_bytes: Int64
    var quality_offset: UInt8
    var quality_data: HostBuffer[.uint8]
    var sequence_data: HostBuffer[.uint8]
    var id_data: HostBuffer[.uint8]
    var ends: HostBuffer[.int64]
    var id_ends: HostBuffer[.int64]

    def to_device(deinit self, ctx: DeviceContext) raises -> DeviceFastqBatch:
        """Consume the staging buffers after a synchronized upload."""
        return move_staged_to_device(self^, ctx)


def download_device_batch_to_staged(
    device_batch: DeviceFastqBatch, ctx: DeviceContext
) raises -> StagedFastqBatch:
    """Download every device buffer and wait until host data is readable."""
    var n = device_batch.num_records
    var total_seq = device_batch.seq_len
    var total_id = device_batch.total_id_bytes
    var quality_data = ctx.enqueue_create_host_buffer[.uint8](Int(total_seq))
    var ends = ctx.enqueue_create_host_buffer[.int64](n)
    var sequence_data = ctx.enqueue_create_host_buffer[.uint8](Int(total_seq))
    var id_data = ctx.enqueue_create_host_buffer[.uint8](Int(total_id))
    var id_ends = ctx.enqueue_create_host_buffer[.int64](n)
    ctx.enqueue_copy(src_buf=device_batch.qual_buffer, dst_buf=quality_data)
    ctx.enqueue_copy(src_buf=device_batch.ends, dst_buf=ends)
    ctx.enqueue_copy(
        src_buf=device_batch.sequence_buffer, dst_buf=sequence_data
    )
    ctx.enqueue_copy(src_buf=device_batch.id_buffer, dst_buf=id_data)
    ctx.enqueue_copy(src_buf=device_batch.id_ends, dst_buf=id_ends)
    ctx.synchronize()
    return StagedFastqBatch(
        num_records=n,
        total_seq_bytes=total_seq,
        total_id_bytes=total_id,
        quality_offset=device_batch.quality_offset,
        quality_data=quality_data,
        sequence_data=sequence_data,
        id_data=id_data,
        ends=ends,
        id_ends=id_ends,
    )


def stage_batch_to_host(
    batch: FastqBatch, ctx: DeviceContext
) raises -> StagedFastqBatch:
    """Copy a nonempty CPU batch into pinned host buffers, retaining metadata.
    """
    var n = batch.num_records()
    if n == 0:
        raise Error("Cannot transfer an empty FastqBatch")
    var total_bytes = batch.seq_len()
    var total_id_bytes = len(batch._id_bytes)
    var quality_data = ctx.enqueue_create_host_buffer[.uint8](total_bytes)
    var sequence_data = ctx.enqueue_create_host_buffer[.uint8](total_bytes)
    var id_data = ctx.enqueue_create_host_buffer[.uint8](total_id_bytes)
    var ends = ctx.enqueue_create_host_buffer[.int64](n)
    var id_ends = ctx.enqueue_create_host_buffer[.int64](n)
    ctx.synchronize()
    unsafe_memcpy(
        dest=quality_data.as_span().unsafe_ptr(),
        src=batch._quality_bytes.unsafe_ptr(),
        count=total_bytes,
    )
    unsafe_memcpy(
        dest=ends.as_span().unsafe_ptr(), src=batch._ends.unsafe_ptr(), count=n
    )
    unsafe_memcpy(
        dest=sequence_data.as_span().unsafe_ptr(),
        src=batch._sequence_bytes.unsafe_ptr(),
        count=total_bytes,
    )
    unsafe_memcpy(
        dest=id_data.as_span().unsafe_ptr(),
        src=batch._id_bytes.unsafe_ptr(),
        count=total_id_bytes,
    )
    unsafe_memcpy(
        dest=id_ends.as_span().unsafe_ptr(),
        src=batch._id_ends.unsafe_ptr(),
        count=n,
    )
    return StagedFastqBatch(
        num_records=n,
        total_seq_bytes=Int64(total_bytes),
        total_id_bytes=Int64(total_id_bytes),
        quality_offset=batch.quality_offset(),
        quality_data=quality_data,
        sequence_data=sequence_data,
        id_data=id_data,
        ends=ends,
        id_ends=id_ends,
    )


def move_staged_to_device(
    var staged: StagedFastqBatch, ctx: DeviceContext
) raises -> DeviceFastqBatch:
    """Consume staged buffers after uploading all data and synchronizing."""
    var quality_buffer = ctx.enqueue_create_buffer[.uint8](
        Int(staged.total_seq_bytes)
    )
    var ends_buffer = ctx.enqueue_create_buffer[.int64](staged.num_records)
    var sequence_buffer = ctx.enqueue_create_buffer[.uint8](
        Int(staged.total_seq_bytes)
    )
    var id_buffer = ctx.enqueue_create_buffer[.uint8](
        Int(staged.total_id_bytes)
    )
    var id_ends_buffer = ctx.enqueue_create_buffer[.int64](staged.num_records)
    ctx.enqueue_copy(src_buf=staged.quality_data, dst_buf=quality_buffer)
    ctx.enqueue_copy(src_buf=staged.ends, dst_buf=ends_buffer)
    ctx.enqueue_copy(src_buf=staged.sequence_data, dst_buf=sequence_buffer)
    ctx.enqueue_copy(src_buf=staged.id_data, dst_buf=id_buffer)
    ctx.enqueue_copy(src_buf=staged.id_ends, dst_buf=id_ends_buffer)
    ctx.synchronize()
    return DeviceFastqBatch(
        num_records=staged.num_records,
        seq_len=staged.total_seq_bytes,
        quality_offset=staged.quality_offset,
        total_id_bytes=staged.total_id_bytes,
        qual_buffer=quality_buffer,
        sequence_buffer=sequence_buffer,
        ends=ends_buffer,
        id_buffer=id_buffer,
        id_ends=id_ends_buffer,
    )


def upload_batch_to_device(
    batch: FastqBatch, ctx: DeviceContext
) raises -> DeviceFastqBatch:
    """Stage and upload a nonempty CPU batch; return after transfer completion.
    """
    return move_staged_to_device(stage_batch_to_host(batch, ctx), ctx)
