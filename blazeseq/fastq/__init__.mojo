from blazeseq.fastq.record import FastqRecord, FastqView, Validator
from blazeseq.fastq.parser import FastqParser, ParserConfig
from blazeseq.fastq.record_batch import (
    FastqBatch,
    DeviceFastqBatch,
    StagedFastqBatch,
    upload_batch_to_device,
)

