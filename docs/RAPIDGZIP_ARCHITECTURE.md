# Rapidgzip-Enabled Architecture: Multiple Producer, Multiple Consumer (MPMC)

## Overview

When using **rapidgzip** for reading compressed FASTQ files, the architecture can evolve from **Single Producer, Multiple Consumer (SPMC)** to **Multiple Producer, Multiple Consumer (MPMC)**. Rapidgzip enables parallel decompression and random access, allowing multiple threads to read different parts of the compressed file simultaneously.

## Rapidgzip Capabilities

### Key Features

1. **Parallel Decompression**: Multiple threads can decompress different chunks of a gzip file simultaneously
2. **Random Access**: Can seek to specific byte offsets in the compressed file without decompressing everything before it
3. **High Performance**: Achieves 8-12 GB/s decompression speeds with multiple cores
4. **Index Support**: Optional indexes enable faster random access

### Performance Characteristics

- **8.7 GB/s** for base64-encoded data with 128 cores (55x speedup over GNU gzip)
- **5.6 GB/s** for standard data (33x speedup)
- **Up to 24 GB/s** with pre-created indexes

## Architecture Evolution: SPMC → MPMC

### Original SPMC Architecture

```
┌─────────────┐
│ FASTQ File  │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│  Producer   │ (Single thread, sequential reading)
└──────┬──────┘
       │
       ▼
┌─────────────┐
│    Queue    │
└──────┬──────┘
       │
   ┌───┴───┬───┐
   ▼       ▼   ▼
┌─────┐ ┌─────┐ ┌─────┐
│ C1  │ │ C2  │ │ C3  │ (Multiple consumers)
└─────┘ └─────┘ └─────┘
```

**Limitations:**
- Single I/O bottleneck
- Sequential file reading
- Producer may be slower than consumers

### New MPMC Architecture with Rapidgzip

```
┌─────────────────────────────────────────┐
│      Compressed FASTQ File (.gz)        │
└─────────────────────────────────────────┘
         │
    ┌────┼────┬────┬────┐
    │    │    │    │    │
    ▼    ▼    ▼    ▼    ▼
┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐
│ P1 │ │ P2 │ │ P3 │ │ P4 │ │ P5 │ (Multiple Producers)
│    │ │    │ │    │ │    │ │    │
│Chunk│ │Chunk│ │Chunk│ │Chunk│ │Chunk│
│ 0   │ │ 1   │ │ 2   │ │ 3   │ │ 4   │
└──┬──┘ └──┬──┘ └──┬──┘ └──┬──┘ └──┬──┘
   │       │       │       │       │
   └───────┼───────┼───────┼───────┘
           │       │       │
           ▼       ▼       ▼
    ┌───────────────────────────┐
    │   ThreadSafeBatchQueue    │
    │   (Shared by all producers)│
    └───────────┬───────────────┘
                │
        ┌───────┼───────┬───────┐
        │       │       │       │
        ▼       ▼       ▼       ▼
    ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐
    │ CPU  │ │ GPU  │ │ GPU  │ │ CPU  │ (Multiple Consumers)
    │  C1  │ │  C2  │ │  C3  │ │  C4  │
    └──────┘ └──────┘ └──────┘ └──────┘
```

**Advantages:**
- Parallel I/O and decompression
- Multiple producers eliminate I/O bottleneck
- Better CPU utilization
- Scales with number of cores
- Faster overall throughput

## Key Architectural Changes

### 1. Chunk-Based File Reading

Instead of sequential reading, the file is divided into chunks that are processed in parallel.

**Chunk Assignment:**
```mojo
struct ChunkAssignment:
    var start_offset: Int64  # Byte offset in compressed file
    var end_offset: Int64   # Byte offset in compressed file
    var producer_id: Int
```

**Chunk Division Strategies:**

1. **Equal-Sized Chunks** (Simple):
   - Divide file into N equal-sized chunks
   - Each producer gets one chunk
   - Problem: May split records across chunks

2. **Record-Aware Chunks** (Recommended):
   - Divide file into chunks
   - Each producer seeks to chunk start, then finds first complete record
   - Producer reads until chunk end, ensuring complete records
   - May need small overlap between chunks

3. **Index-Based Chunks** (Optimal with rapidgzip index):
   - Use rapidgzip index to find record boundaries
   - Assign chunks aligned to record boundaries
   - No overlap needed

### 2. Record Boundary Detection

**Challenge**: When a producer starts reading from the middle of a file, it may start in the middle of a FASTQ record (4 lines per record).

**Solution**: Each producer must:
1. Seek to assigned chunk start
2. Read forward to find the start of the next complete record (next `@` at start of line)
3. Parse records until reaching chunk end
4. Handle potential overlap with next chunk

