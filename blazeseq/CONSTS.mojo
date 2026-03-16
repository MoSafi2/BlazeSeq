"""Central constants for BlazeSeq. General consts live here; quality-schema-specific
symbols are in blazeseq.fastq.quality_schema."""
from std.sys.info import simd_width_of

# Size units
comptime KB = 1024
comptime MB = 1024 * KB
comptime GB = 1024 * MB

# FASTQ/FASTA line markers (ASCII codes)
comptime USE_SIMD = True
comptime read_header: UInt8 = 64   # ord("@")
comptime quality_header: UInt8 = 43  # ord("+")
comptime new_line: UInt8 = 10       # ord("\n")
comptime carriage_return: UInt8 = 13  # ord("\r")
comptime fasta_header: UInt8 = 62   # ord(">")

# Sentinel error message for end-of-stream; used by parser/buffered iterators to stop iteration.
comptime EOF = "EOF"

# SIMD and dtype
comptime simd_width: Int = simd_width_of[UInt8]()
comptime U8 = DType.uint8

# Buffer and capacity
comptime DEFAULT_CAPACITY = 256 * KB
comptime MAX_SHIFT = 30
comptime MAX_CAPACITY = 2**MAX_SHIFT

# Default max records per batch for parser.batches() / next_batch() and FastqBatch preallocation.
comptime DEFAULT_BATCH_SIZE = 4096