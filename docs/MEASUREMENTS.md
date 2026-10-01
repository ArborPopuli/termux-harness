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

The same command, in three independent sessions. All three are shown because the
spread between them is itself informative — and because two of the four numbers
here do not replicate tightly.

**Run 1** (`bench/raw/llama-bench-run1.txt`, 2026-09-30)

| ngl | test | t/s |
|---|---|---|
| 0 | pp64 | 37.10 ± 0.48 |
| 0 | tg32 | 9.86 ± 1.07 |
| 99 | pp64 | **45.76 ± 0.02** |
| 99 | tg32 | **9.31 ± 0.12** |

**Run 2** (`bench/raw/llama-bench-run2.txt`, 2026-10-01T00:15)

| ngl | test | t/s |
|---|---|---|
| 0 | pp64 | 36.34 ± 0.70 |
| 0 | tg32 | 12.00 ± 0.79 |
| 99 | pp64 | **45.77 ± 0.02** |
| 99 | tg32 | **10.46 ± 0.08** |

**Run 3** (`bench/raw/llama-bench-run3.txt`, 2026-10-01T01:21, about an hour after run 2)

| ngl | test | t/s |
|---|---|---|
| 0 | pp64 | 37.40 ± 0.60 |
| 0 | tg32 | 12.26 ± 0.74 |
| 99 | pp64 | **45.74 ± 0.05** |
| 99 | tg32 | **10.45 ± 0.02** |

### What replicates, and what doesn't

| quantity | run 1 | run 2 | run 3 | verdict |
|---|---|---|---|---|
| GPU pp64 | 45.76 ± 0.02 | 45.77 ± 0.02 | 45.74 ± 0.05 | **0.03 t/s across three runs** |
| CPU pp64 | 37.10 ± 0.48 | 36.34 ± 0.70 | 37.40 ± 0.60 | reproduces (~3%) |
| GPU tg32 | 9.31 ± 0.12 | 10.46 ± 0.08 | 10.45 ± 0.02 | varies ~12% |
| CPU tg32 | 9.86 ± 1.07 | 12.00 ± 0.79 | 12.26 ± 0.74 | **varies ~24%** |

The GPU prompt-processing number is the most stable measurement on this device.
Three independent runs span **45.74 – 45.77 t/s**, a total spread of **0.03**,
against a per-run standard deviation of ±0.02–0.05. Run 3 was taken about an hour
after run 2, on the same device in the same state; that it lands within 0.03 t/s of
a run from the previous day is the useful part. The +22–26% gap over CPU prompt
processing is therefore unambiguous.

Token generation replicates in *direction* but not in *magnitude*:

| | run 1 | run 2 | run 3 |
|---|---|---|---|
| GPU tg32 vs CPU tg32 | **−6%** | **−13%** | **−15%** |

All three agree that **GPU token generation is not faster than CPU**. But the
figure "−6%" that the README's summary table carries is run 1 specifically, and
run 1 has the lowest CPU tg32 of the three (9.86, against 12.00 and 12.26). Run 3
is also a same-session repeat of run 2, so it is not an independent confirmation of
run 2's 12.00 in the way run 1 is.

Quote the range, or quote the direction. Not the single figure.

> ⚠️ If you take one thing from this page: **do not quote a single `llama-cli`
> run from this device.** We did exactly that and got a figure that was wrong by
> an order of magnitude. See [`CORRECTIONS.md`](CORRECTIONS.md).

## 2. CPU time — the metric that actually matters on a phone

`bench/raw/cpu-seconds.txt`. Sampling `utime+stime` from `/proc/<pid>/stat`:

| run | `-ngl 99` | `-ngl 0` | ratio |
|---|---|---|---|
| 1 | **5 CPU-s** (wall 10 s) | **33 CPU-s** (wall 13 s) | 6.6× |
| 2 | **4 CPU-s** (wall 8 s) | **35 CPU-s** (wall 13 s) | 8.8× |
| 3 | **5 CPU-s** (wall 9 s) | **37 CPU-s** (wall 19 s) | 7.4× |

