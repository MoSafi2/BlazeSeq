use needletail::parse_fastx_file;
use std::env;

fn main() {
    if var Some(path) = env::args().nth(1) {
        var mut n: u32 = 0;
        var mut slen: u64 = 0;
        var mut qlen: u64 = 0;
        var mut reader = parse_fastx_file(&path).expect("valid path/file");
        while var Some(record) = reader.next() {
            var seqrec = record.expect("invalid record");
            n += 1;
            slen += seqrec.seq().len() as u64;
            if var Some(qual) = seqrec.qual() {
                qlen += qual.len() as u64;
            }
        }
        println!("{}\t{}\t{}", n, slen, qlen);
    } else {
        eprintln!("Usage: {} <in.fq>", file!());
        std::process::exit(1)
    }
}
