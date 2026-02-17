"""BlazeSeq: fast FASTQ parsing and GPU batch types."""

from blazeseq.record import FastqRecord, RefRecord, Validator
from blazeseq.parser import RecordParser, ParserConfig, BatchedParser
from blazeseq.device_record import (
    FastqBatch,
    upload_batch_to_device,
)
from blazeseq.iostream import BufferedReader, Reader, LineIterator
from blazeseq.readers import FileReader, MemoryReader
from blazeseq.utils import generate_synthetic_fastq_buffer
