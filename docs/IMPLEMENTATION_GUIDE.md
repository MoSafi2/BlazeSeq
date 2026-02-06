# Implementation Guide: SPMC Architecture for BlazeSeq

This guide provides step-by-step instructions for implementing the Single Producer, Multiple Consumer (SPMC) architecture for parallel FASTQ parsing.

## Prerequisites

- Understanding of Mojo language and BlazeSeq codebase
- Familiarity with threading and synchronization concepts
- Basic knowledge of GPU programming (for GPU consumers)

## Step-by-Step Implementation

### Step 1: Research Mojo Threading API

**Goal**: Understand available threading primitives in Mojo 0.26.1

**Tasks**:
1. Check Mojo standard library for `threading` module
2. Verify availability of:
   - `Mutex` or equivalent
   - `ConditionVariable` or equivalent
   - `Thread` or equivalent
   - `Atomic` types
3. Review Mojo documentation for concurrency patterns
4. Test basic threading operations if possible

**Expected Output**: 
- List of available threading primitives
- Example code demonstrating basic usage
- Notes on limitations or differences from standard threading APIs

**Files to Create**:
- `docs/THREADING_API.md` - Documentation of Mojo threading capabilities

---

### Step 2: Implement ThreadSafeBatchQueue

**Goal**: Create a thread-safe queue for batch transfer

**Location**: `blazeseq/parallel/queue.mojo`

**Implementation**:

```mojo
from threading import Mutex, ConditionVariable  # Verify actual imports
from memory import UnsafePointer

struct ThreadSafeBatchQueue[T: Movable]:
    """
    Thread-safe queue for transferring batches between producer and consumers.
    Supports both bounded (with backpressure) and unbounded operation.
    """
    var _queue: List[T]
    var _mutex: Mutex
    var _not_empty: ConditionVariable  # Signaled when queue becomes non-empty
    var _not_full: ConditionVariable    # Signaled when queue has space
    var _max_size: Int  # -1 for unbounded, >0 for bounded
    var _done: Bool      # True when producer is finished
    
    fn __init__(out self, max_size: Int = -1):
        """Initialize queue with optional size limit."""
        self._queue = List[T]()
        self._mutex = Mutex()
        self._not_empty = ConditionVariable()
        self._not_full = ConditionVariable()
        self._max_size = max_size
        self._done = False
    
    fn push(mut self, item: T) raises:
        """
        Push item to queue. Blocks if queue is full (bounded mode).
        Raises error if done() has been called.
        """
        self._mutex.lock()
        try:
            if self._done:
                raise Error("Cannot push to queue after done() called")
            
            # Wait if queue is full (bounded mode)
            while self._max_size > 0 and len(self._queue) >= self._max_size:
                self._not_full.wait(self._mutex)
            
            self._queue.append(item^)
            self._not_empty.notify_one()  # Wake one waiting consumer
        finally:
            self._mutex.unlock()
    
    fn pop(mut self) raises -> Optional[T]:
        """
        Pop item from queue. Returns None if queue is empty and done.
        Blocks if queue is empty but not done.
        """
        self._mutex.lock()
        try:
            # Wait while queue is empty and not done
            while len(self._queue) == 0 and not self._done:
                self._not_empty.wait(self._mutex)
            
            if len(self._queue) == 0:
                return None  # Queue empty and done
            
            var item = self._queue.pop(0)
            self._not_full.notify_one()  # Wake producer if waiting
            return item^
        finally:
            self._mutex.unlock()
    
    fn signal_done(mut self):
        """Signal that producer is finished. Consumers will process remaining items then exit."""
        self._mutex.lock()
        try:
            self._done = True
            self._not_empty.notify_all()  # Wake all waiting consumers
        finally:
            self._mutex.unlock()
    
    fn is_empty(self) -> Bool:
        """Check if queue is empty (non-blocking)."""
        self._mutex.lock()
        try:
            return len(self._queue) == 0
        finally:
            self._mutex.unlock()
    
    fn is_done(self) -> Bool:
        """Check if producer is done (non-blocking)."""
        self._mutex.lock()
        try:
            return self._done
        finally:
            self._mutex.unlock()
    
    fn size(self) -> Int:
        """Get current queue size (non-blocking)."""
        self._mutex.lock()
        try:
            return len(self._queue)
        finally:
            self._mutex.unlock()
```

