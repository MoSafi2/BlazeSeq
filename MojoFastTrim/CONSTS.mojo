alias USE_SIMD = True
alias read_header = 64
alias quality_header = 43
alias new_line = 10
alias simd_width: Int = simdwidthof[DType.int8]()


@value
struct QualitySchema(Stringable):
    var SCHEMA: StringLiteral
    var LOWER: Int8
    var UPPER: Int8
    var OFFSET: Int8

    fn __init__(inout self, schema: StringLiteral, lower: Int, upper: Int, offset: Int):
        self.SCHEMA = schema
        self.UPPER = upper
        self.LOWER = lower
        self.OFFSET = offset

    fn __str__(self) -> String:
        return (
            String("Quality schema: ")
            + self.SCHEMA
            + "\nLower: "
            + self.LOWER
            + "\nUpper: "
            + self.UPPER
            + "\nOffset: "
            + self.OFFSET
        )


# Values for schemas are derived from
# https://github.com/BioJulia/FASTX.jl/blob/master/src/fastq/quality.jl
# Check the values again, smthing smells solexa is different than Illumina 1.3?

alias generic_schema = QualitySchema("Generic", 0, 127, 0)
alias sanger_schema = QualitySchema("Sanger", 33, 126, 33)
alias solexa_schema = QualitySchema("Solexa", 59, 126, 64)
alias illumina_1_3_schema = QualitySchema("Illumina v1.3", 64, 126, 64)
alias illumina_1_5_schema = QualitySchema("Illumina v1.5", 66, 126, 64)
alias illumina_1_8 = QualitySchema("Illumina v1.8", 33, 126, 33)


fn main():
    print(solexa_schema)
