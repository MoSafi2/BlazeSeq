"""Device-compatible Fastq record descriptor and batch for GPU kernels."""

from blazeseq.record import FastqRecord, RefRecord
from blazeseq.ascii_string import ASCIIString
from blazeseq.CONSTS import DEFAULT_BATCH_SIZE
from gpu.host import DeviceContext
from gpu.host.device_context import DeviceBuffer, HostBuffer
from gpu import block_idx, thread_idx
from memory import UnsafePointer, memcpy, Span, alloc
from collections.string import String


# ---------------------------------------------------------------------------
# Trait for host-side batches that can be uploaded to the device
# ---------------------------------------------------------------------------


trait GpuMovableBatch:
    """Host-side batch type that can be moved to the device. Id, sequence, and quality are always uploaded."""

    fn num_records(self) -> Int:
        ...

    fn to_device(self, ctx: DeviceContext) raises -> DeviceFastqBatch:
        ...


# ---------------------------------------------------------------------------
# FastqBatch: Structure-of-Arrays batch format for GPU operations
# ---------------------------------------------------------------------------


struct FastqBatch(Copyable, GpuMovableBatch, ImplicitlyDestructible, Sized, Representable):
    """
    Structure-of-Arrays (SoA) batch format for multiple FASTQ records.
    
    Stores ids, sequences, and qualities in packed byte buffers with
    offset arrays, enabling coalesced GPU access after upload. Use with
    `parser.batches()` or `next_batch()`, or build from a list of `FastqRecord`s.
    Implements `GpuMovableBatch` for `to_device()`.
    
    Use cases: GPU kernels, batch processing.
    
    Example:
        ```mojo
        from blazeseq import FastqParser, FileReader
        from pathlib import Path
        var parser = FastqParser[FileReader](FileReader(Path("data.fastq")), "generic")
        for batch in parser.batches():
            _ = batch.num_records()
        ```
    """

    var _id_bytes: List[UInt8]
    var _quality_bytes: List[UInt8]
    var _sequence_bytes: List[UInt8]
    var _id_ends: List[Int64]
    var _ends: List[Int64]
    var _quality_offset: UInt8

    fn __init__(
        out self,
        batch_size: Int = DEFAULT_BATCH_SIZE,
        avg_record_size: Int = 150,
        quality_offset: UInt8 = 33,
    ):
        """Create an empty batch with preallocated capacity.
        
        Args:
            batch_size: Expected number of records (capacity for offset arrays); default from CONSTS.
            avg_record_size: Estimated bytes per record for buffer preallocation.
            quality_offset: Phred offset (33 or 64) for the batch.
        """
        self._id_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._id_ends = List[Int64](capacity=batch_size)
        self._quality_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._sequence_bytes = List[UInt8](
            capacity=avg_record_size * batch_size
        )
        self._ends = List[Int64](capacity=batch_size)
        self._quality_offset = quality_offset

    fn __init__(
        out self,
        records: List[FastqRecord],
        avg_record_size: Int = 150,
        quality_offset: UInt8 = 33,
    ) raises:
        """
        Build a FastqBatch from a list of FastqRecords in one shot.
        Uses the first record's quality_offset for the batch; empty list yields an empty batch.
        """

        if len(records) == 0:
            raise Error("FastqBatch cannot be empty")

        var batch_size = len(records)
        self._id_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._id_ends = List[Int64](capacity=batch_size)
        self._quality_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._sequence_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._ends = List[Int64](capacity=batch_size)
        self._quality_offset = quality_offset
        for i in range(batch_size):
            self.add(records[i])

    fn add(mut self, record: FastqRecord):
        """Append one FastqRecord to the batch (copies into packed buffers)."""

        self._quality_bytes.extend(record.quality.as_span())
        self._sequence_bytes.extend(record.sequence.as_span())
        self._id_bytes.extend(record.id.as_span())

        if self.num_records() == 0:
            self._id_ends.append(Int64(len(record.id)))
            self._ends.append(Int64(len(record.quality)))
        else:
            self._id_ends.append(Int64(len(record.id))+ self._id_ends[- 1])
            self._ends.append(Int64(len(record.quality)) + self._ends[- 1])

    fn add[origin: Origin[mut=True]](mut self, record: RefRecord[origin]):
        """Append one RefRecord to the batch (copies into packed buffers; no FastqRecord allocation)."""

        self._quality_bytes.extend(record.quality)
        self._sequence_bytes.extend(record.sequence)
        self._id_bytes.extend(record.id)

        if self.num_records() == 0:
            self._id_ends.append(Int64(len(record.id)))
            self._ends.append(Int64(len(record.quality)))
        else:
            self._id_ends.append(Int64(len(record.id))+ self._id_ends[- 1])
            self._ends.append(Int64(len(record.quality)) + self._ends[- 1])

    fn to_device(self, ctx: DeviceContext) raises -> DeviceFastqBatch:
        """Upload this batch to the device (id, sequence, and quality together).
        """
        return upload_batch_to_device(self, ctx)

    fn stage(self, ctx: DeviceContext) raises -> StagedFastqBatch:
        """Stage batch into pinned host memory for fast device transfer."""
        return stage_batch_to_host(self, ctx)

    fn num_records(self) -> Int:
        """Return the number of records in the batch."""
        return len(self._ends)

    fn seq_len(self) -> Int:
        """Return total length of all sequence bytes in the batch."""
        return Int(self._ends[-1])

    fn quality_offset(self) -> UInt8:
        """Return the Phred quality offset (33 or 64) for this batch."""
        return self._quality_offset

    fn __len__(self) -> Int:
        """Return the number of records (same as `num_records()`)."""
        return self.num_records()

    fn __repr__(self) -> String:
        """Return a string representation for Python/Representable."""
        return "FastqBatch(records=" + String(self.num_records()) + ", quality_offset=" + String(self._quality_offset) + ")"

    fn get_record(self, index: Int) raises -> FastqRecord:
        """
        Return the record at the given index as a `FastqRecord`.
        Bounds-checked; raises if index < 0 or index >= `num_records()`.
        """
        var n = self.num_records()
        if index < 0 or index >= n:
            raise Error("FastqBatch.get_record index out of range")

        fn get_offsets(ends: List[Int64], idx: Int) -> Tuple[Int, Int]:
            var start = Int(0) if idx == 0 else Int(ends[idx - 1])
            var end = Int(ends[idx])
            return start, end

        fn unsafe_span_to_ascii_string[
            origin: Origin
        ](bs: Span[Byte, origin]) -> ASCIIString:
            var len_bs = len(bs)
            var new_ptr = (
                bs.unsafe_ptr()
                .unsafe_mut_cast[True]()
                .unsafe_origin_cast[MutExternalOrigin]()
            )
            var span = Span[Byte, MutExternalOrigin](ptr=new_ptr, length=len_bs)
            return ASCIIString(span)

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

    fn get_ref(self, index: Int) raises -> RefRecord[origin_of(self)]:
        """
        Return the record at the given index as a zero-copy `RefRecord`.
        Bounds-checked; raises if index < 0 or index >= `num_records()`.
        The returned `RefRecord` references the batch's internal buffers.
        """
        var n = self.num_records()
        if index < 0 or index >= n:
            raise Error("FastqBatch.get_ref index out of range")

        fn get_offsets(ends: List[Int64], idx: Int) -> Tuple[Int, Int]:
            var start = Int(0) if idx == 0 else Int(ends[idx - 1])
            var end = Int(ends[idx])
            return start, end

        var id_range = get_offsets(self._id_ends, index)
        var range = get_offsets(self._ends, index)

        # Create spans directly from list data
        var id_span = Span[Byte, origin_of(self)](
            ptr=self._id_bytes.unsafe_ptr().unsafe_origin_cast[
                origin_of(self)
            ]()
            + id_range[0],
            length=id_range[1] - id_range[0],
        )
        var seq_span = Span[Byte, origin_of(self)](
            ptr=self._sequence_bytes.unsafe_ptr().unsafe_origin_cast[
                origin_of(self)
            ]()
            + range[0],
            length=range[1] - range[0],
        )
        var qual_span = Span[Byte, origin_of(self)](
            ptr=self._quality_bytes.unsafe_ptr().unsafe_origin_cast[
                origin_of(self)
            ]()
            + range[0],
            length=range[1] - range[0],
        )

        return RefRecord[origin = origin_of(self)](
            id_span,
            seq_span,
            qual_span,
            UInt8(self._quality_offset),
        )

    fn to_records(self) raises -> List[FastqRecord]:
        """
        Reconstruct a List[FastqRecord] from the batch's SoA arrays.
        """
        var n = self.num_records()
        var out = List[FastqRecord](capacity=n)
        for i in range(n):
            out.append(self.get_record(i))
        return out^

    fn write_to(self, mut w: Some[Writer]) raises:
        """Write each record in FASTQ format (4 lines per record) to the given writer."""
        for i in range(self.num_records()):
            self.get_ref(i).write_to(w)


