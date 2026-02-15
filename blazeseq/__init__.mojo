"""BlazeSeq: fast FASTQ parsing and GPU batch types."""

from blazeseq.record import FastqRecord, RecordCoord, Validator
from blazeseq.parser import RecordParser, ParserConfig, BatchedParser
from blazeseq.device_record import (
    FastqBatch,
    upload_batch_to_device,
)
from blazeseq.kernels.prefix_sum import enqueue_quality_prefix_sum
from blazeseq.kernels.qc import (
    enqueue_batch_average_quality,
    BatchAverageQualityResult,
    enqueue_quality_distribution,
    QualityDistributionResult,
    QualityDistributionHostResult,
    QualityDistributionBatchedAccumulator,
    cpu_quality_distribution,
)
from blazeseq.iostream import BufferedReader, Reader, LineIterator
from blazeseq.readers import FileReader, MemoryReader
from blazeseq.utils import generate_synthetic_fastq_buffer
