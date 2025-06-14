from blazeseq.parser import CoordParser
fn main() raises:
    var iterator = CoordParser[validate_ascii=False, validate_quality=False]("/home/mohamed/Documents/Projects/BlazeSeq/data/SRR16012060.fastq")
    var x = iterator.parse_all()
    