Same 96-token generation. All three runs agree: the GPU run finishes *sooner*
while consuming **roughly one seventh of the CPU**. The 4–5 CPU-seconds on the GPU
side is the more stable half of the measurement; the 33–37 on the CPU side is the
one that moves, exactly as the throughput table above would predict.

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

Four things we could measure. Two of them — (b) and (d) — are impossible if the GPU
is *not* being used, and those are the two the claim rests on. (a) is weaker than it
looks, and (c) turned out not to discriminate at all; both say so below.

**(a) Only the real GPU is enumerated as a compute device.**
The system ships two Vulkan ICDs — `freedreno_icd` (Adreno) and `lvp_icd`
(lavapipe, a **CPU software rasteriser**). If ggml picked lavapipe, "Vulkan works"
would be true and "GPU is used" would be false. It doesn't:

```
$ llama-cli --list-devices
Available devices:
  Vulkan0: Adreno (TM) 830 (8428 MiB, 5682 MiB free)
```

This rules out the lavapipe false success — "Vulkan works" while nothing runs on the
GPU — but it is weaker than the other two: `--list-devices` takes no `-ngl` and
prints the same thing either way, so it shows which device is *available*, not that
work is being placed on it.

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

Unlike (c), this changes with `-ngl`, and that is what makes it evidence: the same
command at `-ngl 0` says `offloaded 0/29 layers`, with 4.46 GiB of weights in
`Vulkan_Host` instead of `Vulkan0`.

**(c) The Vulkan backend is initialised and the device is open** (`bench/raw/proc-evidence.log`):

```
fd_kgsl_open=1        # /dev/kgsl-3d0 is open in llama-cli's fd table
maps_freedreno=3      # libvulkan_freedreno.so is mapped
maps_libvulkan=9
```

**This one does not discriminate, and we used to claim it did.** A `-ngl 0` run
reports the same three numbers. `-ngl 0` does not switch the Vulkan backend off — it
only stops layers being placed on the device, and the weights then land in a
host-side Vulkan buffer:

```
-ngl 0 :  load_tensors: offloaded 0/29 layers to GPU
          load_tensors: Vulkan_Host model buffer size = 4460.78 MiB
```

So an open device node means *the backend was initialised*, not that the matmuls ran
there. This is the same mistake as reading anything into `maps_lvp` — see
[`CORRECTIONS.md`](CORRECTIONS.md) §7. The evidence that the GPU is doing the work is
(b) and (d), both of which change with `-ngl`.

**(d) CPU time collapses** — section 2 above. 33 → 5 CPU-seconds is not
explainable by anything other than the work having moved somewhere else.

Note that `maps_lvp=3` also shows up: the Vulkan loader maps *every* installed ICD
during instance enumeration. That is the general form of the mistake in (c) — a
mapped library, or an open device node, records that the loader did its job, not
where any work went. It is also why (a) asks what is *enumerated as a compute
device* rather than what is loaded.

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

- **n = 3 runs.** Enough to show the GPU pp64 figure is stable to 0.03 t/s and
  that the tg direction is consistent; not enough for tight confidence intervals.
  Runs 2 and 3 were also taken about an hour apart in the same session rather than
  on separate days, so they are not fully independent of each other.
- **The device is noisy.** Load average sat around 21–23 throughout, from
  processes outside Termux that we cannot see (non-root `ps` shows only our own
  UID). Absolute timings will differ on a quiet device.
- **Thermal state was not controlled or measured.** Runs were minutes apart, not
  hours.
- **`uma: 1`** — this is unified memory. The "8428 MiB free" figure for the GPU
  moves with system memory pressure; we saw it range from 3850 MiB to 6391 MiB
  across the session. `-ngl 99` succeeding depends on how much the rest of the
  system is holding at that moment.
