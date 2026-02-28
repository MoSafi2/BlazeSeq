"""
BlazeSeq Python bindings — high-performance FASTQ parsing.

Install from PyPI (wheels only):
    pip install blazeseq

Usage:
    import blazeseq
    parser = blazeseq.create_parser("file.fastq", "sanger")
    while blazeseq.has_more(parser):
        rec = blazeseq.next_record(parser)
        print(rec.id(), rec.sequence())
"""

from blazeseq._loader import _get_extension_module

_mod = _get_extension_module()

create_parser = _mod.create_parser
has_more = _mod.has_more
next_record = _mod.next_record
next_ref_as_record = _mod.next_ref_as_record
next_batch = _mod.next_batch
FastqRecord = _mod.FastqRecord
FastqBatch = _mod.FastqBatch
FastqParser = _mod.FastqParser

__all__ = [
    "create_parser",
    "has_more",
    "next_record",
    "next_ref_as_record",
    "next_batch",
    "FastqRecord",
    "FastqBatch",
    "FastqParser",
]
