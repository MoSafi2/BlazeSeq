"""Example: Using RecordParser for FASTQ parsing.

This example demonstrates:
1. RecordParser: Parsing records one at a time with validation (ASCII + quality schema)
2. RecordParser: Parsing with validation disabled for maximum speed

BatchedParser (AoS/SoA batches) is not currently exposed; see blazeseq.parser for updates.

Usage:
    mojo run examples/example_parser.mojo /path/to/file.fastq
"""

from blazeseq.parser import RecordParser, ParserConfig
from blazeseq.readers import FileReader
from pathlib import Path
from sys import argv


# ---------------------------------------------------------------------------
# Example 1: RecordParser - Single record iteration
# ---------------------------------------------------------------------------


fn example_record_parser(file_path: String) raises:
    """
    Example using RecordParser to parse records one at a time.
    Useful for streaming processing or when you need to process records individually.
    """
    print("=" * 60)
    print("Example 1: RecordParser - Single record iteration")
    print("=" * 60)
    print()

    var parser = RecordParser[FileReader](FileReader(Path(file_path)), "generic")

    var record_count = 0
    var total_base_pairs = 0

    # Iterate through records using lazy evaluation
    # Note: Using try/except pattern as Mojo's Optional unwrapping has limitations
    while True:
        try:
            var record = parser.next()
            if record is None:
                break
            record_val = record.take()
            record_count += 1
            total_base_pairs += len(record_val)

            # Print first 3 records as examples  
            if record_count <= 3:
                print("Record " + String(record_count) + ":")
                print("  Header: " + String(record_val.get_header_string()))
                print("  Sequence length: " + String(len(record_val)))
                print("  Quality length: " + String(len(record_val.get_quality_string())))
                print()
        except:
            break

    print("Summary:")
    print("  Total records: " + String(record_count))
    print("  Total base pairs: " + String(total_base_pairs))
    print()


# ---------------------------------------------------------------------------
# Example 2: RecordParser - No validation (faster)
# ---------------------------------------------------------------------------


fn example_record_parser_no_validation(file_path: String) raises:
    """
    Example using RecordParser with validation disabled for maximum speed.
    Use when you trust the input data format.
    """
    print("=" * 60)
    print("Example 2: RecordParser - No validation (faster)")
    print("=" * 60)
    print()

    # Disable both ASCII and quality validation via ParserConfig for maximum performance
    var parser = RecordParser[
        FileReader, ParserConfig(check_ascii=False, check_quality=False)
    ](FileReader(Path(file_path)), "generic")

    var record_count = 0
    while True:
        try:
            var record = parser.next()
            if record is None:
                break
            record_count += 1
        except:
            break

    print("Parsed " + String(record_count) + " records (no validation)")
    print()


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------


fn main() raises:
    """Main function that runs RecordParser examples."""

    var args = argv()
    if len(args) < 2:
        print("Usage: mojo run examples/example_parser.mojo /path/to/file.fastq")
        return

    var file_path = args[1]

    example_record_parser(file_path)
    example_record_parser_no_validation(file_path)

    print("=" * 60)
    print("All examples completed!")
    print("=" * 60)
