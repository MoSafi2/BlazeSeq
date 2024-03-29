import time
from math import math
from sys import argv
from blazeseq import CoordParser, RecordParser
from blazeseq.iostream import FileReader
from blazeseq import FullStats


fn main() raises:
    var fast_mode = False
    var validate_ascii = False
    var validate_quality = False
    var vars = argv()
    var path = vars[-1]

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

        if fast_mode:
            var parser = CoordParser(path)
            run_coord_parser(parser)
        else:
            run_record_parser(path, validate_ascii, validate_quality)


fn run_record_parser(path: String, validate_ascii: Bool, validate_quality: Bool) raises:
    if validate_ascii and validate_quality:
        var parser = RecordParser[validate_ascii=True, validate_quality=True](path)
        run_record_parser_session(parser)
    elif validate_ascii and not validate_quality:
        var parser = RecordParser[validate_ascii=True, validate_quality=False](path)
        run_record_parser_session(parser)

    elif not validate_ascii and validate_quality:
        var parser = RecordParser[validate_ascii=False, validate_quality=True](path)
        run_record_parser_session(parser)

    else:
        var parser = RecordParser[validate_ascii=True, validate_quality=True](path)
        run_record_parser_session(parser)


fn run_record_parser_session(inout parser: RecordParser) raises:
    var reads = 0
    var strt = time.now()
    while True:
        var record = parser.next()
        reads += 1
        if reads % 1_000_000 == 0:
            var current = time.now()
            var reads_p_min: Float64 = reads / ((strt - current) / 1e9) * 60
            var rounded = int(math.round(reads_p_min))
            print("\33[H")
            print("\033[J")
            print("Number of reads processed is :", reads)
            print("Speed:", rounded, " reads/min")


fn run_coord_parser(inout parser: CoordParser) raises:
    var reads = 0
    var strt = time.now()
    while True:
        var record = parser.next()
        reads += 1
        if reads % 1_000_000 == 0:
            var current = time.now()
            var reads_p_min: Float64 = reads / ((strt - current) / 1e9) * 60
            var rounded = int(math.round(reads_p_min))
            print("\33[H")
            print("\033[J")
            print("Number of reads processed is :", reads)
            print("Speed:", rounded, " reads/min")
