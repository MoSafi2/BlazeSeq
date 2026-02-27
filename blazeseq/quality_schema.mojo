comptime KB = 1024
comptime MB = 1024 * KB
comptime GB = 1024 * MB


comptime USE_SIMD = True
comptime read_header = 64
comptime quality_header = 43
comptime new_line = 10
comptime carriage_return = 13

comptime U8 = DType.uint8

comptime DEFAULT_CAPACITY = 64 * KB
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


@fieldwise_init
@register_passable("trivial")
struct QualitySchema(Copyable, ImplicitlyCopyable, Movable, Writable):
    var SCHEMA: StringSlice[StaticConstantOrigin]
    var LOWER: UInt8
    var UPPER: UInt8
    var OFFSET: UInt8

    fn write_to[w: Writer](self, mut writer: w) -> None:
        writer.write(self.__str__())

    fn __str__(self) -> String:
        return (
            String("Quality schema: ")
            + self.SCHEMA
            + "\nLower: "
            + String(self.LOWER)
            + "\nUpper: "
            + String(self.UPPER)
            + "\nOffset: "
            + String(self.OFFSET)
        )
