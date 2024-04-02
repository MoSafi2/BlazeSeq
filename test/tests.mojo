from sys import external_call
from collections import List
from os import listdir


fn main() raises:
    var test_files: List[String] = listdir("/home/")
    var valid_files: List[String] = List[String]()
    for file_str in test_files:
        var tmp = file_str[]
        if tmp != String("tests.mojo") and tmp.endswith(".mojo"):
            valid_files.append(tmp)

    for test_file in valid_files:
        var thrown_away = external_call["system", Int, StringRef](
            (String("mojo run /home/") + test_file[]._strref_dangerous())
        )
