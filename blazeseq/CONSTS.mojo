from blazeseq.record import QualitySchema
from sys.info import simdwidthof

alias KB = 1024
alias MB = 1024 * KB
alias GB = 1024 * MB


alias USE_SIMD = True
alias read_header = 64
alias quality_header = 43
alias new_line = 10
alias carriage_return = 13

alias U8 = DType.uint8
alias simd_width: Int = simdwidthof[U8]()

alias DEFAULT_CAPACITY = 50
alias MAX_SHIFT = 30
alias MAX_CAPACITY = 2**MAX_SHIFT


# Values for schemas are derived from
# https://github.com/BioJulia/FASTX.jl/blob/master/src/fastq/quality.jl
# Also check: https://www.biostars.org/p/90845/

# Generic is the minimum and maximum value of all possible schemas schemas
alias generic_schema = QualitySchema("Generic", 33, 126, 33)
alias sanger_schema = QualitySchema("Sanger", 33, 126, 33)
alias solexa_schema = QualitySchema("Solexa", 59, 126, 64)
alias illumina_1_3_schema = QualitySchema("Illumina v1.3", 64, 126, 64)
alias illumina_1_5_schema = QualitySchema("Illumina v1.5", 66, 126, 64)
alias illumina_1_8_schema = QualitySchema("Illumina v1.8", 33, 126, 33)
