"""Single-producer / multi-consumer (SPMC) bounded queue for FastqBatch.

This provides back pressure via a fixed-capacity ring buffer: the producer
blocks (spin-waits) when the queue is full, and consumers block when empty.
"""

from blazeseq.record_batch import FastqBatch
from os.atomic import Atomic


@always_inline
fn _spin_iters(mut iters: Int):
    # Simple busy-wait backoff to reduce contention.
    # (Mojo does not yet expose a portable condvar in this repo.)
    if iters < 1:
        iters = 1
    for _ in range(iters):
        pass


struct FastqBatchSPMCQueue(ImplicitlyDestructible):
    """Bounded SPMC queue for `FastqBatch` with back pressure.

    - Single producer calls `push()` / `close()`.
    - Multiple consumers call `pop()` / `try_pop()`.
    """

    var _capacity: Int
    var _slots: List[Optional[FastqBatch]]

    var _head: Atomic[DType.int64]
    var _tail: Atomic[DType.int64]

    # Semaphore-like counters (atomic) to avoid consumer overshoot:
    # - _free: available ring slots for producer (back pressure when 0)
    # - _used: available items for consumers (empty when 0)
    var _free: Atomic[DType.int64]
    var _used: Atomic[DType.int64]

    # 0 = open, 1 = closed
    var _closed: Atomic[DType.int64]

    fn __init__(out self, capacity: Int) raises:
        if capacity <= 0:
            raise Error("FastqBatchSPMCQueue capacity must be >= 1")
        self._capacity = capacity
        self._slots = List[Optional[FastqBatch]](capacity=capacity)
        for _ in range(capacity):
            self._slots.append(None)

        self._head = Atomic[DType.int64](0)
        self._tail = Atomic[DType.int64](0)
        self._free = Atomic[DType.int64](Int64(capacity))
        self._used = Atomic[DType.int64](0)
        self._closed = Atomic[DType.int64](0)

    @always_inline
    fn capacity(self) -> Int:
        return self._capacity

    @always_inline
    fn is_closed(self) -> Bool:
        return self._closed.load() != 0

    fn close(mut self):
        var expected: Int64 = 0
        _ = self._closed.compare_exchange(expected, Int64(1))

    @always_inline
    fn len(self) -> Int:
        return Int(self._used.load())

    @always_inline
    fn is_empty(self) -> Bool:
        return self.len() == 0

    @always_inline
    fn is_full(self) -> Bool:
        return self._free.load() == 0

    @always_inline
    fn _acquire_free(mut self) raises:
        var backoff: Int = 1
        while True:
            if self.is_closed():
                raise Error("FastqBatchSPMCQueue is closed")
            var curr: Int64 = self._free.load()
            if curr > 0:
                var expected = curr
                if self._free.compare_exchange(expected, curr - Int64(1)):
                    return
            _spin_iters(backoff)
            backoff = min(backoff * 2, 1 << 16)

    @always_inline
    fn _try_acquire_used(mut self) -> Bool:
        while True:
            var curr: Int64 = self._used.load()
            if curr <= 0:
                return False
            var expected = curr
            if self._used.compare_exchange(expected, curr - Int64(1)):
                return True

    @always_inline
    fn _acquire_used_or_closed(mut self) -> Bool:
        var backoff: Int = 1
        while True:
            if self._try_acquire_used():
                return True
            if self.is_closed():
                return False
            _spin_iters(backoff)
            backoff = min(backoff * 2, 1 << 16)

    fn push(mut self, var batch: FastqBatch) raises:
        """Push one batch into the queue; blocks (spin-waits) when full."""
        self._acquire_free()

        # Reserve a unique ring index for this producer item.
        var idx: Int64 = self._tail.fetch_add(Int64(1))
        var pos = Int(idx % Int64(self._capacity))
        self._slots[pos] = batch^
        # Publish item availability after storing it.
        self._used += Int64(1)

    fn try_pop(mut self) -> Optional[FastqBatch]:
        """Try to pop one batch; returns None if currently empty."""
        if not self._try_acquire_used():
            return None

        var idx: Int64 = self._head.fetch_add(Int64(1))
        var pos = Int(idx % Int64(self._capacity))

        if not self._slots[pos]:
            # Should not happen if the semaphore counters are correct.
            # Avoid raising in concurrent contexts; treat as closed+empty.
            self.close()
            return None
        var out = self._slots[pos].take()

        # Release a free slot after clearing it.
        self._free += Int64(1)
        return out^

    fn pop(mut self) -> Optional[FastqBatch]:
        """Pop one batch; blocks (spin-waits) until an item is available or closed+empty."""
        if not self._acquire_used_or_closed():
            return None

        var idx: Int64 = self._head.fetch_add(Int64(1))
        var pos = Int(idx % Int64(self._capacity))

        if not self._slots[pos]:
            self.close()
            return None
        var out = self._slots[pos].take()
        self._free += Int64(1)
        return out^

