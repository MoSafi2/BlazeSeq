"""Device-compatible Fastq record descriptor and batch for GPU kernels."""

from blazeseq.record import FastqRecord
from blazeseq.byte_string import ByteString
from gpu.host import DeviceContext
from gpu.host.device_context import DeviceBuffer, HostBuffer
from gpu import block_idx, thread_idx
from memory import UnsafePointer
from collections.string import String


# ---------------------------------------------------------------------------
# FastqBatch: Structure-of-Arrays batch format for GPU operations
# ---------------------------------------------------------------------------


struct FastqBatch(Copyable, ImplicitlyDestructible, Sized):
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
        self._header_ends = List[Int32](capacity=batch_size * 2)
        self._quality_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._sequence_bytes = List[UInt8](
            capacity=avg_record_size * batch_size
        )
        self._qual_ends = List[Int32](capacity=batch_size * 2)
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
        self._header_ends = List[Int32](capacity=batch_size * 2)
        self._quality_bytes = List[UInt8](capacity=avg_record_size * batch_size)
        self._sequence_bytes = List[UInt8](
            capacity=avg_record_size * batch_size
        )
        self._qual_ends = List[Int32](capacity=batch_size * 2)
        self._quality_offset = quality_offset
        for i in range(n):
            self.add(records[i])

    fn add(mut self, record: FastqRecord):
        """
        Append one FastqRecord: copy its QuStr and SeqStr bytes into the
        packed buffers and record the cumulative quality length for offsets.
        Uses the record's quality_schema.OFFSET for the first record only.
        """
        if len(self._qual_ends) == 0:
            self._quality_offset = UInt8(record.quality_offset)
        for i in range(len(record.QuStr)):
            self._quality_bytes.append(record.QuStr[i])
        for i in range(len(record.SeqStr)):
            self._sequence_bytes.append(record.SeqStr[i])
        self._qual_ends.append(Int32(len(self._quality_bytes)))

        for i in range(len(record.SeqHeader)):
            self._header_bytes.append(record.SeqHeader[i])
        self._header_ends.append(Int32(len(self._header_bytes)))

    fn num_records(self) -> Int:
        return len(self._qual_ends)

    fn total_quality_len(self) -> Int:
        return len(self._quality_bytes)

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
struct DeviceFastqBatch:
    """
    Device-side buffers and metadata after upload. Holds device buffers and
    num_records / quality_offset for launching the prefix-sum kernel.
    """

    var qual_buffer: DeviceBuffer[DType.uint8]
    var offsets_buffer: DeviceBuffer[DType.int32]
    var num_records: Int
    var total_quality_len: Int
    var quality_offset: UInt8


fn upload_batch_to_device(
    batch: FastqBatch, ctx: DeviceContext
) raises -> DeviceFastqBatch:
    """
    Allocate device buffers and copy batch data to the given DeviceContext.
    Returns a handle holding device buffers and metadata for kernel launch.
    """
    var total_qual = batch.total_quality_len()
    var n = batch.num_records()
    var qual_buf = ctx.enqueue_create_buffer[DType.uint8](total_qual)
    var offsets_buf = ctx.enqueue_create_buffer[DType.int32](n + 1)

    var host_qual = ctx.enqueue_create_host_buffer[DType.uint8](total_qual)
    var host_offs = ctx.enqueue_create_host_buffer[DType.int32](n + 1)
    ctx.synchronize()

    for i in range(total_qual):
        host_qual[i] = batch._quality_bytes[i]

    host_offs[0] = 0
    for i in range(n):
        host_offs[i + 1] = batch._qual_ends[i]
    ctx.enqueue_copy(src_buf=host_qual, dst_buf=qual_buf)
    ctx.enqueue_copy(src_buf=host_offs, dst_buf=offsets_buf)

    return DeviceFastqBatch(
        qual_buffer=qual_buf,
        offsets_buffer=offsets_buf,
        num_records=n,
        total_quality_len=total_qual,
        quality_offset=batch.quality_offset(),
    )


# ---------------------------------------------------------------------------
# Subbatch slice upload: fill host buffers from batch slice, upload to device
# ---------------------------------------------------------------------------


fn fill_subbatch_host_buffers(
    batch: FastqBatch,
    start_rec: Int,
    end_rec: Int,
    host_qual: HostBuffer[DType.uint8],
    host_offs: HostBuffer[DType.int32],
) raises -> None:
    """
    Fill pre-allocated host buffers with the quality bytes and offsets for
    the record range [start_rec, end_rec). Offsets are 0-based relative to
    the slice. Caller must ensure host_qual has size >= total_qual and
    host_offs has size >= (end_rec - start_rec) + 1.
    """
    var qual_start = 0 if start_rec == 0 else Int(
        batch._qual_ends[start_rec - 1]
    )
    var qual_end = Int(batch._qual_ends[end_rec - 1])
    var total_qual = qual_end - qual_start
    var n = end_rec - start_rec

    for i in range(total_qual):
        host_qual[i] = batch._quality_bytes[qual_start + i]

    host_offs[0] = 0
    for i in range(n):
        host_offs[i + 1] = batch._qual_ends[start_rec + i] - Int32(qual_start)


fn upload_subbatch_from_host_buffers(
    host_qual: HostBuffer[DType.uint8],
    host_offs: HostBuffer[DType.int32],
    n: Int,
    total_qual: Int,
    quality_offset: UInt8,
    ctx: DeviceContext,
) raises -> DeviceFastqBatch:
    """
    Allocate device buffers and enqueue copy from the given host buffers.
    Does not synchronize; caller may overlap with other work.
    """
    var qual_buf = ctx.enqueue_create_buffer[DType.uint8](total_qual)
    var offsets_buf = ctx.enqueue_create_buffer[DType.int32](n + 1)
    ctx.enqueue_copy(src_buf=host_qual, dst_buf=qual_buf)
    ctx.enqueue_copy(src_buf=host_offs, dst_buf=offsets_buf)
    return DeviceFastqBatch(
        qual_buffer=qual_buf,
        offsets_buffer=offsets_buf,
        num_records=n,
        total_quality_len=total_qual,
        quality_offset=quality_offset,
    )
