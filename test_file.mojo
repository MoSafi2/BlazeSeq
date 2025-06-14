from blazeseq.iostream import FileReader, BufferedLineIterator
from blazeseq.readers import GZFile
fn main() raises:
    var iterator = BufferedLineIterator(GZFile("/home/mohamed/Documents/Projects/BlazeSeq/data/SRR16012060.fastq.gz", "r"))
    var x = iterator.get_next_line()
    print(x)
    
