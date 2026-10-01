# harness-bench

A 30-task ruler for the harness itself.

`bench/run-bench.sh` (one directory up) measures the *server*: tokens per second and
CPU-seconds under `-ngl 0` and `-ngl 99`. It does not measure whether the model
produces a **correct command**. Those are different questions, and a model can win
the first one while failing the second.

This directory measures the second one.

---

## What this measures

For each task, the bench sends the harness's **own** `SYSTEM_PROMPT` — extracted from
`agent.sh` at runtime, never copied — plus one Chinese request. The model replies with
an explanation and a `[CMD]` line. The bench extracts the command, runs it against a
fixture tree, and hands the command's **stdout** to a checker.

Two numbers come out of each task, and they are reported separately:

| column | what it is |
|---|---|
| `result` | `PASS` / `FAIL` — the checker in `tasks.tsv`, evaluated against stdout |
| `wall_s` | request sent → command finished |
| `cpu_s` | the **server process's** `utime+stime` delta across the request |

`cpu_s` is the one this project actually cares about. On a phone the scarce resource
is not FLOPs, it is the ability to coexist with the foreground, and that is paid in
CPU-seconds, not tokens. A model that is slower but cheaper can still be the right
choice — so the two numbers are read together, never averaged into one score.

The score is **not** a general capability score. It is "can this model drive *this*
harness on *these* tasks". That is the only claim being made.

---

## How it works

```
tasks.tsv        id, category, request, checker        (30 rows)
refs.tsv         id, a known-correct command           (30 rows)
setup-fixtures.sh  builds the fixture tree under $LAB, reset before every task
run-bench.sh     drives the model, runs commands, scores them
validate-checkers.sh  runs refs.tsv through the checkers; all 30 must pass
```

`$LAB` defaults to `/storage/emulated/0/bench-lab`. Fixtures are **reset before every
task** — an earlier version shared one tree across all tasks, so a task that renamed
files broke every task after it.

## Running it

```sh
# score a server the bench starts and stops itself
bash run-bench.sh <label> <model.gguf> [ngl]

# score a server that is already up (leaves it alone when done)
RUNNING=1 PORT=8080 bash run-bench.sh <label> <model.gguf> 99
```

Results land in `results/<label>.tsv`. The script **refuses to overwrite** an existing
label — use a new one rather than clobbering published evidence.

---

## Are the checkers right?

This is the part that matters, because a broken checker is silent.

`refs.tsv` holds a known-correct command for every task. `validate-checkers.sh` runs
all 30 through their own checkers. **A checker that fails its own reference command is
a broken checker**, and the run stops.

```sh
bash validate-checkers.sh     # expect: 30/30, "判定器全部自洽"
```

### Three checkers were wrong, and they looked fine

The first full run scored 25/30. Three of those failures were the **checker's** fault,
not the model's:

| task | correct answer | what the checker counted |
|---|---|---|
| t08 | 8 lines | lines containing `empty` → 2 (only 2 of the 8 empty files have "empty" in the name) |
| t09 | 3 lines | lines containing lowercase `todo` → 2 (`mixed.txt` has uppercase `TODO`) |
| t12 | **26** | expected 25 — the number itself was wrong |

`tasks.tsv` had always said "expected values must be measured from the fixture". **A
discipline without an instrument is not a discipline** — 25/30 looked entirely
plausible and nobody would have gone looking. `refs.tsv` plus `validate-checkers.sh`
is the instrument.

The general lesson, stated once so it does not have to be relearned: **an indicator
that does not vary with the thing you are trying to detect is not evidence.** A checker
that counts the wrong substring does not vary with correctness. A "GPU is in use"
check that reads the same under `-ngl 0` and `-ngl 99` does not vary with offload
(see `docs/CORRECTIONS.md` §4). Both looked like measurements and were not.

---

## Results

| model | size | score | wall | CPU |
|---|---|---|---|---|
| Qwen2.5-Coder-7B Q4_K_M | 4.36 GiB | **29/30** | 10.0 s/task | 0.30 s/task |
| Qwen3-4B-Instruct-2507 Q4_K_M | 2.32 GiB | **24/30** | 5.8 s/task | 0.54 s/task |
| Nanbeige4.2-3B Q4_K_M | 1.9 GiB | *not measured — see below* | — | — |

