from blazeseq.iostream import FileReader, BufferedLineIterator
from blazeseq.readers import GZFile
from blazeseq.parser import CoordParser, RecordParser


fn main() raises:
    var iterator = RecordParser[check_ascii=False, check_quality=False](
        FileReader(
            "/home/mohamed/Documents/Projects/BlazeSeq/data/SRR16012060.fastq",
        )
    )
    var count = 0
    var slen = 0
    var qlen = 0
    while True:
        try:
            var r = iterator.next()
            count += 1
            slen += r.len_record()
            qlen += r.len_quality()
        except:
            break

    print(count, slen, qlen, sep="\t")
