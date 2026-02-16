"""Tests for FastqRecord and external Validator.

FastqRecord is a data holder only; it does not validate. Validation is
performed externally via Validator (e.g. from ParserConfig). Tests are split
into: (1) FastqRecord behaviour as a container, (2) Validator structure/ASCII/quality
validation with explicit assert_raises where errors are expected.
"""
from memory import alloc
from blazeseq import FastqRecord, Validator
from blazeseq.CONSTS import generic_schema
from blazeseq.byte_string import ByteString
from testing import assert_equal, assert_false, assert_true, TestSuite, assert_raises


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

fn get_fastq_records() raises -> List[String]:
    """Load first 4 lines of data/fastq_test.fastq as one FASTQ record."""
    var records = List[String]()
    var f = open("data/fastq_test.fastq", "r")
    var content = f.read()
    f.close()
    var lines = content.split("\n")
    for i in range(min(4, len(lines))):
        records.append(String(lines[i]))
    return records^


fn _validator_structure_only() -> Validator:
    """Validator that only runs structure checks (no ASCII, no quality schema)."""
    return Validator(False, False, materialize[generic_schema]())


# ---------------------------------------------------------------------------
# FastqRecord: construction and container behaviour
# ---------------------------------------------------------------------------

fn test_fastq_record_construction_never_validates() raises:
    """FastqRecord construction accepts any four strings; it never raises for invalid structure."""
    # Invalid structure by FASTQ rules; construction must still succeed.
    _ = FastqRecord("INVALID", "ATCG", "+", "!!!!")
    _ = FastqRecord("@test", "ATCG", "INVALID", "!!!!")
    _ = FastqRecord("@test", "ATCG", "+", "!!")
    # Valid structure
    _ = FastqRecord("@id", "ACGT", "+", "!!!!")


fn test_fastq_record_getters_and_length() raises:
    """Getters and length methods return correct values."""
    var record = FastqRecord("@test_seq", "ATCGATCGG", "+", "!!!!!!!!!")

    assert_equal(String(record.get_seq()), "ATCGATCGG")
    assert_equal(String(record.get_quality_string()), "!!!!!!!!!")
    assert_equal(String(record.get_header_string()), "@test_seq")

    assert_equal(len(record), 9)
    # total_length = len(SeqHeader) + len(SeqStr) + len(QuHeader) + len(QuStr)
    assert_equal(record.total_length(), 9 + 9 + 1 + 9)


fn test_fastq_record_equality() raises:
    """Equality is based on SeqStr only (headers ignored)."""
    var record1 = FastqRecord("@test1", "ATCG", "+", "!!!!")
    var record2 = FastqRecord("@test2", "ATCG", "+", "!!!!")
    var record3 = FastqRecord("@test1", "GCTA", "+", "!!!!")

    assert_true(record1 == record2)
    assert_false(record1 == record3)
    assert_true(record1 != record3)


fn test_fastq_record_string_representation() raises:
    """__str__ produces four lines (header, seq, qual header, qual)."""
    var record = FastqRecord("@id", "ACGT", "+", "!!!!")
    var s = record.__str__()
    assert_equal(s.count("\n"), 4)
    assert_true(s.startswith(String("@id")))


fn test_fastq_record_from_file_data() raises:
    """Record built from file lines has expected shape and passes external validation."""
    var lines = get_fastq_records()
    var read = FastqRecord(lines[0], lines[1], lines[2], lines[3])

    assert_false(len(read) == 0)
    assert_equal(len(read.SeqStr), len(read.QuStr))
    assert_true(read.SeqHeader.startswith(String("@")))
    assert_true(read.QuHeader.startswith(String("+")))

    _validator_structure_only().validate(read)


# ---------------------------------------------------------------------------
# Validator: structure validation (validate_record)
# ---------------------------------------------------------------------------

fn test_validator_structure_valid_passes() raises:
    """Validator.validate() does not raise for a well-formed record (structure only)."""
    var v = _validator_structure_only()
    var record = FastqRecord("@id", "ACGT", "+", "!!!!")
    v.validate(record)


