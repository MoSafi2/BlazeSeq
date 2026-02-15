"""Device-compatible Fastq record descriptor and batch for GPU kernels."""

from blazeseq.record import FastqRecord
from blazeseq.byte_string import ByteString
from gpu.host import DeviceContext
from gpu.host.device_context import DeviceBuffer, HostBuffer
from gpu import block_idx, thread_idx
from memory import UnsafePointer, memcpy
from collections.string import String


# ---------------------------------------------------------------------------
# Trait for host-side batches that can be uploaded to the device
# ---------------------------------------------------------------------------


trait GpuMovableBatch:
    """Host-side batch type that can be moved to the device. Header, sequence, and quality are always uploaded.
    """

    fn num_records(self) -> Int:
        ...

    fn upload_to_device(self, ctx: DeviceContext) raises -> DeviceFastqBatch:
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
    var _quality_bytes: List[UInt8]
    var _sequence_bytes: List[UInt8]
    var _header_ends: List[Int]
    var _qual_ends: List[Int]
    var _quality_offset: UInt8

    fn __init__(
        out self,
        batch_size: Int = 100,
        avg_record_size: Int = 100,
        quality_offset: UInt8 = 33,
    ):
        self._header_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._header_ends = List[Int](capacity=batch_size)
        self._quality_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._sequence_bytes = List[UInt8](
            capacity=avg_record_size * batch_size
        )
        self._qual_ends = List[Int](capacity=batch_size)
        self._quality_offset = quality_offset

    fn __init__(
        out self,
        records: List[FastqRecord],
        avg_record_size: Int = 100,
        quality_offset: UInt8 = 33,
    ) raises:
        """
        Build a FastqBatch from a list of FastqRecords in one shot.
        Uses the first record's quality_offset for the batch; empty list yields an empty batch.
        """

        if len(records) == 0:
            raise Error("FastqBatch cannot be empty")

        var batch_size = len(records)
        self._header_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._header_ends = List[Int](capacity=batch_size)
        self._quality_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._sequence_bytes = List[UInt8](
            capacity=avg_record_size * batch_size
        )
        self._qual_ends = List[Int](capacity=batch_size)
        self._quality_offset = quality_offset
        for i in range(batch_size):
            self.add(records[i])

    # TODO: Make this more performanant.
    # Potential Bug: Quality ends and Header ends are not running sums but just the length of the current record.
    fn add(mut self, record: FastqRecord):
        """
        Append one FastqRecord: copy its QuStr and SeqStr bytes into the
        packed buffers and record the cumulative quality length for offsets.
        Uses the record's quality_schema.OFFSET for the first record only.
        """

        current_loaded = self.num_records()
        self._quality_bytes.extend(record.QuStr.as_span())
        self._sequence_bytes.extend(record.SeqStr.as_span())
        self._header_bytes.extend(record.SeqHeader.as_span())

        if current_loaded == 0:
            self._header_ends.append(Int(len(self._header_bytes)))
            self._qual_ends.append(Int(len(self._quality_bytes)))
        else:
            self._header_ends.append(
                Int(
                    len(self._header_bytes)
                    + self._header_ends[current_loaded - 1]
                )
            )
            self._qual_ends.append(
                Int(
                    len(self._quality_bytes)
                    + self._qual_ends[current_loaded - 1]
                )
            )

    fn upload_to_device(self, ctx: DeviceContext) raises -> DeviceFastqBatch:
        """Upload this batch to the device (header, sequence, and quality together).
        """
        return upload_batch_to_device(self, ctx)

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
        When header data is not present (e.g. batch from copy_to_host with
        QUALITY_AND_SEQUENCE), synthesizes a header "@0", "@1", ... per record.
        """
        var n = self.num_records()
        if index < 0 or index >= n:
            raise Error("FastqBatch.get_record index out of range")
        var qual_start = 0 if index == 0 else Int(self._qual_ends[index - 1])
        var qual_end = Int(self._qual_ends[index])
        var seg_len = qual_end - qual_start

        # Header: use stored bytes if present, else synthesize "@index"
        var header_bs: ByteString
        if len(self._header_ends) == n:
            var header_start = 0 if index == 0 else Int(
                self._header_ends[index - 1]
            )
            var header_end = Int(self._header_ends[index])
            var header_len = header_end - header_start
            header_bs = ByteString(capacity=header_len)
            for j in range(header_len):
                header_bs[j] = self._header_bytes[header_start + j]
        else:
            header_bs = ByteString("@" + String(index))

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
struct DeviceFastqBatch(ImplicitlyDestructible, Movable):
    """
    Device-side buffers and metadata after upload. Holds device buffers and
    num_records / quality_offset for launching the prefix-sum kernel.
    Header, sequence, and quality bytes are always present (full payload).
    """

    var num_records: Int
    var seq_len: Int
    var quality_offset: UInt8
    var total_header_bytes: Int
    var qual_buffer: DeviceBuffer[DType.uint8]
    var sequence_buffer: DeviceBuffer[DType.uint8]
    var offsets_buffer: DeviceBuffer[DType.int]
    var header_buffer: DeviceBuffer[DType.uint8]
    var header_ends: DeviceBuffer[DType.int]

    fn copy_to_host(self, ctx: DeviceContext) raises -> FastqBatch:
        """Copy device buffers to host and return a FastqBatch."""

        var staged = download_device_batch_to_staged(self, ctx)
        var batch = FastqBatch(quality_offset=self.quality_offset, batch_size=0)

        batch._quality_bytes = List[UInt8](capacity=staged.total_seq_bytes)
        batch._qual_ends = List[Int](capacity=staged.num_records)
        batch._quality_bytes.extend(staged.quality_data_host.as_span())
        batch._qual_ends.extend(staged.quality_ends_host.as_span())

        batch._sequence_bytes = List[UInt8](capacity=staged.total_seq_bytes)
        batch._sequence_bytes.extend(staged.sequence_data_host.as_span())

        batch._header_bytes = List[UInt8](capacity=self.total_header_bytes)
        batch._header_ends = List[Int](capacity=self.num_records)
        batch._header_bytes.extend(staged.header_data_host.as_span())
        batch._header_ends.extend(staged.header_ends_host.as_span())

        return batch^

    fn to_records(self, ctx: DeviceContext) raises -> List[FastqRecord]:
        """Copy device buffers to host and return a list of FastqRecords."""
        return self.copy_to_host(ctx).to_records()


@fieldwise_init
struct StagedFastqBatch:
    """Intermediary host-side storage in pinned memory. Header, sequence, and quality are always present.
    """

    var num_records: Int
    var total_seq_bytes: Int

    # Semantic naming: [component]_[type]_[location]
    var quality_data_host: HostBuffer[DType.uint8]
    var quality_ends_host: HostBuffer[DType.int]
    var sequence_data_host: HostBuffer[DType.uint8]
    var header_data_host: HostBuffer[DType.uint8]
    var header_ends_host: HostBuffer[DType.int]


fn download_device_batch_to_staged(
    device_batch: DeviceFastqBatch, ctx: DeviceContext
) raises -> StagedFastqBatch:
    """Vectorized DMA move from Device to Host Staging."""
    var n = device_batch.num_records
    var total_seq = device_batch.seq_len
    var total_hdr = device_batch.total_header_bytes

    var quality_data_host = ctx.enqueue_create_host_buffer[DType.uint8](
        total_seq
    )
    var quality_ends_host = ctx.enqueue_create_host_buffer[DType.int32](n)
    var sequence_data_host = ctx.enqueue_create_host_buffer[DType.uint8](
        total_seq
    )
    var header_data_host = ctx.enqueue_create_host_buffer[DType.uint8](
        total_hdr
    )
    var header_ends_host = ctx.enqueue_create_host_buffer[DType.int32](n)

    ctx.enqueue_copy(device_batch.qual_buffer, quality_data_host)
    ctx.enqueue_copy(device_batch.offsets_buffer, quality_ends_host)
    ctx.enqueue_copy(device_batch.sequence_buffer, sequence_data_host)
    ctx.enqueue_copy(device_batch.header_buffer, header_data_host)
    ctx.enqueue_copy(device_batch.header_ends, header_ends_host)

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


fn stage_batch_to_host(
    batch: FastqBatch, ctx: DeviceContext
) raises -> StagedFastqBatch:
    """Stage batch to pinned host buffers; header, sequence, and quality are always copied.
    """
    var n = batch.num_records()
    var total_bytes = batch.seq_len()
    var total_header_bytes = Int(batch._header_ends[n - 1]) if n > 0 else 0

    var quality_data_host = ctx.enqueue_create_host_buffer[DType.uint8](
        total_bytes
    )
    var quality_ends_host = ctx.enqueue_create_host_buffer[DType.int32](n)
    var sequence_data_host = ctx.enqueue_create_host_buffer[DType.uint8](
        total_bytes
    )
    var header_data_host = ctx.enqueue_create_host_buffer[DType.uint8](
        total_header_bytes
    )
    var header_ends_host = ctx.enqueue_create_host_buffer[DType.int32](n)

    ctx.synchronize()

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
    memcpy(
        dest=sequence_data_host.as_span().unsafe_ptr(),
        src=batch._sequence_bytes.unsafe_ptr(),
        count=total_bytes,
    )
    memcpy(
        dest=header_data_host.as_span().unsafe_ptr(),
        src=batch._header_bytes.unsafe_ptr(),
        count=total_header_bytes,
    )
    memcpy(
        dest=header_ends_host.as_span().unsafe_ptr(),
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
    var quality_buffer = ctx.enqueue_create_buffer[DType.uint8](
        staged.total_seq_bytes
    )
    var quality_ends_buffer = ctx.enqueue_create_buffer[DType.int32](
        staged.num_records
    )
    var sequence_buffer = ctx.enqueue_create_buffer[DType.uint8](
        staged.total_seq_bytes
    )
    var header_buffer = ctx.enqueue_create_buffer[DType.uint8](
        len(staged.header_data_host)
    )
    var header_ends_buffer = ctx.enqueue_create_buffer[DType.int32](
        staged.num_records
    )

    ctx.enqueue_copy(src_buf=staged.quality_data_host, dst_buf=quality_buffer)
    ctx.enqueue_copy(
        src_buf=staged.quality_ends_host, dst_buf=quality_ends_buffer
    )
    ctx.enqueue_copy(src_buf=staged.sequence_data_host, dst_buf=sequence_buffer)
    ctx.enqueue_copy(src_buf=staged.header_data_host, dst_buf=header_buffer)
    ctx.enqueue_copy(
        src_buf=staged.header_ends_host, dst_buf=header_ends_buffer
    )

    ctx.synchronize()

    return DeviceFastqBatch(
        num_records=staged.num_records,
        seq_len=staged.total_seq_bytes,
        quality_offset=quality_offset,
        total_header_bytes=len(staged.header_data_host),
        qual_buffer=quality_buffer,
        sequence_buffer=sequence_buffer,
        offsets_buffer=quality_ends_buffer,
        header_buffer=header_buffer,
        header_ends=header_ends_buffer,
    )


fn upload_batch_to_device(
    batch: FastqBatch,
    ctx: DeviceContext,
) raises -> DeviceFastqBatch:
    """
    Allocates device buffers and moves batch data to the GPU by staging through host memory.
    Header, sequence, and quality bytes are always uploaded together.

    This implementation splits the work into two distinct phases:
    1. Staging: CPU-driven memcpy from standard List memory to DMA-accessible HostBuffers.
    2. Dispatching: Enqueueing asynchronous DMA transfers from Host to Device.
    """

    var staged = stage_batch_to_host(batch, ctx)
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
