//! FASTQ parser benchmark runner using paraseq.
//!
//! CLI:
//!   paraseq_runner <path.fastq> [batch_size]
//!
//! Output (single line):
//!   "<records> <base_pairs>"
//!
//! Notes:
//! - We iterate `RecordSet`s (record-set batches) via `RecordSet.fill(...)`.

use std::env;

use paraseq::fastq;
use paraseq::Record;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: paraseq_runner <path.fastq> [batch_size]");
        std::process::exit(1);
    }

    let path = &args[1];
    let batch_size: usize = if args.len() >= 3 {
        args[2].parse().unwrap_or(4096)
    } else {
        4096
    };

    let mut reader = match fastq::Reader::from_path_with_batch_size(path, batch_size) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("paraseq_runner: failed to open {}: {e}", path);
            std::process::exit(1);
        }
    };

    let mut record_set = reader.new_record_set();

    let mut total_reads: u64 = 0;
    let mut total_base_pairs: u64 = 0;

    loop {
        let has_more = match record_set.fill(&mut reader) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("paraseq_runner: fill error: {e}");
                std::process::exit(1);
            }
        };

        if !has_more {
            break;
        }

        for record in record_set.iter() {
            let record = match record {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("paraseq_runner: record error: {e}");
                    std::process::exit(1);
                }
            };

            total_reads += 1;
            total_base_pairs += record.seq_raw().len() as u64;
        }
    }

    println!("{} {}", total_reads, total_base_pairs);
}

