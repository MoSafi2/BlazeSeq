from blazeseq import RecordParser, CoordParser
from sys import argv
from time import now


fn main() raises:
    var vars = argv()
    var path = vars[1]
    record_parser_validate_all(path)
    record_parser_quality_only(path)
    coord_parser(path)


fn record_parser_validate_all(path: String) raises:
    var tic = now()
    var parser = RecordParser[validate_ascii=True, validate_quality=True](
        path, "illumina_1.8"
    )
    var read_no = 0
    var base_number = 0
    var qu_numeber = 0
    while True:
        try:
            var read = parser.next()
            read_no += 1
            base_number += len(read)
            qu_numeber += read.QuStr.num_elements()
        except Error:
            break
    var toc = now()
    var time_fun = round((toc - tic) / 1e9)
    print(
        "RecordParser with ASCII and quality validation.\n",
        "time spent in parsing:",
        (toc - tic) / 1e9,
    )
    print(read_no, base_number, qu_numeber)


fn record_parser_quality_only(path: String) raises:
    var tic = now()
    var parser = RecordParser[validate_ascii=False, validate_quality=True](
        path, "illumina_1.8"
    )
    var read_no = 0
    var base_number = 0
    var qu_numeber = 0
    while True:
        try:
            var read = parser.next()
            read_no += 1
            base_number += len(read)
            qu_numeber += read.QuStr.num_elements()
        except Error:
            break
    var toc = now()
    var time_fun = round((toc - tic) / 1e9)
    print(
        "RecordParser with quality validation.\n",
        "time spent in parsing:",
        (toc - tic) / 1e9,
    )
    print(read_no, base_number, qu_numeber)


fn coord_parser(path: String) raises:
    var tic = now()
    var parser = CoordParser(path)
    var read_no = 0
    var base_number = 0
    var qu_numeber = 0
    while True:
        try:
            var read = parser.next()
            read_no += 1
            base_number += read.seq_len().to_int()
            qu_numeber += read.qu_len().to_int()
        except Error:
            break
    var toc = now()
    var time_fun = round((toc - tic) / 1e9)
    print(
        "CoordParser with basic validation.\n",
        "time spent in parsing:",
        (toc - tic) / 1e9,
    )
    print(read_no, base_number, qu_numeber)