**Testing**:
- Unit tests for push/pop operations
- Test with multiple threads
- Test termination signaling
- Test backpressure (bounded mode)

**Files to Create**:
- `blazeseq/parallel/queue.mojo`
- `tests/test_queue.mojo`

---

### Step 3: Create BatchProducer

**Goal**: Wrap BatchedParser for thread-safe production

**Location**: `blazeseq/parallel/producer.mojo`

**Implementation**:

```mojo
from blazeseq.parser import BatchedParser
from blazeseq.device_record import FastqBatch
from blazeseq.record import FastqRecord
from blazeseq.iostream import Reader
from blazeseq.parallel.queue import ThreadSafeBatchQueue

struct BatchProducer[
    R: Reader,
    check_ascii: Bool = True,
    check_quality: Bool = True,
    batch_size: Int = 1024
]:
    """
    Producer that wraps BatchedParser and pushes batches to a thread-safe queue.
    Runs parsing loop, pushing batches until EOF.
    """
    var parser: BatchedParser[R, check_ascii, check_quality, batch_size]
    var queue: ThreadSafeBatchQueue[FastqBatch]
    var use_soa: Bool  # Structure-of-Arrays (FastqBatch) vs Array-of-Structures (List[FastqRecord])
    
    fn __init__(
        out self,
        var reader: R,
        queue: ThreadSafeBatchQueue[FastqBatch],
        schema: String = "generic",
        default_batch_size: Int = 1024,
        use_soa: Bool = True,
    ) raises:
        self.parser = BatchedParser[R, check_ascii, check_quality, batch_size](
            reader^, schema=schema, default_batch_size=default_batch_size
        )
        self.queue = queue^
        self.use_soa = use_soa
    
    fn run(mut self) raises:
        """
        Main producer loop. Parses batches and pushes to queue until EOF.
        Signals queue when done.
        """
        while True:
            var batch: FastqBatch
            if self.use_soa:
                batch = self.parser.next_batch(max_records=self.parser._batch_size)
            else:
                # Convert AoS to SoA if needed
                var record_list = self.parser.next_record_list(max_records=self.parser._batch_size)
                if len(record_list) == 0:
                    break
                batch = FastqBatch(batch_size=len(record_list))
                for record in record_list:
                    batch.add(record^)
            
            if len(batch) == 0:
                break  # EOF
            
            self.queue.push(batch^)
        
        # Signal that production is complete
        self.queue.signal_done()
```

**Testing**:
- Test producer with small file
- Test with empty file
- Test error handling
- Test termination signaling

**Files to Create**:
- `blazeseq/parallel/producer.mojo`
- `tests/test_producer.mojo`

---

### Step 4: Create BatchConsumer Base

**Goal**: Base consumer struct for pulling batches

**Location**: `blazeseq/parallel/consumer.mojo`

**Implementation**:

```mojo
from blazeseq.parallel.queue import ThreadSafeBatchQueue

struct BatchConsumer[T: Movable]:
    """
    Base consumer that pulls batches from queue and processes them.
    Subclasses implement process_batch() for specific processing logic.
    """
    var queue: ThreadSafeBatchQueue[T]
    var consumer_id: Int
    var processed_count: Int
    
    fn __init__(
        out self,
        queue: ThreadSafeBatchQueue[T],
        consumer_id: Int = 0,
    ):
        self.queue = queue^
        self.consumer_id = consumer_id
        self.processed_count = 0
    
    fn run(mut self) raises:
        """
        Main consumer loop. Pulls batches and processes until queue is done.
        """
        while True:
            var batch_opt = self.queue.pop()
            if batch_opt is None:
                # Queue empty and done
                break
            
            var batch = batch_opt.take()
            self.process_batch(batch^)
            self.processed_count += 1
    
    fn process_batch(mut self, batch: T) raises:
        """
        Process a batch. To be implemented by subclasses.
        """
        raise Error("process_batch() must be implemented by subclass")
```

**Testing**:
- Test consumer with simple processing
- Test termination handling
- Test with multiple consumers

**Files to Create**:
- `blazeseq/parallel/consumer.mojo`
- `tests/test_consumer.mojo`

---

### Step 5: Implement CPUConsumer

