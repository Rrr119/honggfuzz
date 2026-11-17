#!/usr/bin/env bash
#
# Benchmark honggfuzz coverage backends, with a focus on Intel PT kernel
# (driver) fuzzing and on fusing hardware (PT/BTS) feedback with the default
# compile-time (software) instrumentation.
#
# The benchmark runs the same target/corpus for a fixed time under several
# feedback configurations and records honggfuzz's --statsfile CSV plus the
# observed coverage counters, so runs are comparable across backends.
#
# Usage:
#   ./bench_coverage.sh -t /path/to/target -c /path/to/corpus \
#       [-w /path/to/honggfuzz] [-d 60] [-n 4] [--mode all|soft|ipt|bts|fused|kernel]
#
# Environment overrides:
#   HONGGFUZZ_BIN   path to the honggfuzz binary (default: repo-root ./honggfuzz)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

HONGGFUZZ_BIN="${HONGGFUZZ_BIN:-${REPO_ROOT}/honggfuzz}"
TARGET=""
CORPUS=""
DURATION=60
THREADS=4
MODE="all"

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
    -t | --target)
        TARGET="$2"
        shift 2
        ;;
    -c | --corpus)
        CORPUS="$2"
        shift 2
        ;;
    -w | --honggfuzz)
        HONGGFUZZ_BIN="$2"
        shift 2
        ;;
    -d | --duration)
        DURATION="$2"
        shift 2
        ;;
    -n | --threads)
        THREADS="$2"
        shift 2
        ;;
    --mode)
        MODE="$2"
        shift 2
        ;;
    -h | --help)
        usage
        ;;
    *)
        echo "Unknown argument: $1" >&2
        usage
        ;;
    esac
done

[ -x "${HONGGFUZZ_BIN}" ] || {
    echo "honggfuzz binary not found or not executable: ${HONGGFUZZ_BIN}" >&2
    exit 1
}
[ -n "${TARGET}" ] || {
    echo "missing --target" >&2
    usage
}
command -v "${TARGET}" >/dev/null 2>&1 || [ -x "${TARGET}" ] || {
    echo "target not executable: ${TARGET}" >&2
    exit 1
}
[ -n "${CORPUS}" ] && [ -d "${CORPUS}" ] || {
    echo "corpus directory not found: ${CORPUS}" >&2
    exit 1
}

OUT_DIR="${SCRIPT_DIR}/results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "${OUT_DIR}"

# --- capability detection ---------------------------------------------------

have_intel_pt() {
    [ -r /sys/bus/event_source/devices/intel_pt/type ]
}
have_intel_bts() {
    [ -r /sys/bus/event_source/devices/intel_bts/type ]
}
perf_paranoid() {
    if [ -r /proc/sys/kernel/perf_event_paranoid ]; then
        cat /proc/sys/kernel/perf_event_paranoid
    else
        echo "?"
    fi
}

# A perf event opened on ourselves succeeds only when the backend and the
# perf_event_paranoid policy both allow it.
perf_event_works() {
    local type_path="$1"
    [ -r "${type_path}" ] || return 1
    local ptype
    ptype="$(cat "${type_path}")"
    if command -v perf >/dev/null 2>&1; then
        perf stat -e "${ptype}/" true >/dev/null 2>&1
    else
        # Fall back to the sysfs presence + paranoid policy heuristic.
        local paranoid
        paranoid="$(perf_paranoid)"
        [ "${paranoid}" != "?" ] && [ "${paranoid}" -le 2 ]
    fi
}

echo "== honggfuzz coverage backend benchmark =="
echo "binary   : ${HONGGFUZZ_BIN}"
echo "target   : ${TARGET}"
echo "corpus   : ${CORPUS}"
echo "duration : ${DURATION}s per mode, ${THREADS} threads"
echo "output   : ${OUT_DIR}"
echo "perf_event_paranoid = $(perf_paranoid)"

# --- run one feedback configuration ----------------------------------------
#
# Args: <label> <extra honggfuzz args...>
run_mode() {
    local label="$1"
    shift
    local ws="${OUT_DIR}/${label}/workspace"
    local stats="${OUT_DIR}/${label}/stats.csv"
    mkdir -p "${ws}"

    echo
    echo "-- mode: ${label}"
    # -q keeps logs parseable; --run_time bounds the session; statsfile is the
    # machine-readable coverage/throughput record used by summarize.py.
    if ! "${HONGGFUZZ_BIN}" -q --run_time "${DURATION}" --threads "${THREADS}" \
        --workspace "${ws}" --statsfile "${stats}" -i "${CORPUS}" \
        "$@" -- "${TARGET}" ___FILE___ >"${OUT_DIR}/${label}/console.log" 2>&1; then
        echo "   mode ${label} failed (see ${label}/console.log) - skipping"
        return 1
    fi
    echo "   stats: ${stats}"
}

# Software compile-time instrumentation only (baseline).
run_soft() {
    run_mode soft -z
}

# Hardware-only Intel PT block coverage (userspace target).
run_ipt() {
    if ! have_intel_pt || ! perf_event_works /sys/bus/event_source/devices/intel_pt/type; then
        echo "-- mode: ipt (SKIPPED: Intel PT unavailable or perf access denied)"
        return 0
    fi
    run_mode ipt --linux_perf_ipt_block
}

# Hardware-only Intel BTS edge coverage (userspace target).
run_bts() {
    if ! have_intel_bts || ! perf_event_works /sys/bus/event_source/devices/intel_bts/type; then
        echo "-- mode: bts (SKIPPED: Intel BTS unavailable or perf access denied)"
        return 0
    fi
    run_mode bts --linux_perf_bts_edge
}

# Fused feedback: software instrumentation + Intel PT in the same session.
# Both backends write into the shared coverage bitmap, so either one can flag
# an input as interesting.
run_fused() {
    if ! have_intel_pt || ! perf_event_works /sys/bus/event_source/devices/intel_pt/type; then
        echo "-- mode: fused (SKIPPED: Intel PT unavailable or perf access denied)"
        return 0
    fi
    run_mode fused -z --linux_perf_ipt_block
}

# Kernel-only Intel PT: traces ring-0 (the driver exercised by the target) and
# ignores userspace IPs. Requires an Intel CPU, libipt support and, typically,
# CAP_PERFMON/CAP_SYS_ADMIN plus a relaxed perf_event_paranoid.
run_kernel() {
    if ! have_intel_pt; then
        echo "-- mode: kernel (SKIPPED: no Intel PT PMU on this machine)"
        return 0
    fi
    local paranoid
    paranoid="$(perf_paranoid)"
    if [ "$(id -u)" -ne 0 ] && { [ "${paranoid}" = "?" ] || [ "${paranoid}" -gt 1 ]; }; then
        echo "-- mode: kernel (SKIPPED: kernel tracing needs root or perf_event_paranoid <= 1)"
        return 0
    fi
    run_mode kernel --linux_perf_ipt_block --linux_perf_kernel_only
}

case "${MODE}" in
all)
    run_soft
    run_ipt
    run_bts
    run_fused
    run_kernel
    ;;
soft) run_soft ;;
ipt) run_ipt ;;
bts) run_bts ;;
fused) run_fused ;;
kernel) run_kernel ;;
*)
    echo "unknown --mode '${MODE}'" >&2
    exit 1
    ;;
esac

echo
echo "== summarizing =="
"${SCRIPT_DIR}/summarize.py" "${OUT_DIR}"
