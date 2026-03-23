"""BlazeSeq FASTA parser runner for benchmarking.

Reads a FASTA file from the given path, counts records and base pairs,
and prints exactly "records base_pairs" on one line for verification
against other parsers.

Usage:
    pixi run mojo run -I . benchmark/fasta-parser/run_blazeseq_fasta.mojo <path.fasta>
"""

from sys import argv
from pathlib import Path
from blazeseq.io.readers import FileReader
from blazeseq.fasta.parser import FastaParser

def main() raises:
    var args = argv()
    if len(args) < 2:
        print("Usage: run_blazeseq_fasta.mojo <path.fasta>")
        return

    var file_path = args[1]
    var parser = FastaParser[FileReader](FileReader(Path(file_path)))
    var total_reads: Int = 0
    var total_base_pairs: Int = 0
    for record in parser:
        total_reads += 1
        total_base_pairs += len(record)

    print(total_reads, total_base_pairs)