Raw output: `results/qwen7b-base.tsv`, `results/qwen4b-base.tsv`.

### The 4B result, reported as it is

The smaller model is **faster in wall-clock (0.59×) and more expensive in
CPU-seconds (1.78×)** — and that inversion is consistent, not noise: 4B costs more
CPU on **27 of the 30 tasks**.

This is the opposite of what "smaller model, lower cost" would predict, and it is
**not explained**. Output length does not account for it: on `t01` both models
produced a 49-character command and the 4B still cost 32% more CPU. The mechanism is
an open question, not a finding.

It is worth stating plainly because it cuts against this repository's own framing.
"Moves the matmuls to the GPU, so the foreground keeps its CPU" is a claim about
**where** the work runs. It is not a claim that a smaller model is cheaper, and this
measurement is a reminder that the two are separate questions.

A controlled follow-up needs `-ngl 0` runs of both models on the same build; the 7B
weights are no longer on the device, so that has not been done.

### Why there is no 3B yardstick row

`results/` on the development device also holds a Nanbeige run, and it is not
published here because **two independent instrument faults stack in that single row**:

1. **It scores `noCMD` on all 30 tasks.** Nanbeige is a reasoning model, and
   `run-bench.sh` does not disable thinking. The token budget goes entirely into the
   reasoning block and `content` comes back empty — the bench sees no `[CMD]` line at
   all. The published reply text in that file is reasoning leakage. This is a
   limitation of the bench, not a property of the model: with thinking disabled the
   same model answers correctly in about a second.
2. **`cpu_s` is `0.00` on every row.** That run predates the PID fix below — the
   server's PID was never found, so the CPU counter read nothing.

The file is kept on the development device as evidence and is deliberately not
committed. **A number produced by a broken instrument is not a measurement**, and
the fix for (1) — sending `chat_template_kwargs: {"enable_thinking": false}` — has
not been applied to this bench yet.

---

## Corrections

### `cpu_s` silently read `0.00` for every task

**What we did.** Found the running server with `pgrep -x llama-server`, then sampled
`utime+stime` from `/proc/<pid>/stat`.

**What was true.** `pgrep -x llama-server` **returns nothing on this device** — the
process is plainly running and `pgrep` does not see it. The PID came back empty, the
`/proc` read failed, and every CPU-seconds value in the column was `0`. Nothing
errored; the column simply filled with zeros that looked like measurements.

**The fix.** Capture the PID at launch, where it is free and unambiguous:

```sh
nohup "$BIN/llama-server" ... &
SPID=$!          # not `pgrep -x llama-server`
```

For the `RUNNING=1` path, where the bench did not start the server, read the pidfile
and fall back to scanning `/proc/*/comm` — matching `comm` and **not** `cmdline`,
because a `cmdline` match also matches the scanning script's own command line.

**How it was caught.** By timestamp: the affected run started at 14:08:32, the fixed
run at 14:26:02. Eighteen minutes separate a column of zeros from a column of real
numbers, and nothing in the file itself says which is which.

### One result file accumulated several runs

`results/qwen7b-prod.tsv` on the development device contains rows from more than one
run appended together — the same task id appears three times, and the file ends with
`passed 27/32`. The refuse-to-overwrite guard was added **after** that file was
written. It is not published.

Checked-in results are one run per label, and the header records the label, model,
`ngl`, and start time so a file can be traced back to the run that produced it.

---

## Gotchas

**`pgrep -x llama-server` does not work here.** See the correction above.

**Match `comm`, never `cmdline`.** A `cmdline` pattern matches the scanning script's
own command line. This has killed a shell four times in this project; see
`docs/TERMUX-GOTCHAS.md`.

**`/proc/<pid>/stat` field 2 is parenthesised and may contain spaces,** which shifts
the column positions. `awk '{print $14+$15}'` is correct for `llama-cli` and
`llama-server`, whose names have no spaces — but if you retarget this at a process
whose name does, read the whole tail after the closing paren first.

**Do not run two `-ngl 99` servers at once.** They share device memory with the
system; the second one OOMs and takes Termux with it, which needs a human to restart
the app. Check `free -m` before starting and stop the server when done.
