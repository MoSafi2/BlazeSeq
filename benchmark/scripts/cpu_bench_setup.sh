# CPU benchmark setup for Linux: performance governor, disable turbo, optional SMT (hyperthreading), optional CPU pinning.
# Source this from benchmark run scripts. No-op on non-Linux or if tools are missing.
# Usage:
#   source "$SCRIPT_DIR/../scripts/cpu_bench_setup.sh"
#   cpu_bench_setup    # call before running hyperfine
#   hyperfine_cmd ...  # use instead of bare hyperfine (wraps with taskset)
#   # cpu_bench_teardown is called automatically on EXIT

# Default: pin to core 2. Override with BENCH_CPUS (e.g. "0-3").
BENCH_CPUS="${BENCH_CPUS:-2}"

# Saved state for restore on exit
_CPU_BENCH_GOV_SAVED=""
_CPU_BENCH_TURBO_SAVED=""
_CPU_BENCH_TURBO_SYSFS=""
_CPU_BENCH_SMT_CONTROL_SYSFS=""
_CPU_BENCH_SMT_CONTROL_SAVED=""

_cpu_bench_is_truthy() {
    # Treat common user inputs as "true".
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

cpu_bench_setup() {
    [ "$(uname -s)" != "Linux" ] && return 0

    # Optional: disable SMT/hyperthreading (best-effort).
    # This is controlled via DISABLE_HYPERTHREADING, e.g.:
    #   DISABLE_HYPERTHREADING=1 ./run_benchmarks.sh ...
    _CPU_BENCH_SMT_CONTROL_SYSFS="/sys/devices/system/cpu/smt/control"
    if [ -f "$_CPU_BENCH_SMT_CONTROL_SYSFS" ] && _cpu_bench_is_truthy "${DISABLE_HYPERTHREADING:-}"; then
        _CPU_BENCH_SMT_CONTROL_SAVED="$(cat "$_CPU_BENCH_SMT_CONTROL_SYSFS" 2>/dev/null)" || true
        if echo off | sudo tee "$_CPU_BENCH_SMT_CONTROL_SYSFS" >/dev/null 2>&1; then
            echo "CPU SMT disabled"
        else
            echo "Warning: could not disable SMT/hyperthreading (write 'off' to $_CPU_BENCH_SMT_CONTROL_SYSFS)" >&2
        fi
    fi

    # Performance governor
    if command -v cpupower >/dev/null 2>&1; then
        _CPU_BENCH_GOV_SAVED=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null) || true
        if sudo cpupower frequency-set -g performance >/dev/null 2>&1; then
            echo "CPU governor set to performance"
        else
            echo "Warning: could not set performance governor (sudo cpupower frequency-set -g performance)"
        fi
    else
        echo "Warning: cpupower not found; install linux-tools-common (or linux-tools-$(uname -r)) for performance governor"
    fi

    # Disable turbo (Intel intel_pstate; AMD may use a different path)
    _CPU_BENCH_TURBO_SYSFS="/sys/devices/system/cpu/intel_pstate/no_turbo"
    if [ -f "$_CPU_BENCH_TURBO_SYSFS" ]; then
        _CPU_BENCH_TURBO_SAVED=$(cat "$_CPU_BENCH_TURBO_SYSFS" 2>/dev/null) || true
        if echo 1 | sudo tee "$_CPU_BENCH_TURBO_SYSFS" >/dev/null 2>&1; then
            echo "CPU turbo disabled (intel_pstate)"
        else
            echo "Warning: could not disable turbo"
        fi
    else
        # AMD or other: try amd_pstate if present
        if [ -f /sys/devices/system/cpu/amd_pstate/status ]; then
            echo "AMD CPU: amd_pstate present; consider setting to performance mode manually if needed"
        fi
    fi

    return 0
}

cpu_bench_teardown() {
    [ "$(uname -s)" != "Linux" ] && return 0

    if [ -n "$_CPU_BENCH_GOV_SAVED" ] && command -v cpupower >/dev/null 2>&1; then
        sudo cpupower frequency-set -g "$_CPU_BENCH_GOV_SAVED" >/dev/null 2>&1 && echo "CPU governor restored to $_CPU_BENCH_GOV_SAVED" || true
    fi

    if [ -n "$_CPU_BENCH_TURBO_SYSFS" ] && [ -f "$_CPU_BENCH_TURBO_SYSFS" ] && [ -n "${_CPU_BENCH_TURBO_SAVED}" ]; then
        echo "$_CPU_BENCH_TURBO_SAVED" | sudo tee "$_CPU_BENCH_TURBO_SYSFS" >/dev/null 2>&1 && echo "CPU turbo restored" || true
    fi

    # Restore SMT/hyperthreading (best-effort) if we successfully captured prior state.
    if [ -n "$_CPU_BENCH_SMT_CONTROL_SYSFS" ] && [ -f "$_CPU_BENCH_SMT_CONTROL_SYSFS" ] && [ -n "$_CPU_BENCH_SMT_CONTROL_SAVED" ]; then
        echo "$_CPU_BENCH_SMT_CONTROL_SAVED" | sudo tee "$_CPU_BENCH_SMT_CONTROL_SYSFS" >/dev/null 2>&1 \
            && echo "CPU SMT restored to $_CPU_BENCH_SMT_CONTROL_SAVED" \
            || true
    fi

    return 0
}

# Run hyperfine pinned to BENCH_CPUS. Usage: hyperfine_cmd --warmup 2 --runs 5 ...
hyperfine_cmd() {
    if [ "$(uname -s)" = "Linux" ] && command -v taskset >/dev/null 2>&1; then
        taskset -c "$BENCH_CPUS" hyperfine "$@"
    else
        hyperfine "$@"
    fi
}
