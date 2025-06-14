from blazeseq.iostream import BufferedLineIterator
fn main() raises:
    var iterator = BufferedLineIterator("/home/mohamed/Documents/Projects/BlazeSeq/data/SRR16012060.fastq", capacity=300)
    n = 0
    while True:
        print(iterator.get_next_line())
        n +=1
        if n == 10:
            break
