from time import perf_counter_ns as now
from sys import argv
from blazeseq.parser import CoordParser, RecordParser
from blazeseq.iostream import FileReader


fn main() raises:
    var fast_mode = False
    var validate_ascii = False
    var validate_quality = False
    var vars = argv()

    if len(vars) == 1:
        print(help_msg)

    if vars[1] == "-h" or vars[1] == "--help":
        print(help_msg)

    var path = vars[len(vars) - 1]
    for opt in vars:
        if opt == "--validate-ascii":
            validate_ascii = True
        if opt == "-a":
            validate_ascii = True
        if opt == "--fast-mode":
            fast_mode = True
        if opt == "-f":
            fast_mode = True
        if opt == "--validate-quality":
            validate_quality = True
        if opt == "-q":
            validate_quality = True

    var schema: String = "generic"

    if validate_quality:
        for i in range(len(vars)):
            if vars[i] == "-q" or vars[i] == "--validate-quality":
                if vars[i + 1] != "-" or vars[i + 1] != "--":
                    schema = String(vars[i + 1])

    if fast_mode:
        var parser = CoordParser[validate_ascii=False, validate_quality=False](
            String(path)
        )
        run_coord_parser(parser)
    else:
        run_record_parser(
            String(path), validate_ascii, validate_quality, schema
        )


fn run_record_parser(
    path: String,
    validate_ascii: Bool,
    validate_quality: Bool,
    schema: String,
) raises:
    if validate_ascii and validate_quality:
        var parser = RecordParser[validate_ascii=True, validate_quality=True](
            String(path), schema
        )
        run_record_parser_session(parser)
    elif validate_ascii and not validate_quality:
        var parser = RecordParser[validate_ascii=True, validate_quality=False](
            String(path), schema
        )
        run_record_parser_session(parser)
    elif not validate_ascii and validate_quality:
        var parser = RecordParser[validate_ascii=False, validate_quality=True](
            String(path), schema
        )
        run_record_parser_session(parser)
    elif not validate_ascii and not validate_quality:
        var parser = RecordParser[validate_ascii=False, validate_quality=False](
            String(path), schema
        )
        run_record_parser_session(parser)


fn run_record_parser_session(mut parser: RecordParser) raises:
    var reads = 0
    var strt = now()
    while True:
        try:
            _ = parser.next()
            reads += 1
            if reads % 1_000_000 == 0:
                var current = now()
                var reads_p_min: Float64 = reads / ((current - strt) / 1e9) * 60
                var rounded = Int(round(reads_p_min))
                print("\33[H")
                print("\033[J")
                print("Number of reads processed is:", reads)
                print("Speed:", rounded, "reads/min")

        except:
            var current = now()
            var elapsed = (current - strt) / 1e9
            var reads_p_min: Float64 = reads / ((current - strt) / 1e9) * 60
            var rounded = Int(round(reads_p_min))
            print(
                "total of",
                reads,
                " reads parsed in:",
                elapsed,
                "seconds.\n",
                "Average speed:",
                rounded,
                "reads/min",
            )
            break


fn run_coord_parser(mut parser: CoordParser) raises:
    var reads = 0
    var strt = now()
    while True:
        try:
            _ = parser.next()
            reads += 1
            if reads % 1_000_000 == 0:
                var current = now()
                var reads_p_min: Float64 = reads / ((current - strt) / 1e9) * 60
                var rounded = Int(round(reads_p_min))
                print("\33[H")
                print("\033[J")
                print("Number of reads processed is:", reads)
                print("Speed:", rounded, "reads/min")

        except:
            var current = now()
            var elapsed = (current - strt) / 1e9
            var reads_p_min: Float64 = reads / ((current - strt) / 1e9) * 60
            var rounded = Int(round(reads_p_min))
            print("\33[H")
            print("\033[J")
            print(
                "total of",
                reads,
                " reads parsed in:",
                elapsed,
                "seconds.\n",
                "Average speed:",
                rounded,
                "reads/min",
            )
            break


alias help_msg = """
Usage:

blazeseq [OPTION]... path/to/file
Options:

-h, --help: Prints this help message.
-f, --fast-mode: Use a faster parser (). Use a faster parser (may skip some validations).
-a, --validate-ascii [schema]: Validate that the input file is ASCII encoded (not available in fast-mode).
-q, --validate-quality: Perform additional quality checks on the parsed data (not available in fast-mode).

Description:

Blaze-seq is a verstaile FASTQ parser, It offers different options to control the parsing behavior:

Fast Mode: Using -f or --fast-mode enables a faster parser but only validates read headers/matching ID lengths. This can be useful for initial processing of large files.
Validation: By default, all data is assumed to be valid. You can enable specific validations using the following options:
-a or --validate-ascii: Ensures the file is encoded in ASCII characters.
-q or --validate-quality: Performs checks on the read quality according to the provided quality schema. availble schemas are (sanger, solexa, illumina_1.3', 'illumina_1.5' 'illumina_1.8').
The program currently only outputs limited parsing information, including the number of records processed and the parsing speed (reads per minute).
"""
