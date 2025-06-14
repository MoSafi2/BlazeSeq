from blazeseq.iostream import BufferedLineIterator
fn main() raises:
    var iterator = BufferedLineIterator("/home/mohamed/Documents/Projects/BlazeSeq/data/SRR16012060.fastq", capacity=4096)
    n = 0
    while True:
        try:
            var x = iterator.get_next_line_span()
            n+= 1 
        except:
            break
    
    print(n/4)
