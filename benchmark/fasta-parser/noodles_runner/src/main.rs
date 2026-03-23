//! FASTA parser benchmark runner using noodles.
//! Reads path from argv[1], counts records and base pairs, prints "records base_pairs".

use noodles::fasta;
use std::env;
use std::fs::File;
use std::io::BufReader;
use std::process;

def main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: noodles_fasta_runner <path.fasta>");
        process::exit(1);
    }
    let path = &args[1];

    let file = match File::open(path) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("noodles_fasta_runner: failed to open {}: {}", path, e);
            process::exit(1);
        }
    };

    let mut reader = fasta::io::Reader::new(BufReader::new(file));

    let mut total_reads: u64 = 0;
    let mut total_base_pairs: u64 = 0;

    for result in reader.records() {
        let record = match result {
            Ok(r) => r,
            Err(e) => {
                eprintln!("noodles_fasta_runner: parse error: {}", e);
                process::exit(1);
            }
        };
        total_reads += 1;
        total_base_pairs += record.sequence().len() as u64;
    }

    println!("{} {}", total_reads, total_base_pairs);
}