@fieldwise_init
struct DeviceFastqBatch(ImplicitlyDestructible, Movable):
    """
    Device-side representation of a FastqBatch after upload_batch_to_device().
    
    Holds device buffers for id, sequence, quality, and offset arrays, plus
    num_records, seq_len, quality_offset. Use for GPU kernels (e.g. quality
    prefix-sum). copy_to_host() brings data back to a FastqBatch.
    """

    var num_records: Int
    var seq_len: Int64
    var quality_offset: UInt8
    var total_id_bytes: Int64
    var qual_buffer: DeviceBuffer[DType.uint8]
    var sequence_buffer: DeviceBuffer[DType.uint8]
    var ends: DeviceBuffer[DType.int64]
    var id_buffer: DeviceBuffer[DType.uint8]
    var id_ends: DeviceBuffer[DType.int64]

    fn copy_to_host(self, ctx: DeviceContext) raises -> FastqBatch:
        """Copy device buffers back to host and return a FastqBatch."""

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

        batch._id_bytes = List[UInt8](capacity=Int(self.total_id_bytes))
        batch._id_ends = List[Int64](capacity=self.num_records)
        batch._id_bytes.extend(staged.id_data.as_span())
        batch._id_ends.extend(staged.id_ends.as_span())

        return batch^

    fn to_records(self, ctx: DeviceContext) raises -> List[FastqRecord]:
        """Copy device batch to host and convert to a list of `FastqRecord`s."""
        return self.copy_to_host(ctx).to_records()


