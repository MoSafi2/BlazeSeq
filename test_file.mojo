from blazeseq.iostream import FileReader, BufferedLineIterator
from blazeseq.readers import GZFile
from blazeseq.parser import CoordParser, RecordParser


fn main() raises:
    var iterator = BufferedLineIterator[check_ascii=False](
        FileReader(
            "/home/mohamed/Documents/Projects/BlazeSeq/data/SRR16012060.fastq",
        ),
        capacity=128 * 1024,
    )
    var count = 0
    var slen = 0
    var qlen = 0
    while True:
        try:
            var r = iterator.get_next_line_span()
            count += 1
        except:
            break

    print(count, slen, qlen, sep="\t")
