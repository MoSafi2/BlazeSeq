from MojoFastTrim.fastq_record import FastqRecord
from helpers import get_next_line
from testing import assert_equal, assert_false, assert_true

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


fn valid_fastq_record() raises:
    let valid_vec = get_fastq_records()
    var read = FastqRecord(valid_vec[0], valid_vec[1], valid_vec[2], valid_vec[3])

    assert_false(len(read) == 0)
    assert_false(len(read.__str__()) == 0)

    read._empty_record()
    assert_true(len(read) == 0)
    assert_true(len(read.__str__()) == 0)


fn invalid_record() raises:
    # Add tests here
    pass


fn main() raises:
    valid_fastq_record()
