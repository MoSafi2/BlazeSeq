"""Simple single-threaded and one parallel test for FastqBatchSPMCQueue."""

from algorithm.functional import parallelize
from blazeseq.record import FastqRecord
from blazeseq.record_batch import FastqBatch
from blazeseq.spmc import FastqBatchSPMCQueue
from os.atomic import Atomic
from testing import assert_equal, assert_true, TestSuite


fn make_batch(id_val: Int) raises -> FastqBatch:
    var rec = FastqRecord("@" + String(id_val), "A", "I")
    var b = FastqBatch(batch_size=1)
    b.add(rec)
    return b^


fn test_push_pop_order() raises:
    """Push then pop in order; verify count and content."""
    var q = FastqBatchSPMCQueue(8)
    assert_true(q.is_empty())
    assert_equal(q.capacity(), 8)

    for i in range(5):
        q.push(make_batch(i))

    var count: Int = 0
    while True:
        var opt = q.try_pop()
        if not opt:
            break
        var batch = opt.take()
        assert_equal(batch.num_records(), 1)
        count += 1

    assert_equal(count, 5)
    assert_true(q.try_pop() is None)
    print("✓ test_push_pop_order passed")


fn test_try_pop_empty() raises:
    """Empty queue: try_pop returns None."""
    var q = FastqBatchSPMCQueue(2)
    assert_true(q.try_pop() is None)
    print("✓ test_try_pop_empty passed")


fn test_close_then_pop() raises:
    """After close(), pop() returns None when empty."""
    var q = FastqBatchSPMCQueue(2)
    assert_true(q.try_pop() is None)
    q.close()
    assert_true(q.pop() is None)
    assert_true(q.is_closed())
    print("✓ test_close_then_pop passed")


fn test_push_then_close_pop_all() raises:
    """Push a few, close, then pop until None."""
    var q = FastqBatchSPMCQueue(3)
    q.push(make_batch(0))
    q.push(make_batch(1))
    q.close()

    var a = q.pop()
    var b = q.pop()
    var c = q.pop()

    assert_true(a is not None)
    assert_true(b is not None)
    assert_true(c is None)

    _ = a.take()
    _ = b.take()
    print("✓ test_push_then_close_pop_all passed")


fn test_spmc_parallel_one_producer_multi_consumer() raises:
    """One producer pushes N items and closes; several consumers pop until None. Total popped == N."""
    comptime capacity: Int = 8
    comptime num_items: Int = 100
    comptime num_consumers: Int = 3

    var q = FastqBatchSPMCQueue(capacity)
    var consumed_count = Atomic[DType.int64](0)
    var had_error = Atomic[DType.int64](0)

    @parameter
    fn task(idx: Int) -> None:
        try:
            if idx == 0:
                for i in range(num_items):
                    q.push(make_batch(i))
                q.close()
            else:
                print("consumer", idx)
                var n: Int = 0
                while True:
                    var opt = q.pop()
                    if not opt:
                        break
                    batch = opt.take()
                    n += 1
                consumed_count += Int64(n)
                print(consumed_count.load())
        except:
            var expected: Int64 = 0
            _ = had_error.compare_exchange(expected, Int64(1))
            q.close()

    parallelize[task](num_consumers + 1, num_consumers + 1)

    assert_true(had_error.load() == 0, "no task should raise")
    assert_equal(Int(consumed_count.load()), num_items, "all items consumed exactly once")
    print("✓ test_spmc_parallel_one_producer_multi_consumer passed")


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
