from sys import external_call
from os import listdir

fn main() raises:
    var test_files: List[String] = listdir("./test/")

    for test_file in test_files:
        var _ = external_call["system", Int, String]("mojo run " + test_file)