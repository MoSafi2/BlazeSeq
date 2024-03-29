from blazeseq import RecordParser
from sys import argv
import time


alias KB = 1024
alias MB = 1024 * KB
alias GB = 1024 * MB


fn main() raises:
    var vars = argv()
    var parser = RecordParser[validate_ascii=True, validate_quality=True](vars[1])
    var read_no = 0
    while True:
        try:
            var read = parser.next()
            read_no += 1
        except Error:
            print(read_no)
            break
