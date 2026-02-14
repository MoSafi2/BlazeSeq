"""Device-compatible Fastq record descriptor and batch for GPU kernels."""

from blazeseq.record import FastqRecord
from blazeseq.byte_string import ByteString
from gpu.host import DeviceContext
from gpu.host.device_context import DeviceBuffer, HostBuffer
from gpu import block_idx, thread_idx
from memory import UnsafePointer, memcpy
from collections.string import String


# ---------------------------------------------------------------------------
# GPU batch payload: what gets uploaded to device
# ---------------------------------------------------------------------------


# TODO: Eventually replace with an Enum when mojo gets those.
@fieldwise_init
struct GPUPayload(Equatable, ImplicitlyCopyable):
    var _value: Int

    comptime QUALITY_ONLY = GPUPayload(0)
    comptime SEQUENCE_ONLY = GPUPayload(1)
    comptime HEADER_ONLY = GPUPayload(2)
    comptime QUALITY_AND_SEQUENCE = GPUPayload(3)
    comptime FULL = GPUPayload(4)

    fn __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    fn __ne__(self, other: Self) -> Bool:
        return not (self == other)

    fn __ge__(self, other: Self) -> Bool:
        return self._value >= other._value


# ---------------------------------------------------------------------------
# Trait for host-side batches that can be uploaded to the device
# ---------------------------------------------------------------------------


trait GpuMovableBatch:
    """Host-side batch type that can be moved to the device with a chosen payload.
    """

    fn num_records(self) -> Int:
        ...

    fn upload_to_device(
        self, ctx: DeviceContext, payload: GPUPayload = GPUPayload.QUALITY_ONLY
    ) raises -> DeviceFastqBatch:
        ...


# ---------------------------------------------------------------------------
# FastqBatch: Structure-of-Arrays batch format for GPU operations
# ---------------------------------------------------------------------------


struct FastqBatch(Copyable, GpuMovableBatch, ImplicitlyDestructible, Sized):
    """
    Structure-of-Arrays batch format: host-side container that stacks multiple FastqRecords
    into packed quality (and sequence) byte buffers and an offsets index, then uploads to device.
    Optimized for GPU operations with coalesced memory access.
    """

    var _header_bytes: List[UInt8]
    var _header_ends: List[Int32]
    var _quality_bytes: List[UInt8]
    var _sequence_bytes: List[UInt8]
    var _qual_ends: List[Int32]
    var _quality_offset: UInt8

    fn __init__(
        out self,
        batch_size: Int = 100,
        avg_record_size: Int = 100,
        quality_offset: UInt8 = 33,
    ):
        self._header_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._header_ends = List[Int32](capacity=batch_size + 1)
        self._quality_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._sequence_bytes = List[UInt8](
            capacity=avg_record_size * batch_size
        )
        self._qual_ends = List[Int32](capacity=batch_size + 1)
        self._quality_offset = quality_offset

    fn __init__(
        out self,
        records: List[FastqRecord],
        avg_record_size: Int = 100,
        quality_offset: UInt8 = 33,
    ):
        """
        Build a FastqBatch from a list of FastqRecords in one shot.
        Uses the first record's quality_offset for the batch; empty list yields an empty batch.
        """
        var n = len(records)
        var batch_size = max(1, n)
        self._header_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._header_ends = List[Int32](capacity=batch_size + 1)
        self._quality_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._sequence_bytes = List[UInt8](
            capacity=avg_record_size * batch_size
        )
        self._qual_ends = List[Int32](capacity=batch_size + 1)
        self._quality_offset = quality_offset
        for i in range(n):
            self.add(records[i])

    # TODO: Make this more performanant.
    fn add(mut self, record: FastqRecord):
        """
        Append one FastqRecord: copy its QuStr and SeqStr bytes into the
        packed buffers and record the cumulative quality length for offsets.
        Uses the record's quality_schema.OFFSET for the first record only.
        """
        if len(self._qual_ends) == 0:
            self._quality_offset = UInt8(record.quality_offset)

        self._quality_bytes.extend(record.QuStr.as_span())
        self._sequence_bytes.extend(record.SeqStr.as_span())
        self._qual_ends.append(Int32(len(self._quality_bytes)))
        self._header_bytes.extend(record.SeqHeader.as_span())
        self._header_ends.append(Int32(len(self._header_bytes)))

    fn upload_to_device(
        self, ctx: DeviceContext, payload: GPUPayload = GPUPayload.QUALITY_ONLY
    ) raises -> DeviceFastqBatch:
        """Upload this batch to the device with the given payload (GpuMovableBatch).
        """
        return upload_batch_to_device(self, ctx, payload)

    fn num_records(self) -> Int:
        return len(self._qual_ends)

    fn seq_len(self) -> Int:
        return len(self._sequence_bytes)

    fn quality_offset(self) -> UInt8:
        return self._quality_offset

    fn __len__(self) -> Int:
        return self.num_records()

    fn get_record(self, index: Int) raises -> FastqRecord:
        """
        Return the record at the given index as a FastqRecord.
        Bounds-checked; raises if index < 0 or index >= num_records().
        """
        var n = self.num_records()
        if index < 0 or index >= n:
            raise Error("FastqBatch.get_record index out of range")
        var header_start = 0 if index == 0 else Int(
            self._header_ends[index - 1]
        )
        var header_end = Int(self._header_ends[index])
        var header_len = header_end - header_start
        var qual_start = 0 if index == 0 else Int(self._qual_ends[index - 1])
        var qual_end = Int(self._qual_ends[index])
        var seg_len = qual_end - qual_start

        var header_bs = ByteString(capacity=header_len)
        for j in range(header_len):
            header_bs[j] = self._header_bytes[header_start + j]

        var seq_bs = ByteString(capacity=seg_len)
        for j in range(seg_len):
            seq_bs[j] = self._sequence_bytes[qual_start + j]

        var qu_header_bs = ByteString("+")

        var qual_bs = ByteString(capacity=seg_len)
        for j in range(seg_len):
            qual_bs[j] = self._quality_bytes[qual_start + j]

        return FastqRecord(
            header_bs^,
            seq_bs^,
            qu_header_bs^,
            qual_bs^,
            Int8(self._quality_offset),
        )

    fn to_records(self) raises -> List[FastqRecord]:
        """
        Reconstruct a List[FastqRecord] from the batch's SoA arrays.
        QuHeader is set to "+" for each record per FASTQ convention.
        """
        var n = self.num_records()
        var out = List[FastqRecord](capacity=n)
        for i in range(n):
            out.append(self.get_record(i))
        return out^