@doc_private
@fieldwise_init
struct StagedFastqBatch:
    """Intermediary host-side storage in pinned memory. Id, sequence, and quality are always present.
    """

    # Metadata
    var num_records: Int
    var total_seq_bytes: Int64
    var total_id_bytes: Int64
    var quality_offset: UInt8

    # Data buffers
    var quality_data: HostBuffer[DType.uint8]
    var sequence_data: HostBuffer[DType.uint8]
    var id_data: HostBuffer[DType.uint8]

    # End offsets buffers
    var ends: HostBuffer[DType.int64]
    var id_ends: HostBuffer[DType.int64]

    fn to_device(self, ctx: DeviceContext) raises -> DeviceFastqBatch:
        """Copy staged buffers to device (DMA)."""
        return move_staged_to_device(self, ctx, self.quality_offset)


@doc_private
fn download_device_batch_to_staged(
    device_batch: DeviceFastqBatch, ctx: DeviceContext
) raises -> StagedFastqBatch:
    """Vectorized DMA move from Device to Host Staging."""
    var n = device_batch.num_records
    var total_seq = device_batch.seq_len
    var total_id = device_batch.total_id_bytes

    var quality_data = ctx.enqueue_create_host_buffer[DType.uint8](
        Int(total_seq)
    )
    var ends = ctx.enqueue_create_host_buffer[DType.int64](n)
    var sequence_data = ctx.enqueue_create_host_buffer[DType.uint8](
        Int(total_seq)
    )
    var id_data = ctx.enqueue_create_host_buffer[DType.uint8](
        Int(total_id)
    )
    var id_ends = ctx.enqueue_create_host_buffer[DType.int64](n)
    ctx.synchronize()

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
        ends=ends,
        sequence_data=sequence_data,
        id_data=id_data,
        id_ends=id_ends,
    )


