# Parallel Architecture: Single Producer, Multiple Consumer (SPMC)

## Overview

This document outlines the architecture and implementation plan for enabling parallel processing of FASTQ files using a **Single Producer, Multiple Consumer (SPMC)** pattern. This architecture allows one thread to parse FASTQ records while multiple threads (CPU or GPU) consume and process batches in parallel.

## Architecture Design

```
┌─────────────────────────────────────────────────────────────┐
│                    FASTQ File                               │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│              BatchedParser (Producer Thread)                 │
│  - Reads from file sequentially                             │
│  - Parses batches of records                                │
│  - Pushes batches to queue                                  │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        │ pushes batches
                        ▼
┌─────────────────────────────────────────────────────────────┐
│         ThreadSafeBatchQueue (Synchronization Layer)         │
│  - Thread-safe queue with mutex/condition variables         │
│  - Supports bounded/unbounded operation                     │
│  - Handles backpressure when queue is full                  │
│  - Signals termination when producer finishes               │
└───────────────────────┬─────────────────────────────────────┘
                        │
        ┌───────────────┼───────────────┬───────────────┐
        │               │               │               │
        ▼               ▼               ▼               ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ CPU Consumer │ │ GPU Consumer │ │ GPU Consumer │ │ CPU Consumer │
│   Thread 1   │ │   Thread 2   │ │   Thread 3   │ │   Thread 4   │
│              │ │              │ │              │ │              │
│ - Pulls     │ │ - Pulls     │ │ - Pulls     │ │ - Pulls     │
│   batches   │ │   batches   │ │   batches   │ │   batches   │
│ - Processes │ │ - Uploads   │ │ - Uploads   │ │ - Processes │
│   records   │ │   to GPU    │ │   to GPU    │ │   records   │
│ - CPU work  │ │ - Runs      │ │ - Runs      │ │ - CPU work  │
│              │ │   kernels   │ │   kernels   │ │              │
└──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘
```

## Components

### 1. ThreadSafeBatchQueue

A thread-safe queue that enables communication between the producer and consumers.

**Requirements:**
- Thread-safe push/pop operations using mutex
- Condition variables for blocking when queue is empty/full
- Support for both bounded (with backpressure) and unbounded operation
- Termination signaling mechanism (poison pill or sentinel value)
- Movable batch types (`FastqBatch` or `List[FastqRecord]`)

**Interface:**
```mojo
struct ThreadSafeBatchQueue[T: Movable]:
    var _queue: List[T]
    var _mutex: Mutex
    var _not_empty: ConditionVariable
    var _not_full: ConditionVariable
    var _max_size: Int  # -1 for unbounded
    var _done: Bool
    
    fn push(mut self, item: T) raises
    fn pop(mut self) raises -> Optional[T]
    fn is_empty(self) -> Bool
    fn signal_done(mut self)
    fn wait_for_batch(mut self) raises -> Optional[T]
```

### 2. BatchProducer

Wrapper around `BatchedParser` that runs in a producer thread.

**Requirements:**
- Wraps `BatchedParser` instance
- Runs parsing loop in separate thread (or can be called from thread)
- Pushes batches to `ThreadSafeBatchQueue`
- Handles EOF and signals completion
- Error handling and propagation

**Interface:**
```mojo
struct BatchProducer[
    R: Reader,
    check_ascii: Bool,
    check_quality: Bool,
    batch_size: Int
]:
    var parser: BatchedParser[R, check_ascii, check_quality, batch_size]
    var queue: ThreadSafeBatchQueue[FastqBatch]
    var use_aos: Bool  # Array-of-Structures vs Structure-of-Arrays
    
    fn run(mut self) raises
    fn run_aos(mut self) raises  # Produces List[FastqRecord]
    fn run_soa(mut self) raises  # Produces FastqBatch
```

### 3. BatchConsumer (Base)

Base consumer struct that pulls batches from queue.

