"""
BlazeSeq Python bindings — high-performance FASTQ parsing.

Install from PyPI (wheels only):
    pip install blazeseq

Usage:
    import blazeseq
    p = blazeseq.parser("file.fastq")  # quality_schema defaults to "generic"
    for rec in p.records:
        print(rec.id(), rec.sequence())
    for batch in p.batches:
        for rec in batch:
            ...
"""

from __future__ import annotations

import sys
from typing import Any, Iterator, Protocol, cast

from blazeseq._loader import _get_extension_module

_mod: Any = _get_extension_module()

# Default batch size for parser.batches iteration
_DEFAULT_BATCH_SIZE = 100


# ---------------------------------------------------------------------------
# Protocol definitions for type checkers (extension types are dynamic at runtime)
# ---------------------------------------------------------------------------


class FastqRecordProtocol(Protocol):
    """Protocol for a single FASTQ record (read identifier, sequence, quality)."""

    def id(self) -> str:
        """Return the read identifier (without the leading '@')."""
        ...

    def sequence(self) -> str:
        """Return the sequence line (bases)."""
        ...

    def quality(self) -> str:
        """Return the quality line (encoded quality scores)."""
        ...

    def __len__(self) -> int:
        """Return the sequence length (number of bases)."""
        ...

    def phred_scores(self) -> list[int]:
        """Return Phred quality scores as a Python list of integers."""
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


def _next_or_stop(mojo_iter: Any) -> FastqRecordProtocol:
    """Call __next__ on a Mojo iterator; raise StopIteration when exhausted."""
    try:
        return mojo_iter.__next__()
    except Exception as e:
        if "StopIteration" in str(e):
            raise StopIteration from e
        raise


class _BatchesIterator:
    """Iterator that yields batches from the parser (each batch is iterable over records)."""

    __slots__ = ("_parser", "_batch_size")

    def __init__(self, parser: _IterableParser, batch_size: int) -> None:
        self._parser = parser
        self._batch_size = batch_size

    def __iter__(self) -> _BatchesIterator:
        return self

    def __next__(self) -> _IterableBatch:
        batch = self._parser.next_batch(self._batch_size)
        if batch.num_records() == 0:
            raise StopIteration
        return batch


class _BatchesIterable:
    """Iterable over batches; each iteration returns a new iterator over batches."""

    __slots__ = ("_parser", "_batch_size")

    def __init__(
        self,
        parser: _IterableParser,
        batch_size: int = _DEFAULT_BATCH_SIZE,
    ) -> None:
        self._parser = parser
        self._batch_size = batch_size

    def __iter__(self) -> _BatchesIterator:
        return _BatchesIterator(self._parser, self._batch_size)


class _IterableParser:
    """
    Wrapper so that parser.records and parser.batches work.

    Delegates to the Mojo parser. Supports iteration (for rec in parser),
    .records, .batches, .batches_with_size(n), .has_more(), .next_record(), .next_batch(n).
    """

    __slots__ = ("_parser",)

    def __init__(self, parser: Any) -> None:
        self._parser = parser

    @property
    def records(self) -> _IterableParser:
        """Iterable over records: for rec in parser.records"""
        return self

    @property
    def batches(self) -> _BatchesIterable:
        """Iterable over batches (default size 100): for batch in parser.batches"""
        return _BatchesIterable(self, _DEFAULT_BATCH_SIZE)

    def batches_with_size(self, batch_size: int) -> _BatchesIterable:
        """Iterable over batches of the given size: for batch in parser.batches_with_size(50)"""
        return _BatchesIterable(self, batch_size)

    def __iter__(self) -> _IterableParser:
        return self

    def __next__(self) -> FastqRecordProtocol:
        return _next_or_stop(self._parser)

    def next_batch(self, max_records: int) -> _IterableBatch:
        """Return an iterable batch of up to max_records records."""
        return _IterableBatch(self._parser.next_batch(max_records))

    def __getattr__(self, name: str) -> Any:
        return getattr(self._parser, name)


class _IterableBatch:
    """Wrapper so that `for rec in batch` works. Delegates to the Mojo batch."""

    __slots__ = ("_batch",)

    def __init__(self, batch: Any) -> None:
        self._batch = batch

    def __iter__(self) -> _BatchIterator:
        return _BatchIterator(self._batch.__iter__())

    def __getattr__(self, name: str) -> Any:
        return getattr(self._batch, name)


class _BatchIterator:
    """Iterator over a Mojo batch; raises StopIteration when exhausted."""

    __slots__ = ("_it",)

    def __init__(self, mojo_batch_iter: Any) -> None:
        self._it = mojo_batch_iter

    def __iter__(self) -> _BatchIterator:
        return self

    def __next__(self) -> FastqRecordProtocol:
        return _next_or_stop(self._it)


def parser(
    path: str,
    quality_schema: str = "generic",
    parallelism: int = 4,
) -> _IterableParser:
    """Create a FASTQ parser for the given path and quality schema.

    Supports plain (.fastq, .fq) and gzip-compressed (.fastq.gz, .fq.gz) files.
    quality_schema defaults to "generic"; other options: "sanger", "solexa",
    "illumina_1.3", "illumina_1.5", "illumina_1.8".
    For gzip files, parallelism is the number of decompression threads (default 4).
    It is passed at creation and used for all reads (next_record, next_batch, iteration).

    Returns:
        A parser supporting:
          - for rec in parser.records  (iterate over records)
          - for batch in parser.batches (iterate over batches of 100 records; then for rec in batch)
          - parser.has_more(), parser.next_record(), parser.next_batch(max_records)
    """
    return _IterableParser(_mod.parser(path, quality_schema, parallelism))


create_parser = parser  # backward compatibility


# Re-export extension types (runtime); for type checkers, use the Protocol types above
FastqRecord: type[FastqRecordProtocol] = cast(type[FastqRecordProtocol], _mod.FastqRecord)
FastqBatch: type[FastqBatchProtocol] = cast(type[FastqBatchProtocol], _mod.FastqBatch)
FastqParser = _mod.FastqParser
FastqGZParser = _mod.FastqGZParser

__all__ = [
    "parser",
    "FastqRecord",
    "FastqBatch",
    "FastqParser",
    "FastqGZParser",
    "FastqRecordProtocol",
    "FastqBatchProtocol",
    "ParserProtocol",
]