@doc_private
fn stage_batch_to_host(
    batch: FastqBatch, ctx: DeviceContext
) raises -> StagedFastqBatch:
    """Stage batch to pinned host buffers; id, sequence, and quality are always copied.
    """
    var n = batch.num_records()
    var total_bytes = batch.seq_len()
    var total_id_bytes = len(batch._id_bytes)

    var quality_data = ctx.enqueue_create_host_buffer[DType.uint8](total_bytes)
    var sequence_data = ctx.enqueue_create_host_buffer[DType.uint8](total_bytes)
    var id_data = ctx.enqueue_create_host_buffer[DType.uint8](
        total_id_bytes
    )

    var ends = ctx.enqueue_create_host_buffer[DType.int64](n)
    var id_ends = ctx.enqueue_create_host_buffer[DType.int64](n)

    ctx.synchronize()

    memcpy(
        dest=quality_data.as_span().unsafe_ptr(),
        src=batch._quality_bytes.unsafe_ptr(),
        count=total_bytes,
    )
    memcpy(
        dest=ends.as_span().unsafe_ptr(),
        src=batch._ends.unsafe_ptr(),
        count=n,
    )
    memcpy(
        dest=sequence_data.as_span().unsafe_ptr(),
        src=batch._sequence_bytes.unsafe_ptr(),
        count=total_bytes,
    )
    memcpy(
        dest=id_data.as_span().unsafe_ptr(),
        src=batch._id_bytes.unsafe_ptr(),
        count=total_id_bytes,
    )
    memcpy(
        dest=id_ends.as_span().unsafe_ptr(),
        src=batch._id_ends.unsafe_ptr(),
        count=n,
    )

    return StagedFastqBatch(
        num_records=n,
        total_seq_bytes=total_bytes,
        total_id_bytes=total_id_bytes,
        quality_offset=batch.quality_offset(),
        quality_data=quality_data,
        ends=ends,
        sequence_data=sequence_data,
        id_data=id_data,
        id_ends=id_ends,
    )


@doc_private
fn move_staged_to_device(
    staged: StagedFastqBatch, ctx: DeviceContext, quality_offset: UInt8
) raises -> DeviceFastqBatch:
    var quality_buffer = ctx.enqueue_create_buffer[DType.uint8](
        Int(staged.total_seq_bytes)
    )
    var ends_buffer = ctx.enqueue_create_buffer[DType.int64](
        staged.num_records
    )
    var sequence_buffer = ctx.enqueue_create_buffer[DType.uint8](
        Int(staged.total_seq_bytes)
    )
    var id_buffer = ctx.enqueue_create_buffer[DType.uint8](
        Int(staged.total_id_bytes)
    )
    var id_ends_buffer = ctx.enqueue_create_buffer[DType.int64](
        staged.num_records
    )
    ctx.synchronize()

    ctx.enqueue_copy(src_buf=staged.quality_data, dst_buf=quality_buffer)
    ctx.enqueue_copy(src_buf=staged.ends, dst_buf=ends_buffer)
    ctx.enqueue_copy(src_buf=staged.sequence_data, dst_buf=sequence_buffer)
    ctx.enqueue_copy(src_buf=staged.id_data, dst_buf=id_buffer)
    ctx.enqueue_copy(src_buf=staged.id_ends, dst_buf=id_ends_buffer)

    ctx.synchronize()

    return DeviceFastqBatch(
        num_records=staged.num_records,
        seq_len=staged.total_seq_bytes,
        quality_offset=quality_offset,
        total_id_bytes=staged.total_id_bytes,
        qual_buffer=quality_buffer,
        sequence_buffer=sequence_buffer,
        ends=ends_buffer,
        id_buffer=id_buffer,
        id_ends=id_ends_buffer,
    )


fn upload_batch_to_device(
    batch: FastqBatch,
    ctx: DeviceContext,
) raises -> DeviceFastqBatch:
    """Upload a `FastqBatch` to the GPU. Allocates device buffers and copies id, sequence, and quality.
    
    Args:
        batch: Host-side SoA batch from `parser.batches()` or `next_batch()`.
        ctx: GPU device context for allocation and transfer.
    
    Returns:
        `DeviceFastqBatch`: Device-side buffers and metadata for kernels.
    
    Implementation: Stages through pinned host memory, then enqueues async DMA to device.
    """

    var staged = stage_batch_to_host(batch, ctx)
    return move_staged_to_device(
        staged, ctx, quality_offset=batch.quality_offset()
    )