**Goal**: CPU-based consumer for processing batches

**Location**: `blazeseq/parallel/cpu_consumer.mojo`

**Implementation**:

```mojo
from blazeseq.parallel.consumer import BatchConsumer
from blazeseq.parallel.queue import ThreadSafeBatchQueue
from blazeseq.record import FastqRecord

# Trait for processing functions
trait ProcessFn:
    fn __call__(self, batch: List[FastqRecord]) raises -> None

struct CPUConsumer[ProcessFn: ProcessFn](BatchConsumer[List[FastqRecord]]):
    """
    CPU consumer that processes List[FastqRecord] batches.
    Uses user-provided processing function.
    """
    var process_fn: ProcessFn
    
    fn __init__(
        out self,
        queue: ThreadSafeBatchQueue[List[FastqRecord]],
        process_fn: ProcessFn,
        consumer_id: Int = 0,
    ):
        BatchConsumer[List[FastqRecord]].__init__(self, queue, consumer_id)
        self.process_fn = process_fn
    
    fn process_batch(mut self, batch: List[FastqRecord]) raises:
        """Process batch using provided function."""
        self.process_fn(batch^)

# Example processing function
fn count_base_pairs(batch: List[FastqRecord]) raises -> Int:
    var total = 0
    for record in batch:
        total += len(record)
    return total
```

**Testing**:
- Test with various processing functions
- Test with multiple CPU consumers
- Measure throughput

**Files to Create**:
- `blazeseq/parallel/cpu_consumer.mojo`
- `tests/test_cpu_consumer.mojo`

---

### Step 6: Implement GPUConsumer

**Goal**: GPU-based consumer for processing batches

**Location**: `blazeseq/parallel/gpu_consumer.mojo`

**Implementation**:

```mojo
from blazeseq.parallel.consumer import BatchConsumer
from blazeseq.parallel.queue import ThreadSafeBatchQueue
from blazeseq.device_record import FastqBatch, DeviceFastqBatch, upload_batch_to_device
from blazeseq.kernels.prefix_sum import enqueue_quality_prefix_sum
from gpu.host import DeviceContext
from gpu.host.device_context import DeviceBuffer

struct GPUConsumer(BatchConsumer[FastqBatch]):
    """
    GPU consumer that processes FastqBatch batches on GPU.
    Uploads batches, runs kernels, downloads results.
    """
    var ctx: DeviceContext
    var kernel_fn: fn(DeviceFastqBatch, DeviceContext) raises -> DeviceBuffer[DType.int32]
    
    fn __init__(
        out self,
        queue: ThreadSafeBatchQueue[FastqBatch],
        kernel_fn: fn(DeviceFastqBatch, DeviceContext) raises -> DeviceBuffer[DType.int32],
        consumer_id: Int = 0,
    ) raises:
        BatchConsumer[FastqBatch].__init__(self, queue, consumer_id)
        self.ctx = DeviceContext()
        self.kernel_fn = kernel_fn
    
    fn process_batch(mut self, batch: FastqBatch) raises:
        """Process batch on GPU."""
        # Upload batch to device
        var device_batch = upload_batch_to_device(batch, self.ctx)
        
        # Run kernel
        var result_buffer = self.kernel_fn(device_batch, self.ctx)
        
        # Synchronize and download results (if needed)
        self.ctx.synchronize()
        
        # Process results or store them
        # (Implementation depends on use case)
```

**Testing**:
- Test GPU consumer with quality prefix-sum kernel
- Test with multiple GPU consumers
- Test GPU memory management
- Measure GPU utilization

**Files to Create**:
- `blazeseq/parallel/gpu_consumer.mojo`
- `tests/test_gpu_consumer.mojo`

---

### Step 7: Add Thread Pool Utilities

**Goal**: Utilities for managing multiple consumer threads

**Location**: `blazeseq/parallel/thread_pool.mojo`

**Implementation**:

```mojo
from threading import Thread  # Verify actual API

struct ThreadPool:
    """
    Simple thread pool for managing multiple consumer threads.
    """
    var threads: List[Thread]
    
    fn __init__(out self):
        self.threads = List[Thread]()
    
    fn spawn[T: Movable](
        mut self,
        consumer: BatchConsumer[T],
    ) raises:
        """Spawn a consumer thread."""
        var thread = Thread(consumer.run)
        self.threads.append(thread^)
        thread.start()
    
    fn join_all(mut self) raises:
        """Wait for all threads to complete."""
        for thread in self.threads:
            thread.join()
```

