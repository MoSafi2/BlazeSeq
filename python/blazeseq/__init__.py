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

from blazeseq._loader import _get_extension_module

_mod = _get_extension_module()

# Default batch size for parser.batches iteration
_DEFAULT_BATCH_SIZE = 100


def _next_or_stop(mojo_iter):
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

    def __init__(self, parser, batch_size):
        self._parser = parser  # _IterableParser
        self._batch_size = batch_size

    def __iter__(self):
        return self

    def __next__(self):
        batch = self._parser.next_batch(self._batch_size)
        if batch.num_records() == 0:
            raise StopIteration
        return batch


class _BatchesIterable:
    """Iterable over batches; each iteration returns a new iterator over batches."""

    __slots__ = ("_parser", "_batch_size")

    def __init__(self, parser, batch_size=_DEFAULT_BATCH_SIZE):
        self._parser = parser  # _IterableParser
        self._batch_size = batch_size

    def __iter__(self):
        return _BatchesIterator(self._parser, self._batch_size)


class _IterableParser:
    """Wrapper so that parser.records and parser.batches work. Delegates to the Mojo parser."""

    __slots__ = ("_parser",)

    def __init__(self, parser):
        self._parser = parser

    @property
    def records(self):
        """Iterable over records: for rec in parser.records"""
        return self

    @property
    def batches(self):
        """Iterable over batches (default size 100): for batch in parser.batches"""
        return _BatchesIterable(self, _DEFAULT_BATCH_SIZE)

    def batches_with_size(self, batch_size: int):
        """Iterable over batches of the given size: for batch in parser.batches_with_size(50)"""
        return _BatchesIterable(self, batch_size)

    def __iter__(self):
        return self

    def __next__(self):
        return _next_or_stop(self._parser)

    def next_batch(self, max_records):
        """Return an iterable batch of up to max_records records."""
        return _IterableBatch(self._parser.next_batch(max_records))

    def __getattr__(self, name):
        return getattr(self._parser, name)


class _IterableBatch:
    """Wrapper so that `for rec in batch` works. Delegates to the Mojo batch."""

    __slots__ = ("_batch",)

    def __init__(self, batch):
        self._batch = batch

    def __iter__(self):
        return _BatchIterator(self._batch.__iter__())

    def __getattr__(self, name):
        return getattr(self._batch, name)


class _BatchIterator:
    """Iterator over a Mojo batch; raises StopIteration when exhausted."""

    __slots__ = ("_it",)

    def __init__(self, mojo_batch_iter):
        self._it = mojo_batch_iter

    def __iter__(self):
        return self

    def __next__(self):
        return _next_or_stop(self._it)


def parser(path: str, quality_schema: str = "generic", parallelism: int = 4):
    """Create a FASTQ parser for the given path and quality schema.

    Supports plain (.fastq, .fq) and gzip-compressed (.fastq.gz, .fq.gz) files.
    quality_schema defaults to "generic"; other options: "sanger", "solexa",
    "illumina_1.3", "illumina_1.5", "illumina_1.8".
    For gzip files, parallelism is the number of decompression threads (default 4).
    Returns a parser with:
      - for rec in parser.records  (iterate over records)
      - for batch in parser.batches (iterate over batches of 100 records; then for rec in batch)
    """
    return _IterableParser(_mod.create_parser(path, quality_schema, parallelism))


create_parser = parser  # backward compatibility


FastqRecord = _mod.FastqRecord
FastqBatch = _mod.FastqBatch
FastqParser = _mod.FastqParser

__all__ = [
    "parser",
    "create_parser",
    "FastqRecord",
    "FastqBatch",
    "FastqParser",
]
