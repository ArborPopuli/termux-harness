# Corrections

Every claim in this file is one we made **confidently, and got wrong**, during the
work that produced this repository. They are kept because the failure mode is
more instructive than the fix — and because a project that publishes only its
successful measurements is not publishing measurements.

---

## 1. "GPU offload is 10.2× faster than CPU" — **wrong**

**What we said.** After the first successful `-ngl 99` run we reported
`Prompt: 28.2 t/s | Generation: 10.2 t/s`, compared it against an earlier CPU run
at `Generation: 1.0 t/s`, and announced a 10× speedup.

**What was true.** A controlled `llama-bench -ngl 0,99 -r 3` gave:

| | CPU | GPU | delta |
|---|---|---|---|
| pp64 | 37.10 ± 0.48 | 45.76 ± 0.02 | **+23%** |
| tg32 | 9.86 ± 1.07 | 9.31 ± 0.12 | **−6%** |

Generation was **slightly slower** on the GPU, not 10× faster.

**Why the reasoning failed.** The `1.0 t/s` baseline was a single sample — the
first CPU run after the model had just been loaded, taken while the device was
under load. Repeating the *same configuration* minutes later produced
9.86–12.7 t/s. **A 12× spread between two runs of an identical configuration.**

The error was not arithmetic. It was treating one observation as a measurement.

**The fix.** Never compare single samples on this device. `llama-bench` with
`-r 3` (warm-up + repetitions + standard deviation) is the minimum bar, and the
direction of an effect must replicate across independent runs before it is quoted.

---

## 2. "The build died / stalled" — **wrong**

**What we said.** A monitor watching the build reported
`NO COMPILER PROCESSES for 3 polls and build.done absent -> build died or stalled`.

**What was true.** The build had finished cleanly at 23:49 —
`[100%] Built target llama-app`, and every expected artifact was present on disk.

**Why the reasoning failed.** The monitor keyed off `~/build.done`, a flag file
that **only our own wrapper script created**. The build had been started by hand
from a terminal, so the flag never appeared; "flag absent" was read as "build
failed". The instrument was measuring our own bookkeeping, not the build.

**A second layer to this one.** We initially defended the finding with "the log
file's mtime is frozen, so the process is dead". But the log was written with
`>>`, which is **block-buffered** when stdout is not a terminal — a frozen mtime
is fully compatible with a healthy running process. We had a wrong conclusion
supported by a wrong inference about a second instrument.

**The fix.** Check the object you actually care about (`ps` for the process, the
artifact on disk), not a proxy you introduced yourself.

---

## 3. "The SSH daemon keeps dying from OOM" — **wrong**

**What we said.** After `sshd` vanished twice on the phone, we produced a
confident causal story: `-j8` compilation exhausted memory, Android's low-memory
killer reaped the Termux process group, and the daemon went with it. We wrote it
into an incident report as the leading hypothesis with supporting evidence
(memory headroom logged at build start, load average ~22).

**What was true.** **Android battery optimisation was killing Termux** when the
screen was off. The user confirmed this after plugging the phone in and changing
the setting.

**Why the reasoning failed.** We had correlation (build running, daemon died) and
a plausible mechanism, and we presented the mechanism as the conclusion. We never
tested it — and it was testable: the user changed one setting and the symptom
stopped.

**The fix.** A hypothesis with a plausible mechanism is still a hypothesis.
Label it. In our own incident document the section was headed "假设（未验证）",
which was correct — the failure was repeating the hypothesis downstream as
established fact.

**Operational note for anyone running long jobs in Termux:**
> Settings → Apps → Termux → Battery → **Unrestricted**. Without this, Android
> will kill your background work when the screen turns off.

---

## 4. "The backgrounded run produced no output" — **wrong**

**What we said.** A wrapper script launched `llama-cli` and redirected its output
to a log. The log came back containing only the script's own headers. We
concluded the model had never loaded — the process used only 573 MB RSS and
exited in 13 s.

**What was true.** It worked perfectly. The full output — including the correct
reply and `Generation: 9.9 t/s` — was sitting in the **tmux pane**.

**Why the reasoning failed.** `llama-cli` writes its interactive UI to the
terminal. With a tty available it did not write to our redirected file. We
checked one channel, found it empty, and drew a conclusion about the process.

Incidentally the 573 MB RSS was also correct and unsurprising: the 4.1 GiB of
weights are in a **device-local buffer**, which does not appear in the process's
RSS. Two correct observations, one wrong conclusion.

**The fix.** When a process has multiple output channels, absence of output on one
of them is not absence of output. `</dev/null` on stdin (to stop the interactive
prompt) plus capturing the pane is the reliable combination.

---

## 5. Recurring: patterns that match their own command line

