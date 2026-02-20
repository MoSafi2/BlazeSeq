"""BlazeSeq: fast FASTQ parsing and GPU batch types."""

from blazeseq.record import FastqRecord, RefRecord, Validator
from blazeseq.parser import FastqParser, ParserConfig
from blazeseq.device_record import (
    FastqBatch,
    upload_batch_to_device,
)
from blazeseq.iostream import (
    BufferedReader, Reader, LineIterator, BufferedWriter,
    buffered_writer_for_file, buffered_writer_for_memory, buffered_writer_for_gzip
)
from blazeseq.readers import FileReader, MemoryReader, GZFile
from blazeseq.writers import Writer, FileWriter, MemoryWriter, GZWriter
from blazeseq.utils import generate_synthetic_fastq_buffer
from blazeseq.errors import ParseError, ValidationError
