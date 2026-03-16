# Quality schema struct and predefined schemas for FASTQ quality encoding.
#
# Values for schemas are derived from
# https://github.com/BioJulia/FASTX.jl/blob/master/src/fastq/quality.jl
# Also check: https://www.biostars.org/p/90845/


@fieldwise_init
struct QualitySchema(Copyable, ImplicitlyCopyable, Movable, Writable, TrivialRegisterPassable):
    var SCHEMA: StringSlice[StaticConstantOrigin]
    var LOWER: UInt8
    var UPPER: UInt8
    var OFFSET: UInt8

    fn write_to[w: Writer](self, mut writer: w) -> None:
        writer.write("Quality schema: ")
        writer.write(self.SCHEMA)
        writer.write("\nLower: ")
        writer.write(self.LOWER)
        writer.write("\nUpper: ")
        writer.write(self.UPPER)
        writer.write("\nOffset: ")
        writer.write(self.OFFSET)


comptime generic_schema = QualitySchema("Generic", 33, 126, 33)
comptime sanger_schema = QualitySchema("Sanger", 33, 126, 33)
comptime solexa_schema = QualitySchema("Solexa", 59, 126, 64)
comptime illumina_1_3_schema = QualitySchema("Illumina v1.3", 64, 126, 64)
comptime illumina_1_5_schema = QualitySchema("Illumina v1.5", 66, 126, 64)
comptime illumina_1_8_schema = QualitySchema("Illumina v1.8", 33, 126, 33)
