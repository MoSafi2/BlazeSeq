#!/usr/bin/env bash
# Install benchmarking toolchains into the pixi "benchmark" environment if not present.
# Run from repository root: ./benchmark/install_toolchains.sh
# After this, run benchmarks with: pixi run -e benchmark ./benchmark/run_benchmarks.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "=== BlazeSeq benchmark toolchain installer ==="

# --- Ensure pixi is installed ---
if ! command -v pixi >/dev/null 2>&1; then
    echo "pixi not found. Installing pixi..."
    curl -fsSL https://pixi.sh/install.sh | bash
    export PATH="${HOME}/.local/bin:${PATH}"
    if ! command -v pixi >/dev/null 2>&1; then
        echo "After install, ensure ~/.local/bin is on PATH and re-run this script."
        exit 1
    fi
    echo "pixi installed."
else
    echo "pixi already installed."
fi

# --- Install the benchmark environment (hyperfine, rust) ---
echo "Installing/updating pixi environment 'benchmark' (hyperfine, Rust)..."
if ! pixi install -e benchmark; then
    echo "Failed to install benchmark environment. Check pixi.toml [feature.benchmark.dependencies] and [environments]."
    exit 1
fi
echo "Benchmark environment ready."

# --- Julia: not in pixi env on all platforms; check and guide ---
if command -v julia >/dev/null 2>&1; then
    echo "Julia found ($(julia --version 2>/dev/null || true))."
else
    echo "Julia not found. Required for FASTX.jl benchmark."
    echo "  Install from: https://julialang.org/downloads/"
    echo "  Or: conda install -c conda-forge julia  (if you use conda)"
    echo "Ensure 'julia' is on PATH when running run_benchmarks.sh."
fi

# --- C compiler: not in pixi env; check system and guide user ---
export PATH="${HOME}/.cargo/bin:${PATH}"
# When running under pixi run -e benchmark, CONDA_PREFIX is set to the benchmark env
if [ -n "${CONDA_PREFIX}" ] && [ -d "${CONDA_PREFIX}/bin" ]; then
    export PATH="${CONDA_PREFIX}/bin:${PATH}"
fi
if command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1; then
    echo "C compiler (gcc or clang) found."
else
    echo "No C compiler (gcc or clang) found. Required to build the kseq runner."
    echo "  Linux:   sudo apt-get install build-essential   (Debian/Ubuntu)"
    echo "           sudo dnf install gcc                     (Fedora)"
    echo "  macOS:   xcode-select --install"
    echo "Then re-run the benchmark script."
fi

echo ""
echo "=== Done ==="
echo "Run benchmarks with:"
echo "  pixi run -e benchmark ./benchmark/run_benchmarks.sh"
echo ""
echo "Or activate the benchmark env and run manually:"
echo "  pixi shell -e benchmark"
echo "  ./benchmark/run_benchmarks.sh"
