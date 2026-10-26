"""Check the example kernel against known scores and the CPU reference."""

from blazeseq import FastqBatch, FastqRecord
from max.gpu.host import DeviceContext
from std.sys import has_accelerator
from std.testing import assert_equal, TestSuite
from examples.nw_gpu.execution import setup_reference, run_gpu_nw, run_cpu_nw


def assert_alignment(
    reference: String, queries: List[String], expected: List[Int32]
) raises:
    var batch = FastqBatch()
    for query in queries:
        batch.add(FastqRecord("read", query, String("I") * query.byte_length()))
    var batches = List[FastqBatch]()
    batches.append(batch^)
    var ctx = DeviceContext()
    var (ref_buffer, ref_len) = setup_reference(ctx, reference)
    var gpu = run_gpu_nw(batches, ref_buffer, ref_len, ctx)
    var cpu = run_cpu_nw(batches, reference)
    assert_equal(len(gpu[1]), len(expected))
    for i in range(len(expected)):
        assert_equal(gpu[1][i], expected[i])
        assert_equal(gpu[1][i], cpu[1][i])


def test_matches_mismatches_and_gaps() raises:
    assert_alignment(
        "ACGT", ["ACGT", "ACGA", "ACG", "ACGTT", "TTTT"], [4, 2, 2, 3, -2]
    )


def test_supported_length_boundary() raises:
    assert_alignment(
        String("A") * 256, [String("A") * 256, String("A") * 255], [256, 254]
    )


def main() raises:
    comptime assert has_accelerator(), "GPU tests require an accelerator"
    TestSuite.discover_tests[__functions_in_module()]().run()
