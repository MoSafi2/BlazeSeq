from sys import external_call
from os import listdir

fn main() raises:
    var test_files: List[String] = listdir("/home/test")

    print("Files:")
    print(test_files[0])
    print(".")

    #for test_file in test_files:
    #    var thrown_away = external_call["system", Int, String](String("mojo run ") + String(test_file))