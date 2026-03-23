//! FASTQ parser benchmark runner using seq_io FASTQ RecordSets.
//!
//! CLI:
//!   seq_io_recordset_runner <path.fastq> [batch_size]
//!
//! Output (single line):
//!   "<records> <base_pairs>"

use std::env;

use seq_io::fastq::{Reader, Record, RecordSet};

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: seq_io_recordset_runner <path.fastq> [batch_size]");
        std::process::exit(1);
    }

    let path = &args[1];
    let batch_size: usize = if args.len() >= 3 {
        args[2].parse().unwrap_or(4096)
    } else {
        4096
    };

    // Approximate FASTQ record byte size in BlazeSeq's synthetic generator:
    // - header (with zero-padded digits) + 2*read_length + 4 line separators.
    // The generator defaults to read_length=100, so this is ~219 bytes/record.
    // Use a small safety margin so `read_record_set` returns record sets with
    // around `batch_size` records when possible.
    let bytes_per_record_est: usize = 220;
    let cap = batch_size.saturating_mul(bytes_per_record_est).max(3);

    let mut reader = match Reader::from_path_with_capacity(path, cap) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("seq_io_recordset_runner: failed to open {}: {e}", path);
            std::process::exit(1);
        }
    };

    let mut record_set = RecordSet::default();
    let mut total_reads: u64 = 0;
    let mut total_base_pairs: u64 = 0;

    while let Some(res) = reader.read_record_set(&mut record_set) {
        if let Err(e) = res {
            eprintln!("seq_io_recordset_runner: read_record_set error: {e}");
            std::process::exit(1);
        }

        for record in &record_set {
            total_reads += 1;
            total_base_pairs += record.seq().len() as u64;
        }
    }

    println!("{} {}", total_reads, total_base_pairs);
}

