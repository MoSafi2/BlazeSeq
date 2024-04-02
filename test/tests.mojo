from collections import List
from sys import external_call
from memory.unsafe import Pointer
from os import listdir

fn main() raises:
    var test_files: List[String] = listdir("/home/runner/work/Fastq_Parser/Fastq_Parser/test/")
    print(test_files)
    #var valid_files: List[String]
    # Remove tests.mojo from test_files
    #for test_file in test_files:
    #    var string_pointer: Pointer[String] = test_file.get_unsafe_pointer()
    #    var file_str = string_pointer.load(0)
    #    if file_str != String("tests.mojo"):
    #        valid_files.append(file_str)

    #print(valid_files)

    #for test_file in test_files:
    #    var thrown_away = external_call["system", Int, String]("mojo run /home/runner/work/Fastq_Parser/Fastq_Parser/test/" + test_file)