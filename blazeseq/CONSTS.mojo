from blazeseq.quality_schema import QualitySchema
from sys.info import simd_width_of

comptime KB = 1024
comptime MB = 1024 * KB
comptime GB = 1024 * MB


comptime USE_SIMD = True
comptime read_header: UInt8 = 64
comptime quality_header: UInt8 = 43
comptime new_line: UInt8 = 10
comptime carriage_return: UInt8 = 13

# Sentinel error message for end-of-stream; used by parser/iostream iterators to stop iteration.
comptime EOF = "EOF"

comptime simd_width: Int = simd_width_of[UInt8]()

comptime DEFAULT_CAPACITY = 4 * 1024
comptime MAX_SHIFT = 30
comptime MAX_CAPACITY = 2**MAX_SHIFT


# Values for schemas are derived from
# https://github.com/BioJulia/FASTX.jl/blob/master/src/fastq/quality.jl
# Also check: https://www.biostars.org/p/90845/

# Generic is the minimum and maximum value of all possible schemas schemas
comptime generic_schema = QualitySchema("Generic", 33, 126, 33)
comptime sanger_schema = QualitySchema("Sanger", 33, 126, 33)
comptime solexa_schema = QualitySchema("Solexa", 59, 126, 64)
comptime illumina_1_3_schema = QualitySchema("Illumina v1.3", 64, 126, 64)
comptime illumina_1_5_schema = QualitySchema("Illumina v1.5", 66, 126, 64)
comptime illumina_1_8_schema = QualitySchema("Illumina v1.8", 33, 126, 33)
