//! FASTQ parser benchmark runner using needletail.
//! Reads path from argv[1], counts records and base pairs, prints "records base_pairs".

use needletail::parse_fastx_file;
use std::env;
use std::process;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: needletail_runner <path.fastq>");
        process::exit(1);
    }
    let path = &args[1];

    let mut reader = match parse_fastx_file(path) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("needletail_runner: failed to open {}: {}", path, e);
            process::exit(1);
        }
    };

    let mut total_reads: u64 = 0;
    let mut total_base_pairs: u64 = 0;

    while let Some(record) = reader.next() {
        let seqrec = match record {
            Ok(r) => r,
            Err(e) => {
                eprintln!("needletail_runner: parse error: {}", e);
                process::exit(1);
            }
        };
        total_reads += 1;
        total_base_pairs += seqrec.num_bases() as u64;
    }

    println!("{} {}", total_reads, total_base_pairs);
}
