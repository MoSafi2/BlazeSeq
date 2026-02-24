//! FASTQ parser benchmark runner using seq_io on gzip-compressed input.
//! Reads path from argv[1] (.fastq.gz), counts records and base pairs, prints "records base_pairs".

use flate2::read::GzDecoder;
use seq_io::fastq::{Reader, Record};
use std::env;
use std::fs::File;
use std::io::BufReader;
use std::process;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: seq_io_gzip_runner <path.fastq.gz>");
        process::exit(1);
    }
    let path = &args[1];

    let file = match File::open(path) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("seq_io_gzip_runner: failed to open {}: {}", path, e);
            process::exit(1);
        }
    };
    let decoder = GzDecoder::new(file);
    let buf_reader = BufReader::new(decoder);
    let mut reader = Reader::new(buf_reader);

    let mut total_reads: u64 = 0;
    let mut total_base_pairs: u64 = 0;

    while let Some(record) = reader.next() {
        let record = match record {
            Ok(r) => r,
            Err(e) => {
                eprintln!("seq_io_gzip_runner: parse error: {}", e);
                process::exit(1);
            }
        };
        total_reads += 1;
        total_base_pairs += record.seq().len() as u64;
    }

    println!("{} {}", total_reads, total_base_pairs);
}
