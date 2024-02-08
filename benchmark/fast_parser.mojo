from MojoFastTrim import FastParser
from sys import argv

alias KB = 1024
alias MB = 1024 * KB
alias GB = 1024 * MB


fn main() raises:
    let vars = argv()
    var parser = FastParser(vars[1], 64 * KB)
    var num_reads = 0
    var num_bases = 0
    var num_qu = 0
    while True:
        try:
            let record = parser.next()
            num_reads += 1
            num_bases += record.seq_len().to_int()
            num_qu += record.qu_len().to_int()
        except:
            print(num_reads, num_bases, num_qu)
            parser._file_handle.close()
            break
