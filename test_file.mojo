from blazeseq.iostream import FileReader, BufferedLineIterator
from blazeseq.readers import GZFile
from blazeseq.parser import CoordParser, RecordParser


fn main() raises:
    var iterator = BufferedLineIterator[check_ascii=False](
        FileReader(
            "/home/mohamed/Documents/Projects/BlazeSeq/data/SRR16012060.fastq",
        ),
        capacity=300,
    )
    var count = 0
    # var slen = 0
    # var qlen = 0
    var r = iterator.get_next_n_line_spans[4]()
    print(
        String(bytes=r[0]),
        String(bytes=r[1]),
        String(bytes=r[2]),
        String(bytes=r[3]),
        sep="\n",
    )

    r = iterator.get_next_n_line_spans[4]()
    print(
        String(bytes=r[0]),
        String(bytes=r[1]),
        String(bytes=r[2]),
        String(bytes=r[3]),
        sep="\n"
    )
    count += 1
