from blazeseq.iostream import FileReader, BufferedLineIterator
from blazeseq.readers import GZFile
from blazeseq.parser import CoordParser, RecordParser


fn main() raises:
    var iterator = CoordParser[check_ascii=False, check_quality=False](
        FileReader(
            "/home/mohamed/Documents/Projects/BlazeSeq/data/SRR16012060.fastq"
        )
    )
    var n = 0
    while True:
        try:
            _ = iterator.next()
            n += 1
        except:
            break

    print(n)