**Requirements:**
- Pulls batches from `ThreadSafeBatchQueue`
- Handles termination signals
- Abstract processing method (to be implemented by specific consumers)
- Error handling

**Interface:**
```mojo
struct BatchConsumer[T: Movable]:
    var queue: ThreadSafeBatchQueue[T]
    var consumer_id: Int
    
    fn run(mut self) raises
    fn process_batch(mut self, batch: T) raises
        # Abstract - to be implemented by specific consumers
```

### 4. CPUConsumer

Consumer that processes batches on CPU threads.

**Requirements:**
- Extends `BatchConsumer[List[FastqRecord]]`
- Processes records in batch (e.g., validation, filtering, statistics)
- Can be customized with user-defined processing function
- Thread-safe result aggregation (if needed)

**Interface:**
```mojo
struct CPUConsumer[
    ProcessFn: fn(List[FastqRecord]) raises -> None
](BatchConsumer[List[FastqRecord]]):
    var process_fn: ProcessFn
    
    fn process_batch(mut self, batch: List[FastqRecord]) raises
```

### 5. GPUConsumer

Consumer that processes batches on GPU.

**Requirements:**
- Extends `BatchConsumer[FastqBatch]`
- Owns a `DeviceContext` and GPU stream
- Uploads batches to GPU device
- Runs GPU kernels (e.g., quality prefix-sum)
- Downloads results back to host
- Manages GPU memory efficiently

**Interface:**
```mojo
struct GPUConsumer(BatchConsumer[FastqBatch]):
    var ctx: DeviceContext
    var stream: GPUStream  # Per-consumer stream
    var kernel_fn: fn(DeviceFastqBatch, DeviceContext) raises -> DeviceBuffer
    
    fn process_batch(mut self, batch: FastqBatch) raises
    fn upload_to_device(mut self, batch: FastqBatch) raises -> DeviceFastqBatch
    fn run_kernel(mut self, device_batch: DeviceFastqBatch) raises
    fn download_results(mut self, device_buffer: DeviceBuffer) raises
```

## Implementation Details

### Thread Safety Considerations

1. **Batch Ownership**: Batches must be `Movable` and transferred (not shared) between threads
2. **Queue Synchronization**: Use mutex + condition variables for thread-safe operations
3. **GPU Context**: Each GPU consumer needs its own `DeviceContext` or stream
4. **Error Handling**: Errors from consumers should be collected and reported

### Memory Management

1. **Batch Lifecycle**: 
   - Producer creates batches
   - Queue holds batches temporarily
   - Consumer takes ownership and processes
   - Consumer destroys batch after processing

2. **GPU Memory**:
   - Each GPU consumer manages its own device buffers
   - Use memory pools to reduce allocation overhead
   - Async transfers to overlap computation and data movement

### Backpressure Handling

When queue is full:
- Producer blocks on `push()` until space is available
- Prevents unbounded memory growth
- Configurable queue size based on available memory

### Termination

Producer signals completion by:
1. Pushing a sentinel/poison pill value, OR
2. Calling `queue.signal_done()`

Consumers:
- Check for sentinel value or `done` flag
- Exit processing loop when termination is signaled
- Process any remaining batches in queue

## Usage Example