**Implementation:**
```mojo
fn find_next_record_start(
    reader: RapidGzipReader,
    start_offset: Int64
) raises -> Int64:
    """
    Seek to start_offset, then find the start of the next complete FASTQ record.
    Returns the byte offset of the record start.
    """
    reader.seek(start_offset)
    
    # Read forward until we find '@' at start of line
    # This indicates the start of a FASTQ record header
    while True:
        var byte = reader.read_byte()
        if byte == ord('@'):
            # Check if this is start of line (previous char was '\n')
            var prev_pos = reader.tell() - 2
            reader.seek(prev_pos)
            var prev_byte = reader.read_byte()
            if prev_byte == ord('\n') or prev_pos == start_offset:
                return reader.tell() - 1
        elif byte == -1:  # EOF
            return -1
```

### 3. Chunk Overlap Handling

**Problem**: Records may span chunk boundaries.

**Solutions**:

1. **Overlap Chunks**:
   - Each chunk overlaps slightly with neighbors
   - Producer reads from record start to record end (may extend beyond chunk boundary)
   - Deduplicate records at boundaries (using record IDs)

2. **Boundary Records**:
   - Producer reads complete records only
   - If chunk ends mid-record, producer stops at previous complete record
   - Next producer starts from where previous ended

3. **Coordinated Boundaries** (Best):
   - Use rapidgzip index to find exact record boundaries
   - Assign chunks aligned to record boundaries
   - No overlap needed, no duplication

### 4. Multiple Producer Coordination

**Shared Queue**: All producers push to the same `ThreadSafeBatchQueue`

**Termination**: 
- Each producer signals completion when its chunk is done
- Queue tracks number of active producers
- When all producers are done, signal consumers

**Load Balancing**:
- Different chunks may have different numbers of records
- Queue naturally balances load across consumers
- Fast producers contribute more batches

## Implementation Components

### 1. RapidGzipReader

Wrapper around rapidgzip that supports:
- Random access (seek to byte offset)
- Parallel reading from multiple threads
- Record boundary detection

```mojo
struct RapidGzipReader(Reader):
    var handle: c_void_ptr  # rapidgzip handle
    var file_path: Path
    
    fn __init__(out self, path: Path) raises:
        """Open rapidgzip file for parallel reading."""
        # Initialize rapidgzip with parallel support
        ...
    
    fn seek(mut self, offset: Int64) raises:
        """Seek to byte offset in compressed file."""
        ...
    
    fn tell(self) -> Int64:
        """Get current byte offset."""
        ...
    
    fn read_chunk(mut self, start: Int64, end: Int64) raises -> Span[Byte]:
        """Read chunk from start to end offset."""
        ...
```

### 2. ChunkProducer

Producer that reads and parses a specific chunk of the file.

```mojo
struct ChunkProducer[
    check_ascii: Bool = True,
    check_quality: Bool = True,
    batch_size: Int = 1024
]:
    var reader: RapidGzipReader
    var chunk: ChunkAssignment
    var queue: ThreadSafeBatchQueue[FastqBatch]
    var quality_schema: QualitySchema
    
    fn __init__(
        out self,
        reader: RapidGzipReader,
        chunk: ChunkAssignment,
        queue: ThreadSafeBatchQueue[FastqBatch],
        schema: String = "generic",
    ) raises:
        self.reader = reader^
        self.chunk = chunk
        self.queue = queue^
        self.quality_schema = parse_schema(schema)
    
    fn run(mut self) raises:
        """
        Read chunk, find record boundaries, parse batches, push to queue.
        """
        # Seek to chunk start
        var record_start = find_next_record_start(
            self.reader, self.chunk.start_offset
        )
        
        if record_start == -1:
            return  # No records in this chunk
        
        # Create parser for this chunk
        var parser = BatchedParser[...](
            # Wrap reader with chunk boundaries
            ChunkReader(self.reader, record_start, self.chunk.end_offset),
            schema=self.quality_schema,
        )
        
        # Parse and push batches
        while True:
            var batch = parser.next_batch(max_records=self.batch_size)
            if len(batch) == 0:
                break
            self.queue.push(batch^)
```

### 3. ChunkCoordinator

Manages chunk assignment and producer coordination.

