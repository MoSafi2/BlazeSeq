from collections import Dict, KeyElement
from MojoFastTrim import FastParser, FastqRecord
from MojoFastTrim.helpers import get_next_line
import time
from base64 import b64encode


fn get_fastq_records() raises -> DynamicVector[Tensor[DType.int8]]:
    var vec = DynamicVector[Tensor[DType.int8]](capacity=4)
    let f = open("data/fastq_test.fastq", "r")
    let t = f.read_bytes()

    var offset = 0
    for i in range(4):
        let line = get_next_line(t, offset)
        vec.push_back(line)
        offset += line.num_elements() + 1
    return vec


fn main() raises:
    let valid_vec = get_fastq_records()
    var read = FastqRecord(valid_vec[0], valid_vec[1], valid_vec[2], valid_vec[3])
    let t1 = time.now()

    var d = Dict[FastqRecord, Int]()
    for i in range(100):
        if d.__contains__(read):
            d[read] += 1
        else:
            d[read] = 0
    let t2 = time.now()
    print((t2 - t1))
    print(len(d))