@fieldwise_init
struct DeviceFastqBatch(Movable, ImplicitlyDestructible):
    """
    Device-side buffers and metadata after upload. Holds device buffers and
    num_records / quality_offset for launching the prefix-sum kernel.
    Quality and offsets are always present; sequence and header buffers are
    optional and set when upload uses quality_and_sequence or full payload.
    """

    var num_records: Int
    var seq_len: Int
    var quality_offset: UInt8
    var total_header_bytes: Optional[Int]
    var qual_buffer: Optional[DeviceBuffer[DType.uint8]]
    var sequence_buffer: Optional[DeviceBuffer[DType.uint8]]
    var offsets_buffer: Optional[DeviceBuffer[DType.int32]]
    var header_buffer: Optional[DeviceBuffer[DType.uint8]]
    var header_ends: Optional[DeviceBuffer[DType.int32]]

    fn copy_to_host(self, ctx: DeviceContext) raises -> FastqBatch:
        """High-level orchestrator for downloading data."""
        if (
            self.qual_buffer is None
            or not self.offsets_buffer
            or not self.sequence_buffer
        ):
            raise Error(
                "copy_to_host requires QUALITY_AND_SEQUENCE payload buffers."
            )

        # Phase 1: DMA Transfer (Fast)
        var staged = download_device_batch_to_staged(self, ctx)
        var batch = FastqBatch(quality_offset=self.quality_offset, batch_size=0)
        has_seq = self.sequence_buffer is not None
        has_header = self.header_buffer is not None

        batch._quality_bytes = List[UInt8](capacity=staged.total_seq_bytes)
        batch._qual_ends = List[Int32](capacity=staged.num_records)
        batch._quality_bytes.extend(staged.quality_data_host.as_span())
        batch._qual_ends.extend(staged.quality_ends_host.as_span())



        if has_seq:
            batch._sequence_bytes = List[UInt8](capacity=staged.total_seq_bytes)
            batch._sequence_bytes.extend(staged.sequence_data_host.value().as_span())

        if has_header:
            batch._header_bytes = List[UInt8](
                capacity=self.total_header_bytes.value()
            )
            batch._header_ends = List[Int32](capacity=self.num_records)
            batch._header_bytes.extend(
                staged.header_data_host.value().as_span()
            )
            batch._header_ends.extend(staged.header_ends_host.value().as_span())


        return batch^

    fn to_records(self, ctx: DeviceContext) raises -> List[FastqRecord]:
        """
        Copy device buffers to host and return a list of FastqRecords.
        Same precondition as copy_to_host (QUALITY_AND_SEQUENCE or FULL).
        """
        return self.copy_to_host(ctx).to_records()


