# Termux / Android gotchas

Things that cost us hours. Each one is a real observation from this project, not a
recitation of documentation.

---

## 1. There is no `/bin/bash` and no `/usr/bin/env`

```
/bin/bash                MISSING
/usr/bin/env             MISSING
/bin/sh                  EXISTS
$PREFIX/bin/bash         EXISTS
```

A script starting with `#!/bin/bash` **cannot be executed** on Termux — only
`bash script.sh` works. `#!/usr/bin/env bash` fails too, because there is no
`/usr/bin/env`.

This is a common way for "works for me" scripts to silently fail on Android.

**Fix.** Use the real path, or patch it at install time:

```bash
#!/data/data/com.termux/files/usr/bin/bash
```

`install.sh` in this repo rewrites the shebang to `$PREFIX/bin/bash` so it stays
correct if your prefix differs.

---

## 2. `/tmp` is `noexec`

Putting a helper script in `/tmp` and running it gives:

```
bash: /tmp/helper.sh: Permission denied
```

The file is there and executable; the mount simply refuses to execute from it.

**Fix.** Use `$HOME`. Every scratch script in this project lives in `$HOME`.

---

## 3. CMake wants `glslc`, but you probably installed `glslang`

Configuring with `-DGGML_VULKAN=ON` fails with:

```
Could NOT find Vulkan (missing: glslc) (found version "1.4.364")
```

`glslang` provides `glslangValidator`; llama.cpp's Vulkan backend additionally
needs **`glslc`**, which ships in the **`shaderc`** package. `spirv-headers` is
also required (`find_package(SPIRV-Headers CONFIG REQUIRED)`).

**Fix.**

```sh
pkg install shaderc spirv-headers    # pulls spirv-tools too
```

---

## 4. Android battery optimisation will kill your background work

This is the one that hurt most. Symptom: you are running a long build or server
over SSH, the screen turns off, and then:

```
ssh: connect to host <phone> port 8022: Connection refused
```

The phone still answers `ping` and its ARP entry is intact — the **network is
fine, the Termux process is gone**. `Connection refused` is a TCP RST, meaning no
listener, not a busy machine.

It will look like an OOM kill. It is not. We chased the OOM theory for a while
(see `CORRECTIONS.md` §3).

**Fix.**

> Settings → Apps → Termux → Battery → **Unrestricted**

Also useful:

- keep the phone on a charger for long jobs
- `termux-wake-lock` to hold a partial wakelock while working
- expect that after this happens you must reopen Termux and re-run `sshd`;
  Termux does not auto-start it unless you have Termux:Boot configured

---

## 5. `llama-cli` hangs forever if stdin is a terminal

Run `llama-cli -p "hi" -n 1 > log.txt` from an interactive shell and it will sit
at the `>` prompt **forever**. It is not slow — it is waiting for input. A script
that does this will hang, and the log stays empty (see gotcha 6).

**Fix.** Redirect stdin from `/dev/null`:

```sh
llama-cli -m "$MODEL" -p "hi" -ngl 99 -n 1 -v </dev/null > log.txt 2>&1
```

---

## 6. `llama-cli` writes its UI to the terminal, not to your redirect

With a tty present, output may go to the terminal even when you redirected stdout
to a file. You then see an empty log and conclude the model never loaded.

**Fix.** Combine `</dev/null` (gotcha 5) with redirection, and when in doubt check
the tmux pane — `tmux capture-pane -p -t <session>:<window> -S -50`.

---

## 7. Your own command line matches your own search pattern

`pgrep`/`grep`/`pkill` operate on argv, and the shell running your check has the
pattern in *its* argv:

```sh
pgrep -lf "cmake|clang"          # matches the bash -c running this command
pkill -9 -f "run-bench.sh"       # kills your own SSH session mid-command
```

The last one disconnected us.

**Fix.** Match a field that cannot contain the pattern, or break the literal:

```sh
ps -A -o comm= | grep -cE '^(cc1plus|clang|glslc)$'   # comm never holds the pattern
pgrep -f "cla[n]g"                                     # character class can't self-match
```

---

## 8. GPU utilisation counters are root-only

Every kgsl / devfreq / gpu node is unreadable from Termux:

```
/sys/class/kgsl/kgsl-3d0/gpubusy      → Permission denied
/sys/class/devfreq/                    → Permission denied
```

There is no `dumpsys`. `top` reports CPU only, never GPU.

**Workaround.** `/dev/kgsl-3d0` is world-readable/writable (`crw-rw-rw-`), and
`/proc/<your-pid>/` is readable for your own processes. That gives you:

```sh
ls -l /proc/<pid>/fd   | grep -c kgsl         # is the GPU device node open?
grep -c freedreno /proc/<pid>/maps            # is the real driver mapped?
grep -c lvp       /proc/<pid>/maps            # is the software rasteriser mapped?
```

See `docs/MEASUREMENTS.md` §4 for why this is *better* evidence than a percentage.

---

## 9. Two Vulkan ICDs ship by default — one of them is not a GPU

```
$PREFIX/share/vulkan/icd.d/freedreno_icd.aarch64.json   ← Adreno (real GPU)
$PREFIX/share/vulkan/icd.d/lvp_icd.aarch64.json         ← lavapipe (CPU software rasteriser)
```

If a build selects lavapipe you get a convincing false success: Vulkan
initialises, the logs look right, and **not a single FLOP runs on the GPU**.
Both ICDs get mapped into the process during enumeration, so "I see the lvp
library loaded" proves nothing either way.

**Fix.** Always check what is actually enumerated as a compute device:

```sh
llama-cli --list-devices
# Available devices:
#   Vulkan0: Adreno (TM) 830 (8428 MiB, 3850 MiB free)
```

If that list shows more than one device, or shows something like `llvmpipe` /
`lavapipe`, stop and fix the selection before measuring anything.

---

## 10. Unified memory means "free VRAM" is a moving target

The GPU reports `uma: 1` — it shares system RAM. The "free" figure inside
`Adreno (TM) 830 (8428 MiB, NNNN MiB free)` tracks **overall system memory
pressure**.

We watched it range from **3850 MiB to 6391 MiB** during one session. `-ngl 99`
needs ~4.2 GiB for a 7B Q4_K_M model, so whether full offload succeeds depends on
what the rest of the phone is doing at that moment — it is not a fixed property
of the device.

**Consequences:**
- Don't start a second `-ngl 99` process while a server is already holding device
  memory. We did, and it killed the phone.
- A launcher should degrade gracefully rather than assume full offload works:
  `start-llama-server.sh` tries `-ngl 99 → 30 → 0`.