```mojo
from blazeseq.parallel import (
    ThreadSafeBatchQueue,
    BatchProducer,
    CPUConsumer,
    GPUConsumer,
)
from blazeseq.iostream import FileReader
from pathlib import Path

fn main() raises:
    # Create queue
    var queue = ThreadSafeBatchQueue[FastqBatch](max_size=100)
    
    # Create producer
    var reader = FileReader(Path("data.fastq"))
    var producer = BatchProducer[FileReader, True, True, 1024](
        reader^, queue, use_aos=False
    )
    
    # Create consumers
    var cpu_consumer1 = CPUConsumer(queue, consumer_id=1, process_fn=my_cpu_fn)
    var cpu_consumer2 = CPUConsumer(queue, consumer_id=2, process_fn=my_cpu_fn)
    var gpu_consumer1 = GPUConsumer(queue, consumer_id=3, kernel_fn=quality_prefix_sum)
    var gpu_consumer2 = GPUConsumer(queue, consumer_id=4, kernel_fn=quality_prefix_sum)
    
    # Spawn threads (pseudo-code - depends on Mojo threading API)
    var producer_thread = Thread(producer.run)
    var cpu_thread1 = Thread(cpu_consumer1.run)
    var cpu_thread2 = Thread(cpu_consumer2.run)
    var gpu_thread1 = Thread(gpu_consumer1.run)
    var gpu_thread2 = Thread(gpu_consumer2.run)
    
    # Start all threads
    producer_thread.start()
    cpu_thread1.start()
    cpu_thread2.start()
    gpu_thread1.start()
    gpu_thread2.start()
    
    # Wait for completion
    producer_thread.join()
    cpu_thread1.join()
    cpu_thread2.join()
    gpu_thread1.join()
    gpu_thread2.join()
```

## GPU-Specific Considerations

### Multiple GPU Consumers

1. **Device Context**: Each consumer should have its own `DeviceContext` or use separate streams
2. **Stream Parallelism**: Use CUDA streams (or Mojo equivalent) for concurrent kernel execution
3. **Memory Isolation**: Each consumer manages its own device buffers to avoid conflicts
4. **Load Balancing**: GPU consumers may process batches slower than CPU consumers - queue helps balance

### GPU Memory Optimization

1. **Pinned Memory**: Use pinned host buffers for faster CPU→GPU transfers
2. **Memory Pools**: Pre-allocate device buffers and reuse them
3. **Async Transfers**: Overlap data transfers with kernel execution using streams
4. **Batch Size**: Tune batch size based on GPU memory capacity

## Performance Considerations

### Producer Bottleneck

- Single producer may become bottleneck for very fast consumers
- Consider: larger batch sizes, faster I/O (NVMe), or multiple producers (MPMC)

### Consumer Load Balancing

- Queue naturally balances load across consumers
- Fast consumers process more batches
- Consider: work-stealing for better load distribution

### GPU Utilization

- Multiple GPU consumers can saturate GPU better than single consumer
- Use streams for concurrent kernel execution
- Monitor GPU utilization and adjust consumer count

## Testing Strategy

1. **Unit Tests**:
   - Thread-safe queue operations
   - Producer/consumer lifecycle
   - Termination signaling

2. **Integration Tests**:
   - Single producer, multiple consumers
   - Mixed CPU/GPU consumers
   - Error handling and recovery

3. **Performance Tests**:
   - Throughput vs. consumer count
   - Latency measurements
   - GPU utilization metrics

## Dependencies

### Mojo Standard Library

- `threading` module (if available): Thread creation, mutex, condition variables
- `sync` module: Synchronization primitives
- `gpu.host`: GPU device context and streams

### External Dependencies

- None (uses existing BlazeSeq components)

## Migration Path

### Phase 1: Core Infrastructure
1. Implement `ThreadSafeBatchQueue`
2. Create `BatchProducer` wrapper
3. Create `BatchConsumer` base struct

### Phase 2: CPU Consumers
4. Implement `CPUConsumer`
5. Add thread pool utilities
6. Create example usage

### Phase 3: GPU Consumers
7. Implement `GPUConsumer`
8. Add GPU stream management
9. Optimize GPU memory usage

### Phase 4: Polish
10. Error handling and recovery
11. Performance tuning
12. Documentation and examples

## Open Questions

1. **Mojo Threading API**: What threading primitives are available in Mojo 0.26.1?
2. **GPU Streams**: How to create and manage GPU streams per consumer?
3. **Error Propagation**: Best way to propagate errors from consumers to main thread?
4. **Dynamic Scaling**: Should consumer count be configurable at runtime?

## References

- Mojo Manual: https://docs.modular.com/mojo/manual/
- GPU Programming Guide: Mojo GPU documentation
- Threading Best Practices: Mojo concurrency patterns
