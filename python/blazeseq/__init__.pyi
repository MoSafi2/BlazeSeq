"""Type stub for blazeseq: ensures 'parser' and other exports are known to type checkers."""

from collections.abc import Iterator
from typing import Protocol


class FastqRecordProtocol(Protocol):
    """Protocol for a single FASTQ record (read identifier, sequence, quality)."""

    @property
    def id(self) -> str:
        """Read identifier (without the leading '@')."""
        ...

    @property
    def sequence(self) -> str:
        """Sequence line (bases)."""
        ...

    @property
    def quality(self) -> str:
        """Quality line (encoded quality scores)."""
        ...

    def __len__(self) -> int:
        """Return the sequence length (number of bases)."""
        ...

    @property
    def phred_scores(self) -> list[int]:
        """Phred quality scores as a Python list of integers."""
        ...


class FastqBatchProtocol(Protocol):
    """Protocol for a batch of FASTQ records."""

    def num_records(self) -> int:
        """Return the number of records in the batch."""
        ...

    def get_record(self, index: int) -> FastqRecordProtocol:
        """Return the record at the given index (0-based)."""
        ...

    def __iter__(self) -> Iterator[FastqRecordProtocol]:
        """Iterate over records in the batch."""
        ...


class ParserProtocol(Protocol):
    """Protocol for the FASTQ parser returned by parser()."""

    def has_more(self) -> bool:
        """Return True if there may be more records to read."""
        ...

    def next_record(self) -> FastqRecordProtocol:
        """Return the next record. Raises on EOF or parse error."""
        ...

    def next_ref_as_record(self) -> FastqRecordProtocol:
        """Return the next record (from zero-copy ref) as an owned record. Raises on EOF or parse error."""
        ...

    def next_batch(self, max_records: int) -> FastqBatchProtocol:
        """Return a batch of up to max_records records."""
        ...

    @property
    def records(self) -> Iterator[FastqRecordProtocol]:
        """Iterable over records: for rec in parser.records."""
        ...

    @property
    def batches(self) -> Iterator[FastqBatchProtocol]:
        """Iterable over batches (default size 100): for batch in parser.batches."""
        ...


def parser(
    path: str,
    quality_schema: str = "generic",
    parallelism: int = 4,
) -> ParserProtocol:
    """Create a FASTQ parser for the given path and quality schema.

    Supports plain (.fastq, .fq) and gzip-compressed (.fastq.gz, .fq.gz) files.
    quality_schema defaults to "generic"; other options: "sanger", "solexa",
    "illumina_1.3", "illumina_1.5", "illumina_1.8".
    For gzip files, parallelism is the number of decompression threads (default 4).

    Returns:
        A parser supporting iteration over records and batches.
    """
    ...


def create_parser(
    path: str,
    quality_schema: str = "generic",
    parallelism: int = 4,
) -> ParserProtocol:
    """Create a FASTQ parser (alias for parser). Same signature and behavior as parser()."""
    ...


def mojopkg_path() -> str:
    """Return the path to the directory containing the pre-built blazeseq.mojopkg for use with mojo build -I."""
    ...


# Concrete types from the extension module (for runtime typing)
FastqRecord: type[FastqRecordProtocol]  # Single FASTQ record
FastqBatch: type[FastqBatchProtocol]  # Batch of FASTQ records
FastqParser: type  # Parser for plain FASTQ files (.fastq, .fq)
FastqGZParser: type  # Parser for gzip-compressed FASTQ (.fastq.gz, .fq.gz)