**Files to Create**:
- `blazeseq/parallel/thread_pool.mojo`

---

### Step 8: Create Example Usage

**Goal**: Demonstrate SPMC usage

**Location**: `examples/example_parallel.mojo`

**Implementation**:

```mojo
"""Example: Single Producer, Multiple Consumer architecture."""

from blazeseq.parallel import (
    ThreadSafeBatchQueue,
    BatchProducer,
    CPUConsumer,
    GPUConsumer,
    ThreadPool,
)
from blazeseq.iostream import FileReader
from blazeseq.record import FastqRecord
from pathlib import Path

fn process_batch_cpu(batch: List[FastqRecord]) raises -> None:
    """Example CPU processing function."""
    var total_bp = 0
    for record in batch:
        total_bp += len(record)
    # Process records...

fn main() raises:
    var file_path = Path("data.fastq")
    
    # Create queue
    var queue = ThreadSafeBatchQueue[FastqBatch](max_size=50)
    
    # Create producer
    var reader = FileReader(file_path)
    var producer = BatchProducer[FileReader, True, True, 1024](
        reader^, queue, use_soa=True
    )
    
    # Create consumers
    var cpu_consumer1 = CPUConsumer(queue, process_batch_cpu, consumer_id=1)
    var cpu_consumer2 = CPUConsumer(queue, process_batch_cpu, consumer_id=2)
    var gpu_consumer1 = GPUConsumer(queue, enqueue_quality_prefix_sum, consumer_id=3)
    
    # Create thread pool
    var pool = ThreadPool()
    
    # Spawn producer thread
    var producer_thread = Thread(producer.run)
    producer_thread.start()
    
    # Spawn consumer threads
    pool.spawn(cpu_consumer1)
    pool.spawn(cpu_consumer2)
    pool.spawn(gpu_consumer1)
    
    # Wait for producer
    producer_thread.join()
    
    # Wait for consumers
    pool.join_all()
    
    print("Processing complete!")
```

**Files to Create**:
- `examples/example_parallel.mojo`

---

### Step 9: Add Error Handling

**Goal**: Robust error handling and propagation

**Tasks**:
1. Add error collection in consumers
2. Propagate errors to main thread
3. Handle producer errors
4. Graceful shutdown on error

**Files to Modify**:
- `blazeseq/parallel/consumer.mojo` - Add error collection
- `blazeseq/parallel/producer.mojo` - Add error handling

---

### Step 10: Performance Optimization

**Goal**: Optimize for performance

**Tasks**:
1. Profile queue operations
2. Optimize batch sizes
3. Tune queue capacity
4. Optimize GPU memory usage
5. Add performance metrics

**Files to Create**:
- `benchmark/benchmark_parallel.mojo`

---

## Testing Strategy

### Unit Tests

Each component should have comprehensive unit tests:

1. **ThreadSafeBatchQueue**:
   - Single-threaded push/pop
   - Multi-threaded stress test
   - Termination signaling
   - Backpressure behavior

2. **BatchProducer**:
   - Small file parsing
   - Empty file handling
   - Error handling

3. **BatchConsumer**:
   - Basic consumption
   - Termination handling

4. **CPUConsumer**:
   - Processing function execution
   - Multiple consumers

5. **GPUConsumer**:
   - GPU upload/download
   - Kernel execution
   - Multiple GPU consumers

### Integration Tests

1. Full SPMC pipeline
2. Mixed CPU/GPU consumers
3. Error recovery
4. Performance benchmarks

## Common Pitfalls

1. **Deadlocks**: Ensure proper lock ordering and timeout handling
2. **Race Conditions**: Use proper synchronization primitives
3. **Memory Leaks**: Ensure batches are properly destroyed
4. **GPU Memory**: Avoid conflicts between GPU consumers
5. **Error Propagation**: Ensure errors are properly handled

## Next Steps

After completing the implementation:

1. Performance benchmarking
2. Documentation updates
3. User guide creation
4. Integration with existing BlazeSeq API
5. CI/CD integration
