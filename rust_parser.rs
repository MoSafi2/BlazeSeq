use std::{env, array::from_ref};
use needletail::parse_fastx_file;

fn main() {
    if let path = String::from("102_20.fq") {
        let mut n: u32 = 0;
        let mut slen: u64 = 0;
        let mut qlen: u64 = 0;
        let mut reader = parse_fastx_file(&path).expect("valid path/file");
        let t1 = std::time::Instant::now();
        while let Some(record) = reader.next() {
            let seqrec = record.expect("invalid record");
            n += 1;
            slen += seqrec.seq().len() as u64;
            if let Some(qual) = seqrec.qual() {
                qlen += qual.len() as u64;
            }
        }
        let duration: std::time::Duration = t1.elapsed();

        println!("{}\t{}\t{}", n, slen, qlen);
        println!("Time elapsed ) is: {:?}", duration);

    } else {
        eprintln!("Usage: {} <in.fq>", file!());
        std::process::exit(1)
    }
}
