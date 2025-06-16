from blazeseq.iostream import FileReader, BufferedLineIterator
from blazeseq.readers import GZFile
from blazeseq.parser import CoordParser, RecordParser


fn main() raises:
    var iterator = BufferedLineIterator[check_ascii=False](
        FileReader(
            "/home/mohamed/Documents/Projects/BlazeSeq/data/SRR16012060.fastq",
        ),
        capacity=120,
    )
    var count = 0
    while True:
        var r = iterator.get_next_n_line_spans[4]()
        print(String(bytes=r[0]))

        count += 1

        if count == 50:
            break