Three separate times, a check matched **the shell running the check**:

| Command | What it actually matched | Consequence |
|---|---|---|
| `pgrep -lf "cmake\|clang\|make"` | the `bash -c` running the pgrep | reported "2 compilers alive" when there were none |
| `grep -c "clang\|cmake"` over `ps` output | the `grep` process itself | false positive on process-liveness checks |
| `pkill -9 -f "run-bench.sh"` | **the SSH session executing the pkill** | killed our own connection mid-command |

The third one cost a reconnect. All three have the same shape: the search pattern
is present in the searcher's own argv.

**The fix.** Match on a field that cannot contain the pattern (`ps -o comm=`), or
break the literal with a character class (`cla[n]g`).

---

## 6. We crashed the phone ourselves

While capturing GPU evidence we left `llama-server` running (holding ~4.2 GiB of
device memory) and started a second `-ngl 99` process. Memory ran out and Termux
was killed, taking SSH with it.

Our own `bench/run-bench.sh` already stopped the server first. We had written the
correct procedure and then not followed it in an ad-hoc command.

It is now documented in [`MEASUREMENTS.md`](MEASUREMENTS.md) and enforced in the bench script,
because "remember to stop the server" is not a control.

---

## 7. "The open GPU device node proves the GPU is being used" — **wrong**

**What we said.** `MEASUREMENTS.md` §4 offered four things we *could* measure, as
"stronger than a utilisation reading, because each one is impossible if the GPU is
*not* being used". The third was that the process holds the Adreno device node open
and has the freedreno driver mapped:

```
fd_kgsl_open=1        # /dev/kgsl-3d0 is open in llama-cli's fd table
maps_freedreno=3      # libvulkan_freedreno.so is mapped
```

with the reason given as: *"`/dev/kgsl-3d0` is the Qualcomm GPU driver node. Nothing
on a CPU-only path opens it."*

**What was true.** A `-ngl 0` run — CPU only, nothing offloaded — reports exactly the
same numbers. Three independent runs of each configuration:

| | `fd_kgsl_open` | `maps_freedreno` |
|---|---|---|
| `-ngl 0` | 1 | 3 |
| `-ngl 99` | 1 | 3 |
| `-ngl 0` | 1 | 3 |

The indicator distinguishes nothing.

**Why the reasoning failed.** `-ngl 0` does not switch the Vulkan backend off. It
stops *layers being placed on the device*; llama.cpp still initialises Vulkan and
allocates the weights in a host-side Vulkan buffer:

```
-ngl 0 :  load_tensors: offloaded 0/29 layers to GPU
          load_tensors: Vulkan_Host model buffer size = 4460.78 MiB
```

So an open device node and a mapped driver mean *the Vulkan backend was
initialised*. They say nothing about where the matmuls ran.

**The document already contained the correct reasoning, and did not apply it here.**
§4 dismisses `maps_lvp=3` in one sentence:

> the Vulkan loader maps *every* installed ICD during instance enumeration. Its
> presence is expected and proves nothing by itself.

That sentence is true verbatim with `freedreno` or `kgsl` substituted for `lvp`. We
wrote the rule and then broke it two paragraphs later.

**The fix.** The claim that the GPU is doing the work now rests only on evidence
that actually varies with `-ngl`:

- the `load_tensors` line — `offloaded 0/29` at `-ngl 0`, `offloaded 29/29` at
  `-ngl 99`, with `Vulkan0 model buffer size = 4168.09 MiB` in the latter
- the CPU-time collapse in §2 — 33 → 5 CPU-seconds

Both are discriminating and neither was wrong, so **the conclusion does not move**:
the GPU is being used. What moves is that one of the four arguments for it was not
an argument. §4(c) now says what it actually shows.

Found on 2026-10-01 while hardening `bench/run-bench.sh`, by running the negative
control the earlier work had skipped — the same `-ngl 0` baseline used everywhere
else, applied to an indicator nobody had thought to check against it.

---

## Meta

The pattern across corrections 1–4 is the same, and it is not about LLMs or
Android:

> **We trusted an instrument we had not validated, because its output was
> numerically precise.**

`1.0 t/s` looks like a measurement. `build.done absent` looks like a fact.
`load average 23` looks like evidence. `0 bytes in the log` looks like a result.
Each was precise and each was wrong, and in every case a **negative control** —
does this probe report failure on a known-good input? — would have caught it.

The device amplifies this: a single sample on this phone can be off by an order
of magnitude, the "free GPU memory" figure moves with unrelated system pressure,
and the most interesting counters are behind SELinux. On hardware like this,
**measurement discipline is not rigour theatre — it is the only thing standing
between you and a confident, wrong answer.**
