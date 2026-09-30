# Measurements

Everything on this page is reproduced by `bench/run-bench.sh`; the raw output it
produces lives in `bench/raw/`. If a number here isn't backed by a file in that
directory, it doesn't belong on this page.

## Test setup

| | |
|---|---|
| Device | HONOR **AAK-AN00** |
| SoC | Qualcomm **SM8750** (Snapdragon 8 Elite), 8 cores |
| GPU | **Adreno 830**, exposed via **Turnip** (Mesa open-source Vulkan driver) |
| OS | Android **16** (SDK 36), kernel `6.6.118-android15` |
| RAM | 11,238 MB total + 12,287 MB swap |
| Runtime | Termux, `clang 21.1.8`, `cmake 4.4.3`, Vulkan loader `1.4.364` |
| Model | **Qwen2.5-Coder-7B Q4_K_M**, 4.36 GiB |
| Build | llama.cpp `0.5.0-dev`, `-DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release` |

> We did **not** verify which retail product `AAK-AN00` maps to. The SoC and GPU
> strings are read directly from the device (`getprop`, `llama-bench`).

## 1. Throughput — `llama-bench -r 3`

The same command run twice, on two different days, in independent sessions.
Both runs are shown because the spread between them is itself informative.

**Run 1** (`bench/raw/llama-bench-run1.txt`)

| ngl | test | t/s |
|---|---|---|
| 0 | pp64 | 37.10 ± 0.48 |
| 0 | tg32 | 9.86 ± 1.07 |
| 99 | pp64 | **45.76 ± 0.02** |
| 99 | tg32 | **9.31 ± 0.12** |

**Run 2** (`bench/raw/llama-bench-run2.txt`)

| ngl | test | t/s |
|---|---|---|
| 0 | pp64 | 36.34 ± 0.70 |
| 0 | tg32 | 12.00 ± 0.79 |
| 99 | pp64 | **45.77 ± 0.02** |
| 99 | tg32 | **10.46 ± 0.08** |

### What replicates, and what doesn't

| quantity | run 1 | run 2 | verdict |
|---|---|---|---|
| GPU pp64 | 45.76 ± 0.02 | 45.77 ± 0.02 | **reproduces to 2 decimal places** |
| CPU pp64 | 37.10 ± 0.48 | 36.34 ± 0.70 | reproduces (~2%) |
| GPU tg32 | 9.31 ± 0.12 | 10.46 ± 0.08 | varies ~12% |
| CPU tg32 | 9.86 ± 1.07 | 12.00 ± 0.79 | **varies ~22%** |

The GPU prompt-processing number is the most stable measurement on this device —
its standard deviation is **±0.02 t/s**, small enough that the +23–26% gap over
CPU prompt processing is unambiguous.

Token generation does not replicate as tightly, but the *direction* is consistent
in both runs: **GPU token generation is not faster than CPU** (9.31 < 9.86 and
10.46 < 12.00).

> ⚠️ If you take one thing from this page: **do not quote a single `llama-cli`
> run from this device.** We did exactly that and got a figure that was wrong by
> an order of magnitude. See `CORRECTIONS.md`.

## 2. CPU time — the metric that actually matters on a phone

`bench/raw/cpu-seconds.txt`. Sampling `utime+stime` from `/proc/<pid>/stat`:

| run | `-ngl 99` | `-ngl 0` | ratio |
|---|---|---|---|
| 1 | **5 CPU-s** (wall 10 s) | **33 CPU-s** (wall 13 s) | 6.6× |
| 2 | **4 CPU-s** (wall 8 s) | **35 CPU-s** (wall 13 s) | 8.8× |

Same 96-token generation. The GPU run finishes *sooner* while consuming
**roughly one seventh of the CPU**.

This is the real result of the project. On a phone the scarce resource is not
FLOPs, it is the ability to coexist with the foreground: thermal headroom,
battery, and a responsive UI. Moving the matmuls to the GPU buys that — it does
not buy tokens/sec.

## 3. Why generation doesn't speed up

From `bench/raw/llama-bench-run1.txt`, the device capability line llama.cpp prints:

```
ggml_vulkan: 0 = Adreno (TM) 830 (turnip Mesa driver) | uma: 1 | fp16: 1 | bf16: 0
              | fp4: 0 | warp size: 64 | shared memory: 32768
              | int dot: 0 | matrix cores: none
```

**`matrix cores: none`** and **`int dot: 0`**.

The open-source Turnip driver does not expose the Adreno's matrix/tensor units or
its integer dot-product instructions to the application. ggml's Vulkan backend
therefore cannot take the cooperative-matrix path and falls back to scalar/vector
shaders. Token generation is memory-bandwidth-bound anyway, and the CPU on this
SoC has `i8mm` and `dotprod`, which it can use.

So this is not a build mistake or a wrong device selection. **It is the current
ceiling of this software stack.**

