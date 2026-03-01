"""Example: Using `FastqParser` for FASTQ parsing.

This example demonstrates:
1. `FastqParser`: Parsing records one at a time with validation (ASCII + quality schema)
2. `FastqParser`: Parsing with validation disabled for maximum speed

Use `parser.records()` for owned `FastqRecord`s, `parser.ref_records()` for zero-copy `RefRecord`s,
or `parser.batches()` for `FastqBatch` (SoA). Direct methods: `next_record()`, `next_ref()`, `next_batch()`.

Usage:
    pixi run mojo run examples/example_parser.mojo /path/to/file.fastq
"""

from blazeseq import FastqParser, ParserConfig, FileReader
from pathlib import Path
from sys import argv


# ---------------------------------------------------------------------------
# Example 1: FastqParser - Single record iteration via records()
# ---------------------------------------------------------------------------


fn example_record_parser(file_path: String) raises:
    """
    Example using FastqParser to parse records one at a time via parser.records().
    Useful for streaming processing or when you need to process records individually.
    """
    print("=" * 60)
    print("Example 1: FastqParser - Single record iteration")
    print("=" * 60)
    print()

    var parser = FastqParser[FileReader](FileReader(Path(file_path)), "generic")

    var record_count = 0
    var total_base_pairs = 0

    for record in parser.records():
        record_count += 1
        total_base_pairs += len(record)

        # Print first 3 records as examples
        if record_count <= 3:
            print("Record " + String(record_count) + ":")
            print("  Id: " + String(record.id_slice()))
            print("  Sequence length: " + String(len(record)))
            print("  Quality length: " + String(len(record.quality)))
            print()

    print("Summary:")
    print("  Total records: " + String(record_count))
    print("  Total base pairs: " + String(total_base_pairs))
    print()


# ---------------------------------------------------------------------------
# Example 2: FastqParser - No validation (faster)
# ---------------------------------------------------------------------------


fn example_record_parser_no_validation(file_path: String) raises:
    """
    Example using FastqParser with validation disabled for maximum speed.
    Use when you trust the input data format.
    """
    print("=" * 60)
    print("Example 2: FastqParser - No validation (faster)")
    print("=" * 60)
    print()

    # Disable both ASCII and quality validation via ParserConfig for maximum performance
    var parser = FastqParser[
        FileReader, ParserConfig(check_ascii=False, check_quality=False)
    ](FileReader(Path(file_path)), "generic")

    var record_count = 0
    var total_base_pairs = 0

    for record in parser.records():
        record_count += 1
        total_base_pairs += len(record)

        # Print first 3 records as examples
        if record_count <= 3:
            print("Record " + String(record_count) + ":")
            print("  Id: " + String(record.id_slice()))
            print("  Sequence length: " + String(len(record)))
            print("  Quality length: " + String(len(record.quality)))
            print()

    print("Summary:")
    print("  Total records: " + String(record_count))
    print("  Total base pairs: " + String(total_base_pairs))
    print()


# ---------------------------------------------------------------------------
# Example 3: FastqParser - Parsing in batches
# ---------------------------------------------------------------------------

fn example_batched_parser(file_path: String) raises:
    """
    Example using FastqParser for parsing in batches.
    Use parser.batches() for FastqBatch (SoA) when you need batch processing.
    """
    print("=" * 60)
    print("Example 3: FastqParser - Parsing in batches")
    print("=" * 60)
    print()

    var parser = FastqParser[
        FileReader, ParserConfig(check_ascii=True, check_quality=True)
    ](FileReader(Path(file_path)), "generic")

    var record_count = 0
    var total_base_pairs = 0
    var batch_no = 0

    for batch in parser.batches():
        if batch_no == 0:
            for i in range(3):
                var rec = batch.get_ref(i)
                print("Record " + String(i + 1) + ":")
                print("  Id: " + String(rec.id_slice()))
                print("  Sequence length: " + String(len(rec)))
                print("  Quality length: " + String(len(rec.quality)))
                print()
            batch_no += 1
        record_count += batch.num_records()
        total_base_pairs += batch.seq_len()


    print("Summary:")
    print("  Total records: " + String(record_count))
    print("  Total base pairs: " + String(total_base_pairs))
    print()


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------


fn main() raises:
    """Main function that runs FastqParser examples."""

    var args = argv()
    if len(args) < 2:
        print("Usage: mojo run examples/example_parser.mojo /path/to/file.fastq")
        return

    var file_path = args[1]

    example_record_parser(file_path)
    example_record_parser_no_validation(file_path)
    example_batched_parser(file_path)

    print("=" * 60)
    print("All examples completed!")
    print("=" * 60)
