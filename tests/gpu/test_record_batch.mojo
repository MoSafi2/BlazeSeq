"""Compile-only coverage for the optional MAX-backed batch API."""

from blazeseq import FastqBatch
from blazeseq_gpu import DeviceFastqBatch, StagedFastqBatch
from std.testing import assert_equal, TestSuite


def test_core_batch_remains_available_with_gpu_package() raises:
    var batch = FastqBatch()
    assert_equal(batch.num_records(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
