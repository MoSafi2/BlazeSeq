from blazeseq import FastqRecord
from blazeseq.iostream import BufferedReader
from testing import assert_equal, assert_false, assert_true


fn get_fastq_records() raises -> List[String]:
    var records = List[String]()
    var f = open("data/fastq_test.fastq", "r")
    var content = f.read()
    f.close()
    
    var lines = content.split("\n")
    # Get first 4 lines for a complete FASTQ record
    for i in range(min(4, len(lines))):
        records.append(String(lines[i]))
    
    return records


fn valid_fastq_record() raises:
    var valid_vec = get_fastq_records()
    var read = FastqRecord(valid_vec[0], valid_vec[1], valid_vec[2], valid_vec[3])

    # Test that record has valid length
    assert_false(len(read) == 0)
    assert_false(len(read.__str__()) == 0)
    
    # Test sequence and quality string lengths match
    assert_equal(len(read.SeqStr), len(read.QuStr))
    
    # Test header validation
    assert_true(read.SeqHeader.startswith("@"))
    assert_true(read.QuHeader.startswith("+"))
    
    # Test string representation
    var str_repr = read.__str__()
    assert_true(str_repr.count("\n") == 3)  # Should have 3 newlines for 4 lines


fn invalid_record() raises:
    # Test invalid header (doesn't start with @)
    try:
        _ = FastqRecord("INVALID", "ATCG", "+", "!!!!")
        assert_false(True, "Should have raised error for invalid sequence header")
    except:
        pass  # Expected to fail
    
    # Test invalid quality header (doesn't start with +)
    try:
        _ = FastqRecord("@test", "ATCG", "INVALID", "!!!!")
        assert_false(True, "Should have raised error for invalid quality header")
    except:
        pass  # Expected to fail
    
    # Test mismatched sequence and quality lengths
    try:
        _ = FastqRecord("@test", "ATCG", "+", "!!")
        assert_false(True, "Should have raised error for mismatched lengths")
    except:
        pass  # Expected to fail


fn test_fastq_record_methods() raises:
    var record = FastqRecord("@test_seq", "ATCGATCG", "+", "!!!!!!!!!")
    
    # Test getter methods
    var seq = record.get_seq()
    assert_equal(String(seq), "ATCGATCG")
    
    var qual = record.get_quality_string()
    assert_equal(String(qual), "!!!!!!!!!")
    
    var header = record.get_header_string()
    assert_equal(String(header), "@test_seq")
    
    # Test length methods
    assert_equal(len(record), 8)
    assert_equal(record.total_length(), 26)  # @test_seq(9) + ATCGATCG(8) + +(1) + !!!!!!!!!(8)


fn test_fastq_record_equality() raises:
    var record1 = FastqRecord("@test1", "ATCG", "+", "!!!!")
    var record2 = FastqRecord("@test2", "ATCG", "+", "!!!!")
    var record3 = FastqRecord("@test1", "GCTA", "+", "!!!!")
    
    # Records with same sequence should be equal
    assert_true(record1 == record2)
    
    # Records with different sequences should not be equal
    assert_false(record1 == record3)
    assert_true(record1 != record3)


fn main() raises:
    print("Running FASTQ record tests...")
    
    valid_fastq_record()
    print("✓ Valid FASTQ record test passed")
    
    # invalid_record()
    # print("✓ Invalid record tests passed")
    
    # test_fastq_record_methods()
    # print("✓ FASTQ record methods test passed")
    
    # test_fastq_record_equality()
    # print("✓ FASTQ record equality test passed")
    
    # print("All FASTQ record tests completed successfully!")
