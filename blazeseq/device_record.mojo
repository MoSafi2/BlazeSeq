"""Device-compatible Fastq record descriptor and batch for GPU kernels."""

from blazeseq.record import FastqRecord, RefRecord
from blazeseq.byte_string import ByteString
from gpu.host import DeviceContext
from gpu.host.device_context import DeviceBuffer, HostBuffer
from gpu import block_idx, thread_idx
from memory import UnsafePointer, memcpy, Span, alloc
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
    Structure-of-Arrays (SoA) batch format for multiple FASTQ records.
    
    Stores headers, sequences, and qualities in packed byte buffers with
    offset arrays, enabling coalesced GPU access after upload. Use with
    parser.batched() or next_batch(), or build from a list of FastqRecords.
    Implements GpuMovableBatch for upload_to_device().
    
    Use cases: GPU kernels, batch processing.
    
    Example:
        ```mojo
        from blazeseq.parser import FastqParser
        from blazeseq.readers import FileReader
        from pathlib import Path
        var parser = FastqParser[FileReader](FileReader(Path("data.fastq")), "generic")
        for batch in parser.batched():
            _ = batch.num_records()
        ```
    """

    var _header_bytes: List[UInt8]
    var _quality_bytes: List[UInt8]
    var _sequence_bytes: List[UInt8]
    var _header_ends: List[Int64]
    var _qual_ends: List[Int64]
    var _quality_offset: UInt8

    fn __init__(
        out self,
        batch_size: Int = 100,
        avg_record_size: Int = 100,
        quality_offset: UInt8 = 33,
    ):
        """Create an empty batch with preallocated capacity.
        
        Args:
            batch_size: Expected number of records (capacity for offset arrays).
            avg_record_size: Estimated bytes per record for buffer preallocation.
            quality_offset: Phred offset (33 or 64) for the batch.
        """
        self._header_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._header_ends = List[Int64](capacity=batch_size)
        self._quality_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._sequence_bytes = List[UInt8](
            capacity=avg_record_size * batch_size
        )
        self._qual_ends = List[Int64](capacity=batch_size)
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
        self._header_ends = List[Int64](capacity=batch_size)
        self._quality_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._sequence_bytes = List[UInt8](
            capacity=avg_record_size * batch_size
        )
        self._qual_ends = List[Int64](capacity=batch_size)
        self._quality_offset = quality_offset
        for i in range(batch_size):
            self.add(records[i])

    fn add(mut self, record: FastqRecord):
        """Append one FastqRecord to the batch (copies into packed buffers)."""

        current_loaded = self.num_records()
        self._quality_bytes.extend(record.QuStr.as_span())
        self._sequence_bytes.extend(record.SeqStr.as_span())
        self._header_bytes.extend(record.SeqHeader.as_span())

        if current_loaded == 0:
            self._header_ends.append(Int64(len(record.SeqHeader)))
            self._qual_ends.append(Int64(len(record.QuStr)))
        else:
            self._header_ends.append(
                Int64(len(record.SeqHeader))
                + self._header_ends[current_loaded - 1]
            )

            self._qual_ends.append(
                Int64(len(record.QuStr)) + self._qual_ends[current_loaded - 1]
            )

    fn add[origin: Origin[mut=True]](mut self, record: RefRecord[origin]):
        """Append one RefRecord to the batch (copies into packed buffers; no FastqRecord allocation)."""

        current_loaded = self.num_records()
        self._quality_bytes.extend(record.QuStr)
        self._sequence_bytes.extend(record.SeqStr)
        self._header_bytes.extend(record.SeqHeader)

        if current_loaded == 0:
            self._header_ends.append(Int64(len(record.SeqHeader)))
            self._qual_ends.append(Int64(len(record.QuStr)))
        else:
            self._header_ends.append(
                Int64(len(record.SeqHeader))
                + self._header_ends[current_loaded - 1]
            )

            self._qual_ends.append(
                Int64(len(record.QuStr)) + self._qual_ends[current_loaded - 1]
            )

    fn upload_to_device(self, ctx: DeviceContext) raises -> DeviceFastqBatch:
        """Upload this batch to the device (header, sequence, and quality together).
        """
        return upload_batch_to_device(self, ctx)

    fn num_records(self) -> Int:
        """Return the number of records in the batch."""
        return len(self._qual_ends)

    fn seq_len(self) -> Int:
        """Return total length of all sequence bytes in the batch."""
        return len(self._sequence_bytes)

    fn quality_offset(self) -> UInt8:
        """Return the Phred quality offset (33 or 64) for this batch."""
        return self._quality_offset

    fn __len__(self) -> Int:
        """Return the number of records (same as num_records())."""
        return self.num_records()

    fn get_record(self, index: Int) raises -> FastqRecord:
        """
        Return the record at the given index as a FastqRecord.
        Bounds-checked; raises if index < 0 or index >= num_records().
        """
        var n = self.num_records()
        if index < 0 or index >= n:
            raise Error("FastqBatch.get_record index out of range")

        fn get_offsets(ends: List[Int64], idx: Int) -> Tuple[Int, Int]:
            var start = Int(0) if idx == 0 else Int(ends[idx - 1])
            var end = Int(ends[idx])
            return start, end

        fn unsafe_span_to_byte_string[
            origin: Origin
        ](bs: Span[Byte, origin]) -> ByteString:
            var len_bs = len(bs)
            var new_ptr = (
                bs.unsafe_ptr()
                .unsafe_mut_cast[True]()
                .unsafe_origin_cast[MutExternalOrigin]()
            )
            var span = Span[Byte, MutExternalOrigin](ptr=new_ptr, length=len_bs)
            return ByteString(span)

        var header_range = get_offsets(self._header_ends, index)
        var header_bs = self._header_bytes[header_range[0] : header_range[1]]

        var range = get_offsets(self._qual_ends, index)
        var seq_bs = self._sequence_bytes[range[0] : range[1]]
        var qual_bs = self._quality_bytes[range[0] : range[1]]

        var header = unsafe_span_to_byte_string(header_bs)
        var seq = unsafe_span_to_byte_string(seq_bs)
        var qual = unsafe_span_to_byte_string(qual_bs)

        return FastqRecord(
            header^,
            seq^,
            ByteString("+"),
            qual^,
            Int8(self._quality_offset),
        )

    fn get_ref(self, index: Int) raises -> RefRecord[origin_of(self)]:
        """
        Return the record at the given index as a zero-copy RefRecord.
        Bounds-checked; raises if index < 0 or index >= num_records().
        The returned RefRecord references the batch's internal buffers.
        """
        var n = self.num_records()
        if index < 0 or index >= n:
            raise Error("FastqBatch.get_ref index out of range")

        fn get_offsets(ends: List[Int64], idx: Int) -> Tuple[Int, Int]:
            var start = Int(0) if idx == 0 else Int(ends[idx - 1])
            var end = Int(ends[idx])
            return start, end

        var header_range = get_offsets(self._header_ends, index)
        var range = get_offsets(self._qual_ends, index)

        # Create spans directly from list data
        var header_span = Span[Byte, origin_of(self)](
            ptr=self._header_bytes.unsafe_ptr().unsafe_origin_cast[
                origin_of(self)
            ]()
            + header_range[0],
            length=header_range[1] - header_range[0],
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

        # TODO: check for away to eliminate this
        # QuHeader is always "+" in FASTQ format
        var qu_header_ptr = alloc[UInt8](1)
        qu_header_ptr[0] = UInt8(ord("+"))
        var qu_header_span = Span[Byte, origin_of(self)](
            ptr=qu_header_ptr.unsafe_mut_cast[
                origin_of(self).mut
            ]().unsafe_origin_cast[origin_of(self)](),
            length=1,
        )

        return RefRecord[origin = origin_of(self)](
            SeqHeader=header_span,
            SeqStr=seq_span,
            QuHeader=qu_header_span,
            QuStr=qual_span,
            quality_offset=Int8(self._quality_offset),
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

    fn write_to(self, mut w: Some[Writer]) raises:
        """Write each record in FASTQ format (4 lines per record) to the given writer."""
        for i in range(self.num_records()):
            self.get_ref(i).write_to(w)


@fieldwise_init
struct DeviceFastqBatch(ImplicitlyDestructible, Movable):
    """
    Device-side representation of a FastqBatch after upload_batch_to_device().
    
    Holds device buffers for header, sequence, quality, and offset arrays, plus
    num_records, seq_len, quality_offset. Use for GPU kernels (e.g. quality
    prefix-sum). copy_to_host() brings data back to a FastqBatch.
    """

    var num_records: Int
    var seq_len: Int64
    var quality_offset: UInt8
    var total_header_bytes: Int64
    var qual_buffer: DeviceBuffer[DType.uint8]
    var sequence_buffer: DeviceBuffer[DType.uint8]
    var qual_ends: DeviceBuffer[DType.int64]
    var header_buffer: DeviceBuffer[DType.uint8]
    var header_ends: DeviceBuffer[DType.int64]

    fn copy_to_host(self, ctx: DeviceContext) raises -> FastqBatch:
        """Copy device buffers back to host and return a FastqBatch."""

        var staged = download_device_batch_to_staged(self, ctx)
        var batch = FastqBatch(quality_offset=self.quality_offset, batch_size=0)

        batch._quality_bytes = List[UInt8](capacity=Int(staged.total_seq_bytes))
        batch._qual_ends = List[Int64](capacity=staged.num_records)
        batch._quality_bytes.extend(staged.quality_data.as_span())
        batch._qual_ends.extend(staged.quality_ends.as_span())

        batch._sequence_bytes = List[UInt8](
            capacity=Int(staged.total_seq_bytes)
        )
        batch._sequence_bytes.extend(staged.sequence_data.as_span())

        batch._header_bytes = List[UInt8](capacity=Int(self.total_header_bytes))
        batch._header_ends = List[Int64](capacity=self.num_records)
        batch._header_bytes.extend(staged.header_data.as_span())
        batch._header_ends.extend(staged.header_ends.as_span())

        return batch^

    fn to_records(self, ctx: DeviceContext) raises -> List[FastqRecord]:
        """Copy device batch to host and convert to a list of FastqRecords."""
        return self.copy_to_host(ctx).to_records()


@fieldwise_init
struct StagedFastqBatch:
    """Intermediary host-side storage in pinned memory. Header, sequence, and quality are always present.
    """

    # Metadata
    var num_records: Int
    var total_seq_bytes: Int64
    var total_header_bytes: Int64

    # Data buffers
    var quality_data: HostBuffer[DType.uint8]
    var sequence_data: HostBuffer[DType.uint8]
    var header_data: HostBuffer[DType.uint8]

    # End offsets buffers
    var quality_ends: HostBuffer[DType.int64]
    var header_ends: HostBuffer[DType.int64]


fn download_device_batch_to_staged(
    device_batch: DeviceFastqBatch, ctx: DeviceContext
) raises -> StagedFastqBatch:
    """Vectorized DMA move from Device to Host Staging."""
    var n = device_batch.num_records
    var total_seq = device_batch.seq_len
    var total_hdr = device_batch.total_header_bytes

    var quality_data = ctx.enqueue_create_host_buffer[DType.uint8](
        Int(total_seq)
    )
    var quality_ends = ctx.enqueue_create_host_buffer[DType.int64](n)
    var sequence_data = ctx.enqueue_create_host_buffer[DType.uint8](
        Int(total_seq)
    )
    var header_data = ctx.enqueue_create_host_buffer[DType.uint8](
        Int(total_hdr)
    )
    var header_ends = ctx.enqueue_create_host_buffer[DType.int64](n)
    ctx.synchronize()

    ctx.enqueue_copy(src_buf=device_batch.qual_buffer, dst_buf=quality_data)
    ctx.enqueue_copy(src_buf=device_batch.qual_ends, dst_buf=quality_ends)
    ctx.enqueue_copy(
        src_buf=device_batch.sequence_buffer, dst_buf=sequence_data
    )
    ctx.enqueue_copy(src_buf=device_batch.header_buffer, dst_buf=header_data)
    ctx.enqueue_copy(src_buf=device_batch.header_ends, dst_buf=header_ends)

    ctx.synchronize()

    return StagedFastqBatch(
        num_records=n,
        total_seq_bytes=total_seq,
        total_header_bytes=total_hdr,
        quality_data=quality_data,
        quality_ends=quality_ends,
        sequence_data=sequence_data,
        header_data=header_data,
        header_ends=header_ends,
    )


fn stage_batch_to_host(
    batch: FastqBatch, ctx: DeviceContext
) raises -> StagedFastqBatch:
    """Stage batch to pinned host buffers; header, sequence, and quality are always copied.
    """
    var n = batch.num_records()
    var total_bytes = batch.seq_len()
    var total_header_bytes = len(batch._header_bytes)

    var quality_data = ctx.enqueue_create_host_buffer[DType.uint8](total_bytes)
    var sequence_data = ctx.enqueue_create_host_buffer[DType.uint8](total_bytes)
    var header_data = ctx.enqueue_create_host_buffer[DType.uint8](
        total_header_bytes
    )

    var quality_ends = ctx.enqueue_create_host_buffer[DType.int64](n)
    var header_ends = ctx.enqueue_create_host_buffer[DType.int64](n)

    ctx.synchronize()

    memcpy(
        dest=quality_data.as_span().unsafe_ptr(),
        src=batch._quality_bytes.unsafe_ptr(),
        count=total_bytes,
    )
    memcpy(
        dest=quality_ends.as_span().unsafe_ptr(),
        src=batch._qual_ends.unsafe_ptr(),
        count=n,
    )
    memcpy(
        dest=sequence_data.as_span().unsafe_ptr(),
        src=batch._sequence_bytes.unsafe_ptr(),
        count=total_bytes,
    )
    memcpy(
        dest=header_data.as_span().unsafe_ptr(),
        src=batch._header_bytes.unsafe_ptr(),
        count=total_header_bytes,
    )
    memcpy(
        dest=header_ends.as_span().unsafe_ptr(),
        src=batch._header_ends.unsafe_ptr(),
        count=n,
    )

    return StagedFastqBatch(
        num_records=n,
        total_seq_bytes=total_bytes,
        total_header_bytes=total_header_bytes,
        quality_data=quality_data,
        quality_ends=quality_ends,
        sequence_data=sequence_data,
        header_data=header_data,
        header_ends=header_ends,
    )


fn move_staged_to_device(
    staged: StagedFastqBatch, ctx: DeviceContext, quality_offset: UInt8
) raises -> DeviceFastqBatch:
    var quality_buffer = ctx.enqueue_create_buffer[DType.uint8](
        Int(staged.total_seq_bytes)
    )
    var quality_ends_buffer = ctx.enqueue_create_buffer[DType.int64](
        staged.num_records
    )
    var sequence_buffer = ctx.enqueue_create_buffer[DType.uint8](
        Int(staged.total_seq_bytes)
    )
    var header_buffer = ctx.enqueue_create_buffer[DType.uint8](
        Int(staged.total_header_bytes)
    )
    var header_ends_buffer = ctx.enqueue_create_buffer[DType.int64](
        staged.num_records
    )
    ctx.synchronize()

    ctx.enqueue_copy(src_buf=staged.quality_data, dst_buf=quality_buffer)
    ctx.enqueue_copy(src_buf=staged.quality_ends, dst_buf=quality_ends_buffer)
    ctx.enqueue_copy(src_buf=staged.sequence_data, dst_buf=sequence_buffer)
    ctx.enqueue_copy(src_buf=staged.header_data, dst_buf=header_buffer)
    ctx.enqueue_copy(src_buf=staged.header_ends, dst_buf=header_ends_buffer)

    ctx.synchronize()

    return DeviceFastqBatch(
        num_records=staged.num_records,
        seq_len=staged.total_seq_bytes,
        quality_offset=quality_offset,
        total_header_bytes=staged.total_header_bytes,
        qual_buffer=quality_buffer,
        sequence_buffer=sequence_buffer,
        qual_ends=quality_ends_buffer,
        header_buffer=header_buffer,
        header_ends=header_ends_buffer,
    )


fn upload_batch_to_device(
    batch: FastqBatch,
    ctx: DeviceContext,
) raises -> DeviceFastqBatch:
    """Upload a FastqBatch to the GPU. Allocates device buffers and copies header, sequence, and quality.
    
    Args:
        batch: Host-side SoA batch from parser.batched() or next_batch().
        ctx: GPU device context for allocation and transfer.
    
    Returns:
        DeviceFastqBatch: Device-side buffers and metadata for kernels.
    
    Implementation: Stages through pinned host memory, then enqueues async DMA to device.
    """

    var staged = stage_batch_to_host(batch, ctx)
    return move_staged_to_device(
        staged, ctx, quality_offset=batch.quality_offset()
    )
