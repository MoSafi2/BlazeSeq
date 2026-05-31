# BlazeSeq Mojo package (pre-built .mojopkg)

This directory is populated when you install the `blazeseq` Python package from a wheel (e.g. `pip install blazeseq`). It contains `blazeseq.mojopkg`, a pre-built Mojo package so you can use BlazeSeq from Mojo projects without cloning the repo.

## Using from a Mojo project

1. Install the Python package (this installs the .mojopkg next to the Python package):

   ```bash
   pip install blazeseq
   ```

2. Get the path to this directory in Python:

   ```python
   import blazeseq
   print(blazeseq.mojopkg_path())
   ```

3. When building or running your Mojo code, add that path with `-I` so Mojo can find `blazeseq.mojopkg`. BlazeSeq no longer requires the external `rapidgzip` package to import or run:

   ```bash
   pixi run mojo run -I $(python -c 'import blazeseq; print(blazeseq.mojopkg_path())') your_app.mojo
   ```

## Dependencies

- **Mojo** (same version as the one used to build the package; see project README).
- **rapidgzip**: currently disabled in BlazeSeq. `RapidgzipReader` remains available as a compatibility wrapper and falls back to `GZFile`.
