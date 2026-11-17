# Coverage-backend benchmarks (Intel PT kernel fuzzing)

This directory benchmarks honggfuzz's coverage backends and quantifies the
benefit of fusing hardware (Intel PT/BTS) feedback with the default
compile-time software instrumentation.

## What is measured

`bench_coverage.sh` runs the same target and corpus for a fixed time under five
feedback configurations and stores one honggfuzz `--statsfile` CSV per run:

| Mode     | Flags                                            | Feedback source                          |
|----------|--------------------------------------------------|------------------------------------------|
| `soft`   | `-z`                                             | Compile-time software instrumentation    |
| `ipt`    | `--linux_perf_ipt_block`                         | Intel PT block coverage (userspace)      |
| `bts`    | `--linux_perf_bts_edge`                          | Intel BTS edge coverage (userspace)      |
| `fused`  | `-z --linux_perf_ipt_block`                      | Software + Intel PT, merged in one bitmap|
| `kernel` | `--linux_perf_ipt_block --linux_perf_kernel_only`| Intel PT ring-0 (kernel/driver) coverage |

Modes that the host cannot support (no Intel PT PMU, missing `libipt.so`, or a
locked-down `perf_event_paranoid`) are skipped with an explanatory message
rather than failing the whole benchmark.

## Prerequisites

- An Intel CPU with Processor Trace for the `ipt`, `fused` and `kernel` modes
  (presence is read from `/sys/bus/event_source/devices/intel_pt/type`).
- honggfuzz built against `libipt` (`libipt-dev`); the Makefile enables it
  automatically when `intel-pt.h` is installed.
- A target built with the honggfuzz compiler wrappers for the `soft` and
  `fused` modes, e.g. `./hfuzz_cc/hfuzz-clang -o target target.c`.
- For kernel-only tracing, sufficient privileges:
  - run as root (or with `CAP_PERFMON`/`CAP_SYS_ADMIN`), and
  - `echo 1 > /proc/sys/kernel/perf_event_paranoid` (or a lower value),
  - `echo 0 > /proc/sys/kernel/kptr_restrict` so kernel symbols resolve.

## Running

```shell
# Build honggfuzz first (add libipt-dev for the PT modes)
make

# Userspace comparison, 60s per mode, 4 threads
./bench_coverage.sh -t ./my_target -c ./corpus -d 60 -n 4

# A single mode, e.g. only the kernel/driver run (typically as root)
sudo ./bench_coverage.sh -t ./examples/linux_kernel_ip/tun -c ./corpus --mode kernel
```

Results land in `results/<timestamp>/<mode>/` (`stats.csv`, `console.log`,
per-mode workspace). After all runs, `summarize.py` prints and writes
`summary.csv` and `summary.md`, including the fusion delta:

```text
Fusion delta (fused vs. soft block coverage): +60 (soft=200 fused=260)
```

## Reproducing a kernel-driver run manually

The bundled `examples/linux_kernel_ip/tun` harness drives the kernel TUN
network driver. The equivalent raw command for the `kernel` mode is:

```shell
sudo ./honggfuzz -i ./corpus -W ./ws --linux_perf_ipt_block \
    --linux_perf_kernel_only -- ./examples/linux_kernel_ip/tun ___FILE___
```

In kernel-only mode honggfuzz sets `exclude_user` and traces ring-0, so the
`ipt:` counter on the status line reflects unique kernel basic blocks reached
through the driver ioctl/syscall interface.

## Interpreting the results

- `exec_per_sec` shows the per-backend overhead; hardware tracing (especially
  PT packet decoding) is usually slower than pure software instrumentation.
- `block_cov`/`edge_cov` show unique coverage. `fused` should reach at least the
  union of the two individual backends because both write the shared
  `bbMapPc` bitmap.
- The `kernel` mode reports driver coverage that software instrumentation can
  never see, since the fuzzed userspace harness contains no kernel code.
