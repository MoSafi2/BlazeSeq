# blazeseq (Python)

Python bindings for [BlazeSeq](https://github.com/MoSafi2/BlazeSeq) — high-performance FASTQ parsing.

**Wheels only:** install from PyPI. No source build of the extension.

```bash
# Install (uv recommended)
uv pip install blazeseq

# Or with pip
pip install blazeseq
```

```python
import blazeseq
parser = blazeseq.create_parser("file.fastq", "sanger")
while blazeseq.has_more(parser):
    rec = blazeseq.next_record(parser)
    print(rec.id(), rec.sequence())
```

## Local development (uv)

From the repo root, after building the Mojo extension into `python/blazeseq/_extension/`:

```bash
uv pip install -e python/
uv run python tests/test_python_bindings.py
```
