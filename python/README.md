# blazeseq (Python)

Python bindings for [BlazeSeq](https://github.com/MoSafi2/BlazeSeq) — high-performance FASTQ parsing.

**Wheels only:** install from PyPI. No source build of the extension.

```bash
# Install (uv recommended)
uv pip install blazeseq

# Or with pip
pip install blazeseq
```

## Quick start

```python
import blazeseq

# quality_schema defaults to "generic"; use keyword args for clarity
parser = blazeseq.parser("file.fastq", quality_schema="sanger")
while parser.has_more():
    rec = parser.next_record()
    print(rec.id, rec.sequence)
```

Or use the iterator over records:

```python
for rec in parser.records:
    print(rec.id, rec.sequence)
```

For batched iteration (default 100 records per batch):

```python
for batch in parser.batches:
    for rec in batch:
        print(rec.id, rec.sequence)
```

Custom batch size:

```python
for batch in parser.batches_with_size(50):
    for rec in batch:
        print(rec.id, rec.sequence)
```

**Gzip files:** use `.fastq.gz` or `.fq.gz` and set `parallelism` for decompression threads (default 4):

```python
parser = blazeseq.parser("reads.fastq.gz", quality_schema="sanger", parallelism=8)
for rec in parser.records:
    print(rec.id, rec.sequence)
```

---

## API reference

### Module-level

| Function | Description |
|----------|-------------|
| `parser(path, quality_schema="generic", parallelism=4)` | Create a FASTQ parser. Supports `.fastq`, `.fq`, `.fastq.gz`, `.fq.gz`. **quality_schema:** `"generic"`, `"sanger"`, `"solexa"`, `"illumina_1.3"`, `"illumina_1.5"`, `"illumina_1.8"`. **parallelism:** decompression threads for gzip (default 4). Returns a parser supporting `records`, `batches`, `batches_with_size(n)`, `has_more()`, `next_record()`, `next_batch(n)`. |

### Parser (returned by `parser` / `create_parser`)

| Method / attribute | Description |
|-------------------|-------------|
| `has_more()` | Return `True` if there may be more records to read. |
| `next_record()` | Return the next record as a `FastqRecord`. Raises on EOF or parse error. |
| `next_ref_as_record()` | Return the next record (from zero-copy ref) as a `FastqRecord`. Raises on EOF or parse error. |
| `next_batch(max_records)` | Return a batch of up to `max_records` records as a `FastqBatch`. Returns a partial batch at EOF. |
| `records` | Iterable over records: `for rec in parser.records`. |
| `batches` | Iterable over batches (default 100 records per batch): `for batch in parser.batches` then `for rec in batch`. |
| `batches_with_size(batch_size)` | Iterable over batches of the given size. |
| `__iter__` / `__next__` | Iterator protocol; equivalent to iterating over `records`. |

### FastqRecord

| Property / method | Description |
|-------------------|-------------|
| `id` | Read identifier (without leading `@`). |
| `sequence` | Sequence line (bases). |
| `quality` | Quality line (raw quality string). |
| `__len__()` | Sequence length (number of bases). |
| `phred_scores` | Phred quality scores as a Python list of integers. |

### FastqBatch

| Method | Description |
|--------|-------------|
| `num_records()` | Number of records in the batch. |
| `get_record(index)` | Return the record at the given index as a `FastqRecord`. |
| `__iter__` | Iterate over records: `for rec in batch`. |

---

## Local development (uv)

From the repo root, after building the Mojo extension into `python/blazeseq/_extension/`:

```bash
uv pip install -e python/
uv run python tests/test_python_bindings.py
```
