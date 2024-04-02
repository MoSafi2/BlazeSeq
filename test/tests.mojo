from sys import external_call
from collections import List
from os import listdir

fn main() raises:
    var test_files: List[String] = listdir("/home/runner/work/Fastq_Parser/Fastq_Parser/test/")
    var valid_files: List[String] = []
    for file_str in test_files:
        var tmp = file_str[]
        if tmp != String("tests.mojo"):
            valid_files.append(tmp)
            print(tmp)

    #for test_file in test_files:
    #    var thrown_away = external_call["system", Int, String]("mojo run /home/runner/work/Fastq_Parser/Fastq_Parser/test/" + test_file)