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

3. When building or running your Mojo code, add that path with `-I` so Mojo can find `blazeseq.mojopkg`. You also need your Mojo environment to have the **rapidgzip** package (BlazeSeq depends on it). For example, with pixi:

   ```bash
   # One-liner: use blazeseq from pip with rapidgzip from pixi
   pixi run mojo run -I $(python -c 'import blazeseq; print(blazeseq.mojopkg_path())') -I $CONDA_PREFIX/lib/mojo your_app.mojo
   ```

   Or add `blazeseq` via pip and `rapidgzip-mojo` via pixi in the same project, and pass both include paths to `mojo build` / `mojo run`.

## Dependencies

- **Mojo** (same version as the one used to build the package; see project README).
- **rapidgzip**: not included in this package. Provide it via your environment (e.g. [rapidgzip_mojo](https://github.com/MoSafi2/rapidgzip_mojo) in pixi, or another `-I` path where `rapidgzip.mojopkg` lives).
