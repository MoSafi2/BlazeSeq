//! FASTQ parser benchmark runner using seq_io.
//! Reads path from argv[1], counts records and base pairs, prints "records base_pairs".

use seq_io::fastq::{Reader, Record};
use std::env;
use std::process;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: seq_io_runner <path.fastq>");
        process::exit(1);
    }
    let path = &args[1];

    let mut reader = match Reader::from_path(path) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("seq_io_runner: failed to open {}: {}", path, e);
            process::exit(1);
        }
    };

    let mut total_reads: u64 = 0;
    let mut total_base_pairs: u64 = 0;

    while let Some(record) = reader.next() {
        let record = match record {
            Ok(r) => r,
            Err(e) => {
                eprintln!("seq_io_runner: parse error: {}", e);
                process::exit(1);
            }
        };
        total_reads += 1;
        total_base_pairs += record.seq().len() as u64;
    }

    println!("{} {}", total_reads, total_base_pairs);
}
