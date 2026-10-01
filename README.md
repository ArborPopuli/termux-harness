# termux-harness

**A measured report on llama.cpp's Vulkan GPU offload on Android — plus a
drop-in local agent harness for Termux.**

[中文说明](README.zh-CN.md) · [Measurements](docs/MEASUREMENTS.md) ·
[Corrections](docs/CORRECTIONS.md) · [Termux gotchas](docs/TERMUX-GOTCHAS.md)

---

## The short version

We offloaded **Qwen2.5-Coder-7B Q4_K_M** entirely onto an **Adreno 830** through
llama.cpp's Vulkan backend, on a phone, under Termux. Then we measured it properly.

| | CPU (`-ngl 0`) | GPU (`-ngl 99`) | delta |
|---|---|---|---|
| prompt processing (pp64) | 37.10 ± 0.48 t/s | **45.76 ± 0.02 t/s** | **+23%** |
| token generation (tg32) | 9.86 ± 1.07 t/s | **9.31 ± 0.12 t/s** | **−6%** |
| **CPU time, 96 tokens** | **33 CPU-s** | **5 CPU-s** | **6.6× less** |

`llama-bench -r 3`, run three times ([raw output](bench/raw/)). The numbers in the
table above are **run 1**; across all three, GPU prompt processing lands at
**45.74 – 45.77 t/s — a 0.03 t/s spread** — while the GPU generation penalty moves
between **6% and 15%** and the CPU-time ratio ranges **6.6× to 8.8×**. The
*direction* is the same in every run. The individual figures are not, so read the
ranges from [MEASUREMENTS.md](docs/MEASUREMENTS.md) before quoting one.

**Token generation gets slower on the GPU.** Prompt processing gets faster.
Neither is the point.

The point is the last row: **the CPU gets its cycles back.** On a phone the scarce
resource isn't FLOPs — it's the ability to coexist with the foreground. Thermal
headroom, battery, a UI that still responds. Moving the matmuls onto the GPU buys
that. It does not buy tokens/sec, and we're not going to pretend it does.

### Why generation doesn't speed up

```
ggml_vulkan: 0 = Adreno (TM) 830 (turnip Mesa driver) | uma: 1 | fp16: 1 | bf16: 0
              | fp4: 0 | warp size: 64 | shared memory: 32768
              | int dot: 0 | matrix cores: none
```

`matrix cores: none`, `int dot: 0`. The open-source **Turnip** driver does not
expose the Adreno's matrix/tensor units or integer dot-product instructions to the
application, so ggml cannot take the cooperative-matrix path and falls back to
scalar shaders. Token generation is bandwidth-bound anyway, and this CPU has
`i8mm` + `dotprod` to work with.

This is not a build mistake or a misconfigured backend. **It's the current ceiling
of the open-source stack on this hardware.** If your Turnip exposes `matrix cores`,
expect materially better numbers from the same configuration.

---

## What's in the box

| | |
|---|---|
| `agent.sh` | A small agent loop: natural language → `[CMD]…[/CMD]` → confirm → run |
| `start-llama-server.sh` | Brings up `llama-server` with an offload ladder (`99 → 30 → 0`) that degrades automatically on allocation failure |
| `install.sh` | Idempotent install; fixes shebangs for your `$PREFIX`; wires up `~/.agent/` |
| `bench/run-bench.sh` | Reproduces **every number in this README**, writes `bench/raw/*-<label>.txt` |
| `tests/integration.sh` | End-to-end self-test (health, completions, harness, plugins) |
| `docs/` | Measurements, corrections, and the Termux/Android gotchas that cost us hours |

No Ollama. No `jq` (not installed on the target — JSON is handled with `python3`).
Only `curl`, `python3`, `bash`, `git`.

---

## Requirements

- Termux on Android, with `git curl python3`
  ```sh
  pkg install git curl python3
  ```
- llama.cpp built **with the Vulkan backend**:
  ```sh
  pkg install shaderc spirv-headers        # glslc lives in shaderc, NOT glslang
  cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
  cmake --build build -j2
  ```
  > `-j8` on a memory-constrained phone is a good way to get your build killed.
- A GGUF model, e.g. `~/qwen2.5-coder-7b.gguf`

---

## Install

```sh
git clone <this repo> ~/termux-harness
cd ~/termux-harness
bash install.sh
```

## Use

```sh
# start the server (first run loads ~4.2 GiB of weights into device memory)
bash ~/termux-harness/start-llama-server.sh

# ask for a command
bash ~/termux-harness/agent.sh "find jpgs from the last 3 days in Download"
```

Manage the server:

```sh
bash start-llama-server.sh --status
bash start-llama-server.sh --stop
```

The server speaks the **OpenAI chat-completions API** on `127.0.0.1:8080`, so
anything that talks to OpenAI can be pointed at it. The harness is one client;
it doesn't have to be yours.

---

## What this is not

- **Not a speedup claim.** Read the table. Generation is slower.
- **Not a sandbox.** `agent.sh` executes the shell the model writes. A human
  confirms each command, and there is an ASCII check plus a dangerous-pattern
  blocklist — but that blocklist is string matching, not a security boundary.
  Only run it on a machine you're willing to hand to a language model.
  (The ASCII check exists to catch the model leaking prose into `[CMD]…[/CMD]`,
  but it also rejects legitimate CJK paths — and the default search root,
  `/storage/emulated/0/`, is full of them. Set `ALLOW_NON_ASCII=1` in
  `~/.agent/config.sh` if that is your situation.)
- **Not a new inference engine.** It's llama.cpp, wired up for a phone.
- **Not benchmark-grade science.** n = 3 runs, two of them an hour apart in the
  same session rather than on separate days, uncontrolled thermal state, and a
  device whose load average sat at ~21 from processes we can't see. See the
  caveats at the end of [MEASUREMENTS.md](docs/MEASUREMENTS.md).

---

## Two things worth reading even if you skip the code

**[docs/CORRECTIONS.md](docs/CORRECTIONS.md)** — claims we made confidently and
got wrong, including one where a single unvalidated sample told us "GPU is 10×
faster" and replication said otherwise. Kept because the failure mode is more
useful than the fix.

**[docs/TERMUX-GOTCHAS.md](docs/TERMUX-GOTCHAS.md)** — ten Android/Termux traps:
no `/bin/bash`, `/tmp` is `noexec`, `glslc` vs `glslang`, battery optimisation
killing your background jobs, two Vulkan ICDs where one is a CPU rasteriser, and
the `pkill` pattern that killed our own SSH session.

---

## Test device

| | |
|---|---|
| Device | HONOR **AAK-AN00** |
| SoC | Qualcomm **SM8750** (Snapdragon 8 Elite), 8 cores |
| GPU | **Adreno 830** via **Turnip** (Mesa) |
| OS | Android **16** (SDK 36), kernel 6.6.118-android15 |
| RAM | 11.2 GB + 12.3 GB swap |
| Model | Qwen2.5-Coder-7B **Q4_K_M** (4.36 GiB) |
| Build | llama.cpp `0.5.0-dev`, clang 21.1.8, Vulkan loader 1.4.364 |

---

## License

MIT — see [LICENSE](LICENSE).

## Contributing

The most useful thing you can send is a **counter-measurement**: a run on
different hardware, a different Turnip version, or a Turnip that exposes
`matrix cores`. If your numbers contradict ours, that's a result, not a conflict.
