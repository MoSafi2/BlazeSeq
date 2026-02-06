"""Example: Using RecordParser and BatchedParser for FASTQ parsing.

This example demonstrates:
1. RecordParser: Parsing records one at a time with lazy iteration
2. BatchedParser: Parsing batches of records for CPU parallelism (AoS format)
3. BatchedParser: Parsing batches for GPU operations (SoA format)

Usage:
    mojo run examples/example_parser.mojo /path/to/file.fastq
"""

from blazeseq import RecordParser, BatchedParser
from blazeseq.iostream import FileReader
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

    # Create parser with validation enabled
    # Parameters: [Reader type, check_ascii, check_quality]
    # Schema options: "generic", "sanger", "solexa", "illumina_1.3", 
    #                 "illumina_1.5", "illumina_1.8"
    var parser = RecordParser[FileReader, True, True](
        FileReader(Path(file_path)), schema="generic"
    )

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
            # Mojo's type system should narrow Optional after None check
            # Access record fields directly
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

    # Disable both ASCII and quality validation for maximum performance
    var parser = RecordParser[FileReader, False, False](
        FileReader(Path(file_path)), schema="generic"
    )

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
# Example 3: BatchedParser - CPU parallelism (Array-of-Structures)
# ---------------------------------------------------------------------------


fn example_batched_parser_cpu(file_path: String) raises:
    """
    Example using BatchedParser to extract batches in Array-of-Structures (AoS)
    format. This format is optimal for CPU parallelism where you process
    individual records in parallel.
    """
    print("=" * 60)
    print("Example 3: BatchedParser - CPU parallelism (AoS format)")
    print("=" * 60)
    print()

    # Create batched parser with batch size of 1024 records
    # Parameters: [Reader type, check_ascii, check_quality, batch_size]
    var parser = BatchedParser[FileReader, True, True, 1024](
        FileReader(Path(file_path)), schema="generic", default_batch_size=1024
    )

    var total_records = 0
    var batch_number = 0

    # Process batches until EOF
    while True:
        # Extract a batch as a List of FastqRecord (AoS format)
        var batch = parser.next_record_list(max_records=1024)

        if len(batch) == 0:
            break

        batch_number += 1
        total_records += len(batch)

        # Process each record in the batch (can be parallelized)
        var batch_base_pairs = 0
        for i in range(len(batch)):
            batch_base_pairs += len(batch[i])

        print(
            "Batch "
            + String(batch_number)
            + ": "
            + String(len(batch))
            + " records, "
            + String(batch_base_pairs)
            + " base pairs"
        )

    print()
    print("Summary:")
    print("  Total batches: " + String(batch_number))
    print("  Total records: " + String(total_records))
    print()


# ---------------------------------------------------------------------------
# Example 4: BatchedParser - GPU operations (Structure-of-Arrays)
# ---------------------------------------------------------------------------


fn example_batched_parser_gpu(file_path: String) raises:
    """
    Example using BatchedParser to extract batches in Structure-of-Arrays (SoA)
    format. This format is optimal for GPU operations with coalesced memory access.
    """
    print("=" * 60)
    print("Example 4: BatchedParser - GPU operations (SoA format)")
    print("=" * 60)
    print()

    # Create batched parser with batch size of 2048 records
    var parser = BatchedParser[FileReader, True, True, 2048](
        FileReader(Path(file_path)), schema="generic", default_batch_size=2048
    )

    var total_records = 0
    var batch_number = 0

    # Process batches until EOF
    while True:
        # Extract a batch as FastqBatch (SoA format) for GPU operations
        var batch = parser.next_batch(max_records=2048)

        if len(batch) == 0:
            break

        batch_number += 1
        total_records += batch.num_records()

        # FastqBatch provides efficient access to packed data
        var total_qual_len = batch.total_quality_len()
        var quality_offset = batch.quality_offset()

        print(
            "Batch "
            + String(batch_number)
            + ": "
            + String(batch.num_records())
            + " records"
        )
        print(
            "  Total quality length: "
            + String(total_qual_len)
            + " bytes"
        )
        print("  Quality offset: " + String(quality_offset))
        print()

        # The batch can now be uploaded to GPU using upload_batch_to_device()
        # See examples/example_device.mojo for GPU usage examples

    print("Summary:")
    print("  Total batches: " + String(batch_number))
    print("  Total records: " + String(total_records))
    print()


# ---------------------------------------------------------------------------
# Example 5: BatchedParser - Custom batch sizes
# ---------------------------------------------------------------------------


fn example_batched_parser_custom_size(file_path: String) raises:
    """
    Example using BatchedParser with custom batch sizes per call.
    Useful when you need different batch sizes for different processing stages.
    """
    print("=" * 60)
    print("Example 5: BatchedParser - Custom batch sizes")
    print("=" * 60)
    print()

    var parser = BatchedParser[FileReader, False, False, 1024](
        FileReader(Path(file_path)), schema="generic", default_batch_size=1024
    )

    # Extract smaller batches for initial processing
    print("Extracting small batches (256 records each):")
    for i in range(3):
        var small_batch = parser.next_record_list(max_records=256)
        if len(small_batch) == 0:
            break
        print("  Small batch " + String(i + 1) + ": " + String(len(small_batch)) + " records")

    print()

    # Extract larger batches for bulk processing
    print("Extracting large batches (4096 records each):")
    var large_batch_count = 0
    while True:
        var large_batch = parser.next_batch(max_records=4096)
        if len(large_batch) == 0:
            break
        large_batch_count += 1
        print(
            "  Large batch "
            + String(large_batch_count)
            + ": "
            + String(large_batch.num_records())
            + " records"
        )

    print()


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------


fn main() raises:
    """Main function that runs all parser examples."""

    var args = argv()
    if len(args) < 2:
        print("Usage: mojo run examples/example_parser.mojo /path/to/file.fastq")
        return

    var file_path = args[1]

    # Run all examples
    example_record_parser(file_path)
    example_record_parser_no_validation(file_path)
    example_batched_parser_cpu(file_path)
    example_batched_parser_gpu(file_path)
    example_batched_parser_custom_size(file_path)

    print("=" * 60)
    print("All examples completed!")
    print("=" * 60)
