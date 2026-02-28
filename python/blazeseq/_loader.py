"""Load the pre-built blazeseq_parser extension (.so) from the package."""

import importlib.util
import sys
from pathlib import Path

_extension_module = None


def _get_extension_module():
    """Load and return the blazeseq_parser extension module from _extension/*.so."""
    global _extension_module
    if _extension_module is not None:
        return _extension_module

    ext_dir = Path(__file__).resolve().parent / "_extension"
    so_files = list(ext_dir.glob("*.so"))
    if not so_files:
        raise ImportError(
            "No pre-built BlazeSeq extension found for this platform. "
            "Install a wheel from PyPI: pip install blazeseq"
        )
    if len(so_files) > 1:
        # Prefer exact name blazeseq_parser.so if present
        exact = ext_dir / "blazeseq_parser.so"
        if exact.exists():
            so_path = exact
        else:
            so_path = so_files[0]
    else:
        so_path = so_files[0]

    spec = importlib.util.spec_from_file_location("blazeseq_parser", so_path)
    if spec is None or spec.loader is None:
        raise ImportError(f"Could not load extension from {so_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["blazeseq_parser"] = module
    spec.loader.exec_module(module)
    _extension_module = module
    return module
