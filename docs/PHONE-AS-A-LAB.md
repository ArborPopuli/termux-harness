# Using a phone as a headless lab

Everything in this repository was produced by driving an Android phone over SSH
from a laptop. This page is how that was set up, including the parts that cost
time. It assumes Termux is installed and nothing else.

The short version: an Android phone is a real Linux box with a GPU, a battery, and
no root. That is enough to be useful, and the constraints are specific enough to
be worth writing down.

---

## 1. Turning on SSH

```sh
pkg install openssh
sshd
```

That is the whole server. It listens on **port 8022**, not 22 — Termux cannot bind
a privileged port without root, and 8022 is the convention.

Check it:

```sh
whoami                    # e.g. u0_a309 — your Termux user
ifconfig 2>/dev/null | grep 'inet '    # or: ip addr
```

You want the phone's LAN address. Note that **`u0_a309` is your Termux username,
and it is derived from the Android UID assigned to your Termux install** — so it
is stable for that install and identifies it. Do not publish it alongside device
details; it is a fingerprint, not a name. (This repository shipped it once by
accident, in a captured `ls -l` line. See `CORRECTIONS.md` §7 for a different
mistake made in the same file.)

## 2. Keys, so you stop typing passwords

On the laptop:

```sh
ssh-keygen -t ed25519 -f ~/.phone-key -C phone-lab
ssh-copy-id -i ~/.phone-key.pub -p 8022 u0_a309@PHONE_IP
```

Or by hand — Termux has no `ssh-copy-id`:

```sh
cat ~/.phone-key.pub | ssh -p 8022 u0_a309@PHONE_IP \
  'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
```

Then, from the laptop:

```sh
ssh -i ~/.phone-key -o BatchMode=yes -p 8022 u0_a309@PHONE_IP 'uptime'
```

`BatchMode=yes` is worth including: it makes the client fail instead of silently
waiting for a password prompt, so a broken key surfaces immediately instead of
hanging a script.

## 3. Keeping it alive — the one that matters

**This is the failure mode that will waste your evening.** Symptom: you are
running something long over SSH, the screen turns off, and:

```
ssh: connect to host <phone> port 8022: Connection refused
```

The phone still answers `ping` and its ARP entry is intact. `Connection refused`
is a TCP RST — no listener — not a timeout. **The network is fine; the Termux
process is gone.**

It looks exactly like an out-of-memory kill. It is not. Android's battery
optimisation reaped Termux because the screen went off.

Fix, in this order:

1. **Settings → Apps → Termux → Battery → Unrestricted.** Without this nothing
   else helps.
2. `termux-wake-lock` before long jobs, `termux-wake-unlock` after. This ships
   with the Termux app, not with the `termux-api` package, so a bare install has
   it.
3. Keep the phone on a charger for anything long.
4. After it happens you must **reopen Termux and re-run `sshd`**. It does not
   start itself unless you have Termux:Boot configured.

`agent.sh` in this repository takes the wake lock automatically around every
command it runs, and releases it afterwards.

## 4. The shell is not the shell you expect

Termux is not a normal Linux userland. The differences that bite:

| | |
|---|---|
| No `/bin/bash`, no `/usr/bin/env` | `#!/bin/bash` scripts **cannot be executed**. Only `bash script.sh` works. Use `#!/data/data/com.termux/files/usr/bin/bash` |
| `$PREFIX/tmp` is `noexec` | and on the test device not writable at all. Put scratch files under `$HOME` |
| No `sudo`, no root | every `/proc` and `/sys` path that needs it is simply unreadable |
| `pkg` not `apt` | `pkg install …` |

### The SSH exit code trap

**An SSH client exits with the remote command's exit status.** So:

```sh
ssh phone 'tmux ls'        # exits 1 if no server is running — looks like a failed connection
ssh phone 'grep foo file'  # exits 1 on no match
```

A retry loop around SSH will read those as transport failures and retry a command
that succeeded. End remote commands with `; true` or `echo DONE` when you mean
"the connection worked".

## 5. What you can and cannot read without root

This matters more than it sounds, because the interesting numbers are the ones
nobody usually looks at. Measured on an SM8750 device:

**Readable:**

```sh
/sys/class/thermal/thermal_zone*/type,temp    # named sensors: cpu-*, battery, shell_*, charger
/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq
/proc/<your-own-pid>/status, fd/, maps/       # your own processes only
```

That is enough to see temperature and whether the CPU is throttling or ramping.
`device.sh` in this repository is built on exactly these.

**Not readable, no root:**

```sh
/proc/stat          /proc/loadavg        # surprising but true; `uptime` works via a syscall
/sys/class/power_supply/*                # battery percentage
/sys/kernel/debug/kgsl/...               # GPU utilisation — see docs/MEASUREMENTS.md §4
/proc/gpuinfo
```

`ps -A` shows **only your own UID's processes**. "Five processes" means five
Termux processes, not a quiet machine. On the test device the load average sat
around 21 the whole time from processes outside Termux's view.

Read the zone *names*, not the indices — `thermal_zone8` on one device is
`cpu-0-2-1` on another is `cpu-therm` on a third. Match on the type string.

## 6. `termux-api` is a separate package

`termux-notification`, `termux-battery-status`, `termux-tts-speak`,
`termux-clipboard-get` and friends need **both** the `termux-api` package *and*
the Termux:API app installed. Most devices do not have them. `termux-wake-lock`
and `termux-open` are in the base app and usually do.

Anything you write should work without `termux-api` and light up if it appears.
`device.sh` guards every such call with `command -v`.

## 7. Moving files

Streamed, both directions. A phone has less free memory than you think, and a
multi-gigabyte tarball on disk is a good way to find out:

```sh
# laptop pulls
ssh -i ~/.phone-key -p 8022 u0_a309@PHONE_IP 'cd ~/proj && tar cz data' \
  | tar xz -C ~/backup/

# laptop pushes
tar czf - -C ~/proj --exclude=.git . \
  | ssh -i ~/.phone-key -p 8022 u0_a309@PHONE_IP 'tar xzf - -C ~/proj'
```

Two things go wrong here, both worth knowing:

- **macOS `tar` writes `._*` AppleDouble files** into the archive. Use
  `COPYFILE_DISABLE=1 tar czf - …` or delete them after.
- **`tar` preserves the source's permission bits.** Pushing from a checkout where
  the scripts are mode 600 will silently remove the exec bit on the phone, and
  anything guarded by `[ -x … ]` stops running. In this repository that cost a
  phone reboot: `bench/run-bench.sh` skipped its "stop the server first" step and
  the next `-ngl 99` run ran the device out of memory. `chmod +x` after any push,
  or check `tests/guards.sh` section 2.

## 8. Confirming a transfer actually happened

Compare a manifest hash on both ends. It is one line and it catches truncation
that a file count will not:

```sh
ssh phone 'cd ~/proj && find . -type f | LC_ALL=C sort | xargs sha256sum | sha256sum'
(cd ~/backup && find . -type f | LC_ALL=C sort | xargs shasum -a 256 | sha256sum)
```

**Watch your shell.** In zsh, unquoted `$FILES` is **not** word-split, so
`find $FILES -type f` becomes a single bogus path and both sides hash nothing —
producing two identical hashes of the *empty string*
(`e3b0c44298fc1c14…`). Two matching hashes are not a passing test if neither side
looked at anything.