If a future Turnip exposes `matrix cores`, the same configuration should improve
substantially. We would like to be wrong about this.

## 4. GPU utilisation — what we could NOT measure

The natural success criterion, "watch GPU utilisation go above 50%", **cannot be
evaluated on this device without root.** All six candidate sources are
unreadable (SELinux):

```
/sys/kernel/debug/kgsl/kgsl-3d0/gpubusy              NOT READABLE
/sys/kernel/debug/kgsl/kgsl-3d0/gpu_busy_percentage  NOT READABLE
/sys/class/kgsl/kgsl-3d0/gpubusy                     NOT READABLE
/proc/gpuinfo                                        NOT READABLE
/proc/gpufreq/gpufreq_opp_dump                       NOT READABLE
/sys/kernel/ged/hal/gpu_utilization                  NOT READABLE
```

There is no `dumpsys` in Termux, no root, and no GPU entry under `/proc` or
`/sys/class`. **We are not going to invent a percentage.**

### What we measured instead

Four pieces of evidence that are stronger than a utilisation reading, because
each one is impossible if the GPU is *not* being used:

**(a) Only the real GPU is enumerated as a compute device.**
The system ships two Vulkan ICDs — `freedreno_icd` (Adreno) and `lvp_icd`
(lavapipe, a **CPU software rasteriser**). If ggml picked lavapipe, "Vulkan works"
would be true and "GPU is used" would be false. It doesn't:

```
$ llama-cli --list-devices
Available devices:
  Vulkan0: Adreno (TM) 830 (8428 MiB, 5682 MiB free)
```

**(b) All layers are actually placed on the device, with real device buffers.**

```
load_tensors: offloaded 29/29 layers to GPU
load_tensors:      Vulkan0 model buffer size =  4168.09 MiB
load_tensors:  Vulkan_Host model buffer size =   292.36 MiB
llama_kv_cache:    Vulkan0 KV buffer size =   532.00 MiB
sched_reserve:     Vulkan0 compute buffer size =  134.51 MiB
```

4.1 GiB of weights sitting in a device-local buffer is not something that happens
on a CPU path.

**(c) The process holds the Adreno driver device node open** (`bench/raw/proc-evidence.log`):

```
fd_kgsl_open=1        # /dev/kgsl-3d0 is open in llama-cli's fd table
maps_freedreno=3      # libvulkan_freedreno.so is mapped
maps_libvulkan=9
```

`/dev/kgsl-3d0` is the Qualcomm GPU driver node. Nothing on a CPU-only path
opens it.

**(d) CPU time collapses** — section 2 above. 33 → 5 CPU-seconds is not
explainable by anything other than the work having moved somewhere else.

Note that `maps_lvp=3` also shows up: the Vulkan loader maps *every* installed ICD
during instance enumeration. Its presence is expected and proves nothing by
itself — which is exactly why (a) matters.

## Reproducing

```sh
git clone <this repo> ~/termux-harness
cd ~/termux-harness
bash install.sh
bash bench/run-bench.sh run3   # writes bench/raw/*-run3.txt ; restarts llama-server after
```

Artifacts are named `<name>-<label>.<ext>`, so a fresh run never overwrites a
published one. The numbers on this page come from the runs tagged `run1` and
`run2`; pick a new label (e.g. `run3`) to produce a comparable run alongside
them, or `bash bench/run-bench.sh run1 --force` to overwrite the published run 1
artifacts in place.

The **un-suffixed** files — `device-info.txt`, `gpu-evidence.txt`,
`cpu-seconds.txt`, `proc-evidence.log` — are those published runs' artifacts with
hand-written annotation on top: the `interpretation` block at the bottom of
`cpu-seconds.txt`, the note at the bottom of `gpu-evidence.txt`, and the
redaction in `device-info.txt`. They deliberately carry no run suffix, because
they are not reproducible output: a fresh run writes suffixed files and never
touches them.

`run-bench.sh` **stops llama-server first**. This is not optional: the server holds
~4.2 GiB of device memory, and leaving it running while starting a second
`-ngl 99` process is a reliable way to run the phone out of memory. (We know
because we did it.)

## Caveats we are aware of

- **n = 2 runs.** Enough to show the GPU pp64 figure is stable and that the tg
  direction is consistent; not enough for tight confidence intervals.
- **The device is noisy.** Load average sat around 21–23 throughout, from
  processes outside Termux that we cannot see (non-root `ps` shows only our own
  UID). Absolute timings will differ on a quiet device.
- **Thermal state was not controlled or measured.** Runs were minutes apart, not
  hours.
- **`uma: 1`** — this is unified memory. The "8428 MiB free" figure for the GPU
  moves with system memory pressure; we saw it range from 3850 MiB to 6391 MiB
  across the session. `-ngl 99` succeeding depends on how much the rest of the
  system is holding at that moment.
