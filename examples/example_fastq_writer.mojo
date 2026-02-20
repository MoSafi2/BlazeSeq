"""Example: Writing FASTQ to plain or gzipped files.

This example demonstrates:
1. Writing FastqRecords to a plain .fastq file (BufferedWriter[FileWriter])
2. Writing FastqRecords to a gzipped .fastq.gz file (BufferedWriter[GZWriter])
3. Optionally reading from an input file and writing to both formats

Usage:
    # Write sample records to plain and gzip (no input file):
    pixi run mojo run examples/example_fastq_writer.mojo

    # Read from file, write to plain and gzip:
    pixi run mojo run examples/example_fastq_writer.mojo /path/to/input.fastq
"""

from pathlib import Path
from sys import argv
from os import remove

from blazeseq.record import FastqRecord
from blazeseq.parser import FastqParser
from blazeseq.readers import FileReader, GZFile
from blazeseq.writers import WriterBackend
from blazeseq.iostream import (
    BufferedWriter,
    buffered_writer_for_file,
    buffered_writer_for_gzip,
)


# ---------------------------------------------------------------------------
# Helper: write FastqRecords to any BufferedWriter
# ---------------------------------------------------------------------------


fn write_fastq_records[W: WriterBackend](
    mut writer: BufferedWriter[W], records: List[FastqRecord]
) raises:
    """Write FASTQ records to a BufferedWriter (4 lines per record)."""
    for i in range(len(records)):
        var s = records[i].__str__()
        var bytes = List(s.as_bytes())
        writer.write_bytes(bytes)
    writer.flush()


# ---------------------------------------------------------------------------
# Example 1: Write sample records to plain and gzipped files
# ---------------------------------------------------------------------------


fn example_write_sample_to_plain_and_gzip() raises:
    """
    Build a few FastqRecords in code and write them to both a plain .fastq
    and a .fastq.gz file.
    """
    print("=" * 60)
    print("Example 1: Write sample records to plain and gzip")
    print("=" * 60)
    print()

    # Sanger quality (offset 33); header, sequence, plus line, quality string
    var records = List[FastqRecord]()
    records.append(
        FastqRecord("@read/1", "ACGTACGT", "+", "IIIIIIII", 33)
    )
    records.append(
        FastqRecord("@read/2", "NNNNGATTACA", "+", "!!!!!IIIIII", 33)
    )
    records.append(
        FastqRecord("@read/3", "GGGGCCCC", "+", "HHHHHHHH", 33)
    )

    var plain_path = Path("example_output.fastq")
    var gz_path = "example_output.fastq.gz"

    # Write to plain file
    var plain_writer = buffered_writer_for_file(plain_path)
    write_fastq_records(plain_writer, records)
    print("Wrote " + String(len(records)) + " records to " + String(plain_path))

    # Write to gzipped file
    var gz_writer = buffered_writer_for_gzip(gz_path)
    write_fastq_records(gz_writer, records)
    print("Wrote " + String(len(records)) + " records to " + gz_path)
    print()

    # Clean up example outputs (optional)
    remove(plain_path)
    remove(gz_path)
    print("Removed example_output.fastq and example_output.fastq.gz")
    print()


# ---------------------------------------------------------------------------
# Example 2: Read from file, write to plain and gzip
# ---------------------------------------------------------------------------


fn example_read_then_write_plain_and_gzip(input_path: String) raises:
    """
    Parse FASTQ from an input file (plain or .gz), then write the same
    records to both a plain .fastq and a .fastq.gz file.
    """
    print("=" * 60)
    print("Example 2: Read from file → write to plain and gzip")
    print("=" * 60)
    print()

    var path_str = input_path
    var is_gz = path_str.endswith(".gz")

    # Parse all records
    var records = List[FastqRecord]()
    if is_gz:
        var parser = FastqParser[GZFile](GZFile(path_str, "rb"), "sanger")
        for record in parser.records():
            records.append(record^)
    else:
        var parser = FastqParser[FileReader](FileReader(Path(path_str)), "sanger")
        for record in parser.records():
            records.append(record^)

    if len(records) == 0:
        print("No records found in " + path_str)
        print()
        return

    # Output paths (strip .gz from base name for plain, add .gz for gzip)
    var base = path_str
    if is_gz:
        base = String(path_str[: len(path_str) - 3])  # remove ".gz"
    if base.endswith(".fastq"):
        base = String(base[: len(base) - 6])  # remove ".fastq"
    var plain_out = base + "_out.fastq"
    var gz_out = base + "_out.fastq.gz"

    # Write to plain file
    var plain_writer = buffered_writer_for_file(Path(plain_out))
    write_fastq_records(plain_writer, records)
    print("Wrote " + String(len(records)) + " records to " + plain_out)

    # Write to gzipped file
    var gz_writer = buffered_writer_for_gzip(gz_out)
    write_fastq_records(gz_writer, records)
    print("Wrote " + String(len(records)) + " records to " + gz_out)
    print()


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------


fn main() raises:
    """Run FASTQ writing examples."""

    var args = argv()

    # Example 1: always run — write sample data to plain and gzip
    example_write_sample_to_plain_and_gzip()

    # Example 2: if an input file is given, read it and write to plain + gzip
    if len(args) >= 2:
        example_read_then_write_plain_and_gzip(args[1])
    else:
        print("Tip: pass an input FASTQ to also run read → write plain/gzip:")
        print("  pixi run mojo run examples/example_fastq_writer.mojo /path/to/file.fastq")
        print()

    print("=" * 60)
    print("All examples completed!")
    print("=" * 60)