```mojo
struct ChunkCoordinator:
    var file_size: Int64
    var num_producers: Int
    var chunks: List[ChunkAssignment]
    var use_index: Bool
    
    fn __init__(
        out self,
        file_size: Int64,
        num_producers: Int,
        use_rapidgzip_index: Bool = False,
    ):
        self.file_size = file_size
        self.num_producers = num_producers
        self.use_index = use_rapidgzip_index
        self.chunks = self._compute_chunks()
    
    fn _compute_chunks(self) -> List[ChunkAssignment]:
        """
        Compute chunk assignments for producers.
        If index available, align to record boundaries.
        Otherwise, use equal-sized chunks with overlap.
        """
        if self.use_index:
            return self._compute_indexed_chunks()
        else:
            return self._compute_equal_chunks()
    
    fn _compute_equal_chunks(self) -> List[ChunkAssignment]:
        """Divide file into equal chunks with small overlap."""
        var chunk_size = self.file_size // self.num_producers
        var overlap = 1024 * 1024  # 1MB overlap to handle record boundaries
        var chunks = List[ChunkAssignment]()
        
        for i in range(self.num_producers):
            var start = i * chunk_size
            var end = min((i + 1) * chunk_size + overlap, self.file_size)
            chunks.append(ChunkAssignment(
                start_offset=start,
                end_offset=end,
                producer_id=i,
            ))
        return chunks^
```

## Comparison: SPMC vs MPMC

| Aspect | SPMC | MPMC (with rapidgzip) |
|--------|------|------------------------|
| **I/O Bottleneck** | Single producer | Multiple producers |
| **Decompression** | Sequential | Parallel |
| **Scalability** | Limited by single producer | Scales with cores |
| **Complexity** | Lower | Higher (chunk coordination) |
| **Memory** | Lower | Higher (multiple readers) |
| **Throughput** | ~5 GB/s (single core I/O) | 8-12 GB/s (parallel I/O) |
| **Best For** | Uncompressed files, small files | Large compressed files |

## Hybrid Architecture

You can support both modes:

```mojo
enum ParserMode:
    SPMC  # Single Producer, Multiple Consumer
    MPMC  # Multiple Producer, Multiple Consumer

struct AdaptivePipeline:
    var mode: ParserMode
    var file_path: Path
    var is_compressed: Bool
    
    fn __init__(
        out self,
        file_path: Path,
        prefer_parallel: Bool = True,
    ):
        self.file_path = file_path
        self.is_compressed = file_path.suffix == ".gz"
        
        # Choose mode based on file type and preferences
        if self.is_compressed and prefer_parallel:
            self.mode = ParserMode.MPMC
        else:
            self.mode = ParserMode.SPMC
    
    fn run(mut self) raises:
        if self.mode == ParserMode.MPMC:
            # Use rapidgzip with multiple producers
            var pipeline = MPMCPipeline(self.file_path, ...)
            pipeline.run()
        else:
            # Use standard SPMC
            var pipeline = SPMCPipeline(self.file_path, ...)
            pipeline.run()
```

## Performance Considerations

### Producer Count

- **Too Few**: Underutilize I/O bandwidth
- **Too Many**: Overhead from coordination, memory pressure
- **Optimal**: Match number of CPU cores or I/O channels (typically 4-8)

### Chunk Size

- **Too Small**: Overhead from chunk coordination, more boundary handling
- **Too Large**: Less parallelism, slower startup
- **Optimal**: 64-256 MB chunks (depends on file size and record count)

### Queue Size

- **Larger Queue**: Better buffering, less blocking
- **Smaller Queue**: Lower memory usage, more backpressure
- **Optimal**: 50-200 batches (depends on batch size and memory)

## Implementation Challenges

### 1. Record Boundary Detection

**Challenge**: Finding record boundaries when starting from middle of file.

**Solutions**:
- Use rapidgzip index (if available)
- Scan forward for `@` at start of line
- Cache record boundaries for repeated access

### 2. Chunk Overlap

**Challenge**: Records may span chunk boundaries.

**Solutions**:
- Small overlap between chunks
- Deduplicate records using IDs
- Use index to avoid overlap

### 3. Error Handling

**Challenge**: Errors in one producer shouldn't crash entire pipeline.

**Solutions**:
- Per-producer error collection
- Graceful degradation (continue with remaining producers)
- Error reporting and recovery

### 4. Memory Management

**Challenge**: Multiple rapidgzip readers consume memory.

**Solutions**:
- Limit number of concurrent producers
- Reuse readers when possible
- Monitor memory usage

## Migration Path

1. **Phase 1**: Implement RapidGzipReader wrapper
2. **Phase 2**: Add chunk coordination and ChunkProducer
3. **Phase 3**: Implement MPMCPipeline
4. **Phase 4**: Add rapidgzip index support
5. **Phase 5**: Performance tuning and optimization

## Dependencies

- **rapidgzip**: Python package or C++ library
- **Mojo FFI**: For calling rapidgzip C++ API (if using C++ library)
- **Index Generation**: Tools for creating rapidgzip indexes (optional)

## References

- Rapidgzip GitHub: https://github.com/mxmlnkn/rapidgzip
- Rapidgzip Paper: "Rapidgzip: Parallel Decompression and Seeking in Gzip Files Using Cache Prefetching"
- Mojo FFI Documentation: For integrating C++ libraries
