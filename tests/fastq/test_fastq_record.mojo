"""Tests for FastqRecord and external Validator.

FastqRecord is a data holder only; it does not validate. Validation is
performed externally via Validator (e.g. from ParserConfig). Tests are split
into: (1) FastqRecord behaviour as a container, (2) Validator structure/ASCII/quality
validation with explicit assert_raises where errors are expected.
"""
from std.memory import alloc
from blazeseq import FastqRecord
from blazeseq.fastq import Validator
from blazeseq.fastq.quality_schema import generic_schema
from blazeseq.byte_string import BString
from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    TestSuite,
    assert_raises,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def get_fastq_records() raises -> List[String]:
    """Load first 4 lines of tests/test_data/fastq_parser/example.fastq as one FASTQ record.
    """
    var records = List[String]()
    var f = open("tests/test_data/fastq_parser/example.fastq", "r")
    var content = f.read()
    f.close()
    var lines = content.split("\n")
    for i in range(min(4, len(lines))):
        records.append(String(lines[i]))
    return records^


def _validator_structure_only() -> Validator:
    """Validator that only runs structure checks (no ASCII, no quality schema).
    """
    return Validator(False, False, materialize[generic_schema]())


# ---------------------------------------------------------------------------
# FastqRecord: construction and container behaviour
# ---------------------------------------------------------------------------


def test_fastq_record_construction_never_validates() raises:
    """FastqRecord construction accepts any three strings (id, sequence, quality); it never raises for invalid structure.
    """
    # Invalid structure by FASTQ rules; construction must still succeed.
    _ = FastqRecord("INVALID", "ATCG", "!!!!")
    _ = FastqRecord("@test", "ATCG", "INVALID")
    _ = FastqRecord("@test", "ATCG", "!!")
    # Valid structure
    _ = FastqRecord("@id", "ACGT", "!!!!")


def test_fastq_record_getters_and_length() raises:
    """Accessors and length methods return correct values."""
    var record = FastqRecord("@test_seq", "ATCGATCGG", "!!!!!!!!!")

    assert_equal(String(record.sequence()), "ATCGATCGG")
    assert_equal(String(record.quality()), "!!!!!!!!!")
    assert_equal(String(record.id()), "@test_seq")

    assert_equal(len(record), 9)
    # byte_len = 1 + len(id) + len(sequence) + len(quality) + 5 ("@" + id + four newlines and "+\n")
    assert_equal(record.byte_len(), 1 + 9 + 9 + 9 + 5)


def test_fastq_record_equality() raises:
    """Equality is based on sequence only (ids ignored)."""
    var record1 = FastqRecord("@test1", "ATCG", "!!!!")
    var record2 = FastqRecord("@test2", "ATCG", "!!!!")
    var record3 = FastqRecord("@test1", "GCTA", "!!!!")

    assert_true(record1 == record2)
    assert_false(record1 == record3)
    assert_true(record1 != record3)


def test_fastq_record_string_representation() raises:
    """String(record) produces four lines (\"@\" + id, seq, +, qual)."""
    var record = FastqRecord("id", "ACGT", "!!!!")
    var s = String(record)
    assert_equal(s.count("\n"), 4)
    assert_true(s.startswith(String("@id")))


def test_fastq_record_from_file_data() raises:
    """Record built from file lines has expected shape; validate() (ASCII/quality only when disabled) passes.
    """
    var lines = get_fastq_records()
    var read = FastqRecord(
        lines[0], lines[1], lines[3], materialize[generic_schema]()
    )

    assert_false(len(read) == 0)
    assert_equal(len(read._sequence), len(read._quality))

    _validator_structure_only().validate(read)


# ---------------------------------------------------------------------------
# Validator: no structure (structure is validated in parser hot loop)
# ---------------------------------------------------------------------------


def test_validator_structure_valid_passes() raises:
    """Validator.validate() does not raise when no optional checks (ASCII/quality) are enabled.
    """
    var v = _validator_structure_only()
    var record = FastqRecord("@id", "ACGT", "!!!!")
    v.validate(record)


# ---------------------------------------------------------------------------
# Validator: ASCII validation (validate_ascii when check_ascii=True)
# ---------------------------------------------------------------------------


def test_validator_ascii_valid_passes() raises:
    """With check_ascii=True, validate() does not raise for all-ASCII record."""
    var v = Validator(True, False, materialize[generic_schema]())
    var record = FastqRecord("@id", "ACGT", "!!!!")
    v.validate(record)


def test_validator_ascii_invalid_raises() raises:
    """With check_ascii=True, validate() raises when a field contains non-ASCII.
    """
    var v = Validator(True, False, materialize[generic_schema]())
    # Build record with non-ASCII byte in id (String is UTF-8, so use alloc + BString).
    var ptr = alloc[UInt8](2)
    ptr[0] = 64  # '@'
    ptr[1] = 128  # non-ASCII
    var span = Span[UInt8, MutExternalOrigin](ptr=ptr, length=2)
    var bad_id = BString(span)
    ptr.free()
    var record = FastqRecord(
        bad_id^,
        BString("ACGT"),
        BString("!!!!"),
        33,
    )
    with assert_raises(contains="Non ASCII letters found"):
        v.validate(record)


# ---------------------------------------------------------------------------
# Validator: quality range validation (validate_quality_range when check_quality=True)
# ---------------------------------------------------------------------------


def test_validator_quality_schema_valid_passes() raises:
    """With check_quality=True, validate() does not raise when quality bytes are in schema range.
    """
    var v = Validator(False, True, materialize[generic_schema]())
    var record = FastqRecord("@x", "ACG", "!!!")  # '!' = 33, in [33,126]
    v.validate(record)


def test_validator_quality_schema_invalid_raises() raises:
    """With check_quality=True, validate() raises when a quality byte is outside schema [LOWER,UPPER].
    """
    var v = Validator(False, True, materialize[generic_schema]())
    # Generic schema: 33..126. Space (32) is below 33.
    var record = FastqRecord("@x", "ACG", "   ")
    with assert_raises(
        contains="Corrupt quality score according to provided schema"
    ):
        v.validate(record)


# ---------------------------------------------------------------------------
# Validator: full validate() with all checks
# ---------------------------------------------------------------------------


def test_validator_full_valid_passes() raises:
    """Validator with check_ascii=True and check_quality=True accepts valid record.
    """
    var v = Validator(True, True, materialize[generic_schema]())
    var record = FastqRecord("@id", "ACGT", "!!!!")
    v.validate(record)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