fn test_validator_structure_invalid_seq_header_raises() raises:
    """Sequence header not starting with '@' causes validate() to raise."""
    var v = _validator_structure_only()
    var record = FastqRecord("INVALID", "ATCG", "+", "!!!!")
    with assert_raises(contains="Sequence header does not start with '@'"):
        v.validate(record)


fn test_validator_structure_invalid_qual_header_raises() raises:
    """Quality header not starting with '+' causes validate() to raise."""
    var v = _validator_structure_only()
    var record = FastqRecord("@test", "ATCG", "INVALID", "!!!!")
    with assert_raises(contains="Quality header does not start with '+'"):
        v.validate(record)


fn test_validator_structure_mismatched_lengths_raises() raises:
    """Seq/quality length mismatch causes validate() to raise."""
    var v = _validator_structure_only()
    var record = FastqRecord("@test", "ATCG", "+", "!!")
    with assert_raises(contains="Quality and Sequencing string does not match in lengths"):
        v.validate(record)


fn test_validator_structure_extended_header_mismatch_raises() raises:
    """When quality header has len>1, it must match sequence header after '+'/@'; otherwise validate() raises."""
    var v = _validator_structure_only()
    # Length mismatch: "+ab" vs "@x"
    var record_len = FastqRecord("@x", "AC", "+ab", "!!")
    with assert_raises(contains="Quality Header is not the same length as the Sequencing"):
        v.validate(record_len)
    # Content mismatch: "+xy" vs "@ab"
    var record_content = FastqRecord("@ab", "AC", "+xy", "!!")
    with assert_raises(contains="Quality Header is not the same as the Sequencing Header"):
        v.validate(record_content)


# ---------------------------------------------------------------------------
# Validator: ASCII validation (validate_ascii when check_ascii=True)
# ---------------------------------------------------------------------------

fn test_validator_ascii_valid_passes() raises:
    """With check_ascii=True, validate() does not raise for all-ASCII record."""
    var v = Validator(True, False, materialize[generic_schema]())
    var record = FastqRecord("@id", "ACGT", "+", "!!!!")
    v.validate(record)


fn test_validator_ascii_invalid_raises() raises:
    """With check_ascii=True, validate() raises when a field contains non-ASCII."""
    var v = Validator(True, False, materialize[generic_schema]())
    # Build record with non-ASCII byte in header (String is UTF-8, so use alloc + ByteString).
    var ptr = alloc[UInt8](2)
    ptr[0] = 64  # '@'
    ptr[1] = 128  # non-ASCII
    var span = Span[UInt8, MutExternalOrigin](ptr=ptr, length=2)
    var bad_header = ByteString(span)
    ptr.free()
    var record = FastqRecord(
        bad_header^,
        ByteString("ACGT"),
        ByteString("+"),
        ByteString("!!!!"),
        33,
    )
    with assert_raises(contains="Non ASCII letters found"):
        v.validate(record)


# ---------------------------------------------------------------------------
# Validator: quality schema validation (validate_quality_schema when check_quality=True)
# ---------------------------------------------------------------------------

fn test_validator_quality_schema_valid_passes() raises:
    """With check_quality=True, validate() does not raise when quality bytes are in schema range."""
    var v = Validator(False, True, materialize[generic_schema]())
    var record = FastqRecord("@x", "ACG", "+", "!!!")  # '!' = 33, in [33,126]
    v.validate(record)


fn test_validator_quality_schema_invalid_raises() raises:
    """With check_quality=True, validate() raises when a quality byte is outside schema [LOWER,UPPER]."""
    var v = Validator(False, True, materialize[generic_schema]())
    # Generic schema: 33..126. Space (32) is below 33.
    var record = FastqRecord("@x", "ACG", "+", "   ")
    with assert_raises(contains="Corrupt quality score according to provided schema"):
        v.validate(record)


# ---------------------------------------------------------------------------
# Validator: full validate() with all checks
# ---------------------------------------------------------------------------

fn test_validator_full_valid_passes() raises:
    """Validator with check_ascii=True and check_quality=True accepts valid record."""
    var v = Validator(True, True, materialize[generic_schema]())
    var record = FastqRecord("@id", "ACGT", "+", "!!!!")
    v.validate(record)


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
