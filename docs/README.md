# BlazeSeq Documentation

This directory contains documentation for BlazeSeq, including architecture guides, implementation details, and usage examples.

## Documentation Index

### Architecture & Design

- **[PARALLEL_ARCHITECTURE.md](./PARALLEL_ARCHITECTURE.md)** - Comprehensive guide to the Single Producer, Multiple Consumer (SPMC) architecture for parallel FASTQ parsing. Includes architecture diagrams, component descriptions, and design considerations.

- **[RAPIDGZIP_ARCHITECTURE.md](./RAPIDGZIP_ARCHITECTURE.md)** - Guide to Multiple Producer, Multiple Consumer (MPMC) architecture enabled by rapidgzip. Explains how parallel decompression and random access change the architecture, including chunk-based reading, record boundary detection, and coordination strategies.

- **[IMPLEMENTATION_GUIDE.md](./IMPLEMENTATION_GUIDE.md)** - Step-by-step implementation guide for adding multithreading and GPU consumption support. Provides detailed code examples and testing strategies.

## Quick Links

- **Main README**: [../README.md](../README.md)
- **Examples**: [../examples/](../examples/)
- **Tests**: [../tests/](../tests/)

## Contributing

When adding new documentation:

1. Follow the existing documentation style
2. Include code examples where applicable
3. Update this README with links to new documents
4. Ensure all code examples are tested and working
