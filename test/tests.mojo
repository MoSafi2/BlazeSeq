from collections import List
from sys import external_call
from os import listdir

fn main() raises:
    var test_files: List[String] = listdir("/home/runner/work/Fastq_Parser/Fastq_Parser/test/")
    var valid_files: List[String]

    # Remove tests.mojo from test_files
    for test_file in test_files:
        if test_file != String("tests.mojo"):
            valid_files.append(test_file)

    for test_file in test_files:
        var thrown_away = external_call["system", Int, String]("mojo run /home/runner/work/Fastq_Parser/Fastq_Parser/test/" + test_file)