fn download_device_batch_to_staged(
    device_batch: DeviceFastqBatch, ctx: DeviceContext
) raises -> StagedFastqBatch:
    """Vectorized DMA move from Device to Host Staging."""
    var n = device_batch.num_records
    var total_seq = device_batch.seq_len

    # Pre-calculate header size if possible
    var total_hdr: Int = 0
    if device_batch.total_header_bytes is not None:
        total_hdr = device_batch.total_header_bytes.value()

    # 1. Allocate all host staging buffers
    var quality_data_host = ctx.enqueue_create_host_buffer[DType.uint8](
        total_seq
    )
    var quality_ends_host = ctx.enqueue_create_host_buffer[DType.int32](n)
    var sequence_data_host = ctx.enqueue_create_host_buffer[DType.uint8](
        total_seq
    )

    var header_data_host: Optional[HostBuffer[DType.uint8]] = None
    var header_ends_host: Optional[HostBuffer[DType.int32]] = None

    if device_batch.header_buffer is not None:
        header_data_host = ctx.enqueue_create_host_buffer[DType.uint8](
            total_hdr
        )
        header_ends_host = ctx.enqueue_create_host_buffer[DType.int32](n)

    # 2. Enqueue all async copies
    ctx.enqueue_copy(device_batch.qual_buffer.value(), quality_data_host)
    ctx.enqueue_copy(device_batch.offsets_buffer.value(), quality_ends_host)
    ctx.enqueue_copy(device_batch.sequence_buffer.value(), sequence_data_host)

    if header_data_host:
        ctx.enqueue_copy(
            device_batch.header_buffer.value(), header_data_host.value()
        )
        ctx.enqueue_copy(
            device_batch.header_ends.value(), header_ends_host.value()
        )

    ctx.synchronize()

    return StagedFastqBatch(
        num_records=n,
        total_seq_bytes=total_seq,
        quality_data_host=quality_data_host,
        quality_ends_host=quality_ends_host,
        sequence_data_host=sequence_data_host,
        header_data_host=header_data_host,
        header_ends_host=header_ends_host,
    )


@fieldwise_init
struct StagedFastqBatch:
    """Intermediary host-side storage in pinned memory."""

    var num_records: Int
    var total_seq_bytes: Int

    # Semantic naming: [component]_[type]_[location]
    var quality_data_host: HostBuffer[DType.uint8]
    var quality_ends_host: HostBuffer[DType.int32]
    var sequence_data_host: Optional[HostBuffer[DType.uint8]]
    var header_data_host: Optional[HostBuffer[DType.uint8]]
    var header_ends_host: Optional[HostBuffer[DType.int32]]


fn stage_batch_to_host(
    batch: FastqBatch, ctx: DeviceContext, payload: GPUPayload
) raises -> StagedFastqBatch:
    var n = batch.num_records()
    var total_bytes = batch.seq_len()

    var include_sequence = payload >= GPUPayload.QUALITY_AND_SEQUENCE
    var include_full = payload >= GPUPayload.FULL and n > 0
    var total_header_bytes = Int(
        batch._header_ends[n - 1]
    ) if include_full else 0

    # Allocation phase
    var quality_data_host = ctx.enqueue_create_host_buffer[DType.uint8](
        total_bytes
    )
    var quality_ends_host = ctx.enqueue_create_host_buffer[DType.int32](n)

    var sequence_data_host: Optional[HostBuffer[DType.uint8]] = None
    if include_sequence:
        sequence_data_host = ctx.enqueue_create_host_buffer[DType.uint8](
            total_bytes
        )

    var header_data_host: Optional[HostBuffer[DType.uint8]] = None
    var header_ends_host: Optional[HostBuffer[DType.int32]] = None
    if include_full:
        header_data_host = ctx.enqueue_create_host_buffer[DType.uint8](
            total_header_bytes
        )
        header_ends_host = ctx.enqueue_create_host_buffer[DType.int32](n)

    ctx.synchronize()

    # High-speed memory copy phase
    memcpy(
        dest=quality_data_host.as_span().unsafe_ptr(),
        src=batch._quality_bytes.unsafe_ptr(),
        count=total_bytes,
    )
    memcpy(
        dest=quality_ends_host.as_span().unsafe_ptr(),
        src=batch._qual_ends.unsafe_ptr(),
        count=n,
    )

    if include_sequence:
        memcpy(
            dest=sequence_data_host.value().as_span().unsafe_ptr(),
            src=batch._sequence_bytes.unsafe_ptr(),
            count=total_bytes,
        )

    if include_full:
        memcpy(
            dest=header_data_host.value().as_span().unsafe_ptr(),
            src=batch._header_bytes.unsafe_ptr(),
            count=total_header_bytes,
        )
        memcpy(
            dest=header_ends_host.value().as_span().unsafe_ptr(),
            src=batch._header_ends.unsafe_ptr(),
            count=n,
        )

    return StagedFastqBatch(
        num_records=n,
        total_seq_bytes=total_bytes,
        quality_data_host=quality_data_host,
        quality_ends_host=quality_ends_host,
        sequence_data_host=sequence_data_host,
        header_data_host=header_data_host,
        header_ends_host=header_ends_host,
    )


