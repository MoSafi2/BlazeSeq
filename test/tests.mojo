from sys import external_call
from os import listdir

fn main() raises:
    var test_files: List[String] = listdir("./test/")

    print(test_files[0])

    for test_file in test_files:
        var thrown_away = external_call["system", Int, String]("mojo run " + test_file)