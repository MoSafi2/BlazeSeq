"""Install and exercise the newest wheel in a disposable environment."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    wheel = max(
        (root / "python/dist").glob("*.whl"), key=lambda path: path.stat().st_mtime
    )
    with tempfile.TemporaryDirectory(prefix="blazeseq-wheel-") as directory:
        environment = Path(directory) / "venv"
        subprocess.run(
            ["uv", "venv", "--python", sys.executable, str(environment)], check=True
        )
        python = environment / "bin/python"
        subprocess.run(
            ["uv", "pip", "install", "--python", str(python), "pytest", str(wheel)],
            check=True,
        )
        clean_environment = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("MOJO_", "MODULAR_", "CONDA_", "PIXI_", "DYLD_"))
            and key not in {"LD_LIBRARY_PATH", "PYTHONPATH", "PYTHONHOME"}
        }
        subprocess.run(
            [
                str(python),
                "-c",
                "from pathlib import Path; import sys, blazeseq; "
                "assert Path(blazeseq.__file__).is_relative_to(sys.prefix), blazeseq.__file__",
            ],
            cwd=directory,
            env=clean_environment,
            check=True,
        )
        subprocess.run(
            [
                str(python),
                "-m",
                "pytest",
                "-q",
                str(root / "tests/test_python_bindings.py"),
            ],
            cwd=directory,
            env=clean_environment,
            check=True,
        )


if __name__ == "__main__":
    main()