fn move_staged_to_device(
    staged: StagedFastqBatch, ctx: DeviceContext, quality_offset: UInt8
) raises -> DeviceFastqBatch:
    # 1. Create Device Buffers
    var quality_buffer = ctx.enqueue_create_buffer[DType.uint8](
        staged.total_seq_bytes
    )
    var quality_ends_buffer = ctx.enqueue_create_buffer[DType.int32](
        staged.num_records
    )

    # 2. Enqueue DMA Transfers
    ctx.enqueue_copy(src_buf=staged.quality_data_host, dst_buf=quality_buffer)
    ctx.enqueue_copy(
        src_buf=staged.quality_ends_host, dst_buf=quality_ends_buffer
    )

    var sequence_buffer: Optional[DeviceBuffer[DType.uint8]] = None
    if staged.sequence_data_host:
        var db = ctx.enqueue_create_buffer[DType.uint8](staged.total_seq_bytes)
        ctx.enqueue_copy(src_buf=staged.sequence_data_host.value(), dst_buf=db)
        sequence_buffer = db

    var header_buffer: Optional[DeviceBuffer[DType.uint8]] = None
    var header_ends_buffer: Optional[DeviceBuffer[DType.int32]] = None
    if staged.header_data_host and staged.header_ends_host:
        header_buffer = ctx.enqueue_create_buffer[DType.uint8](
            len(staged.header_data_host.value())
        )
        header_ends_buffer = ctx.enqueue_create_buffer[DType.int32](
            staged.num_records
        )

        ctx.enqueue_copy(
            src_buf=staged.header_data_host.value(),
            dst_buf=header_buffer.value(),
        )
        ctx.enqueue_copy(
            src_buf=staged.header_ends_host.value(),
            dst_buf=header_ends_buffer.value(),
        )

    ctx.synchronize()

    var total_header_bytes_val: Optional[Int] = None
    if staged.header_data_host:
        total_header_bytes_val = len(staged.header_data_host.value())

    return DeviceFastqBatch(
        num_records=staged.num_records,
        seq_len=staged.total_seq_bytes,
        quality_offset=quality_offset,
        total_header_bytes=total_header_bytes_val,
        qual_buffer=quality_buffer,
        sequence_buffer=sequence_buffer,
        offsets_buffer=quality_ends_buffer,
        header_buffer=header_buffer,
        header_ends=header_ends_buffer,
    )


fn upload_batch_to_device(
    batch: FastqBatch,
    ctx: DeviceContext,
    payload: GPUPayload = GPUPayload.QUALITY_ONLY,
) raises -> DeviceFastqBatch:
    """
    Allocates device buffers and moves batch data to the GPU by staging through host memory.

    This implementation splits the work into two distinct phases:
    1. Staging: CPU-driven memcpy from standard List memory to DMA-accessible HostBuffers.
    2. Dispatching: Enqueueing asynchronous DMA transfers from Host to Device.
    """

    var staged = stage_batch_to_host(batch, ctx, payload)
    return move_staged_to_device(
        staged, ctx, quality_offset=batch.quality_offset()
    )


# ---------------------------------------------------------------------------
# Subbatch slice upload: fill host buffers from batch slice, upload to device
# ---------------------------------------------------------------------------
#
# Transfer-friendly host storage (Option B): FastqBatch keeps List[UInt8]
# storage. For maximum transfer throughput and to avoid an extra host-side
# copy, use subbatch upload with pre-allocated host buffers: allocate
# HostBuffer(s) once, then repeatedly call fill_subbatch_host_buffers() and
# upload_subbatch_from_host_buffers() (e.g. with double-buffering) so that
# upload is a single enqueue_copy from host buffer to device. See
# examples/example_device.mojo for a full pattern.
# ---------------------------------------------------------------------------


fn main() raises:
    var batch = FastqBatch()
    batch.add(
        FastqRecord(
            "@a",
            "ACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTACGTAC",
            "+",
            "!" * 50,
        )
    )
    batch.add(
        FastqRecord(
            "@b",
            "TGCAATGCAATGCAATGCAATGCAATGCAATGCAATGCAATGCAATCAAT",
            "+",
            "I" * 50,
        )
    )
    batch.add(
        FastqRecord(
            "@c",
            "NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN",
            "+",
            "$" * 50,
        )
    )

    print(batch.get_record(0))
    print(batch.get_record(1))
    print(batch.get_record(2))
    var back_list = batch.to_records()
    for record in back_list:
        print(record)
