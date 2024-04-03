
from blazeseq import RecordParser
from sys import argv


fn main() raises:
    var vars = argv()
    var path = vars[1]
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
    print(read_no, base_number, qu_numeber)
