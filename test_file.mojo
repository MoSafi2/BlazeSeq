from blazeseq.iostream import FileReader, BufferedLineIterator
from blazeseq.readers import GZFile
from blazeseq.parser import CoordParser, RecordParser


fn main() raises:
    var iterator = BufferedLineIterator[check_ascii=False](
        FileReader(
            "/home/mohamed/Documents/Projects/BlazeSeq/data/fastq_test.fastq",
        ),
        capacity=300,
    )
    var count = 0
    while True:
        try:
            var r = iterator._line_coord_n[4]()
            count += 1
            if count == 50:
                break
        except:
            break

    print(count)
