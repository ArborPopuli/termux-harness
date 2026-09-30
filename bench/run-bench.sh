#!/data/data/com.termux/files/usr/bin/bash
# bench/run-bench.sh — reproduce every number quoted in the README.
#
# Usage:
#   bash bench/run-bench.sh [label] [--force]
#
#   [label]   Run tag. Every artifact is written as <name>-<label>.<ext> under
#             bench/raw/, so a fresh run never overwrites published evidence.
#             The README cites bench/raw/llama-bench-run1.txt and
#             llama-bench-run2.txt, i.e. `run-bench.sh run1` and `run-bench.sh
#             run2`. Defaults to a UTC timestamp.
#   [--force] Permit overwriting artifacts that already exist. Without it the
#             script stops before doing any work, rather than clobbering a run
#             that is already committed.
#
# Stops llama-server first: it holds ~4.2 GiB of device memory, which would
# skew (or break) the -ngl 99 measurements. Restarts it at the end.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW="$HERE/raw"
mkdir -p "$RAW"

RUN=""
FORCE=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    -*)      echo "unknown option: $a" >&2; exit 2 ;;
    *)       if [ -z "$RUN" ]; then RUN="$a"
             else echo "usage: run-bench.sh [label] [--force]" >&2; exit 2; fi ;;
  esac
done
[ -n "$RUN" ] || RUN="run$(date -u +%Y%m%d-%H%M%S)"

LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
MODEL="${MODEL:-$HOME/qwen2.5-coder-7b.gguf}"
LAUNCHER="${LAUNCHER:-$HOME/termux-harness/start-llama-server.sh}"
BIN="$LLAMA_DIR/build/bin"
export LD_LIBRARY_PATH="$BIN:${LD_LIBRARY_PATH:-}"

DEVICE="$RAW/device-info-$RUN.txt"
BENCH="$RAW/llama-bench-$RUN.txt"
GPU="$RAW/gpu-evidence-$RUN.txt"
CPUSEC="$RAW/cpu-seconds-$RUN.txt"
VERBOSE="$RAW/llama-cli-verbose-$RUN.txt"

if [ "$FORCE" -ne 1 ]; then
  for f in "$DEVICE" "$BENCH" "$GPU" "$CPUSEC" "$VERBOSE"; do
    if [ -e "$f" ]; then
      echo "refusing to overwrite $f" >&2
      echo "  (re-run with --force if that is what you want)" >&2
      exit 3
    fi
  done
fi

echo "collecting $(date -Iseconds)"
echo "   run label : $RUN"
echo "   llama.cpp : $LLAMA_DIR"
echo "   model     : $MODEL"
echo "   output    : $RAW"

# ---------- 1. Environment snapshot ------------------------------------------
{
  echo "=== collected: $(date -Iseconds) ==="
  echo
  echo "--- device properties (getprop) ---"
  for p in ro.product.model ro.product.brand ro.product.manufacturer \
           ro.board.platform ro.soc.model ro.soc.manufacturer \
           ro.build.version.release ro.build.version.sdk ro.hardware; do
    printf '%-28s = ' "$p"; getprop "$p" 2>/dev/null || echo '(denied)'
  done
  echo
  echo "--- kernel ---"
  # Do NOT use `uname -a` here. It embeds the vendor build string, e.g.
  #   6.6.118-android15-8-gf17133276a57-abogki518694926-4k #1 SMP PREEMPT ...
  # which is a per-ROM fingerprint. Keep the release (which is what the report
  # needs) and the machine; drop the -<commits>-g<hash> build suffix.
  printf 'Linux %s %s Android\n' \
    "$(uname -r | sed -E 's/-([0-9]+-)?g[0-9a-f]{7,}.*$//')" "$(uname -m)"
  echo "--- cores ---";   nproc
  echo "--- cpuinfo ---"; grep -m1 -E 'Hardware|model name' /proc/cpuinfo
  echo "--- cpu features (selected) ---"
  grep -m1 Features /proc/cpuinfo | tr ' ' '\n' \
    | grep -E '^(asimd|i8mm|dotprod|sve|sve2|bf16|fp16)$' | tr '\n' ' '; echo
  echo
  echo "--- memory ---";   free -m
  echo
  echo "--- llama.cpp ---"
  "$BIN/llama-cli" --version 2>&1
  echo
  echo "--- vulkan ICDs present ---"
  ls -1 "$PREFIX/share/vulkan/icd.d/" 2>/dev/null
  echo
  echo "--- vulkan loader ---"
  # readlink (not `ls -l`): `ls -l` would embed the Termux username in the output
  readlink "$PREFIX/lib/libvulkan.so.1" 2>/dev/null
  echo
  echo "--- relevant termux packages ---"
  pkg list-installed 2>/dev/null \
    | grep -E '^(clang|cmake|shaderc|spirv-tools|spirv-headers|vulkan-loader|vulkan-headers|glslang|python|curl|git)/'
} > "$DEVICE" 2>&1
echo "   ok device-info-$RUN.txt"

# ---------- 2. Stop the server, free device memory ---------------------------
if [ -x "$LAUNCHER" ]; then
  echo "stopping llama-server (it would hold device memory and skew the run)"
  bash "$LAUNCHER" --stop >/dev/null 2>&1
  sleep 3
fi

# ---------- 3. Controlled A/B (the core measurement) -------------------------
echo "llama-bench -ngl 0,99 -p 64 -n 32 -r 3"
"$BIN/llama-bench" -m "$MODEL" -ngl 0,99 -p 64 -n 32 -r 3 > "$BENCH" 2>&1
echo "   ok llama-bench-$RUN.txt  (exit=$?)"

# ---------- 4. Device capability + layer-offload evidence --------------------
# Note `</dev/null`: without it llama-cli stops at the interactive prompt waiting
# on stdin and the script hangs forever (we have hit this).
echo "verbose launch, capturing device capability and layer placement"
"$BIN/llama-cli" -m "$MODEL" -p hi -ngl 99 -n 1 -v </dev/null > "$VERBOSE" 2>&1

{
  echo "=== collected: $(date -Iseconds) ==="
  echo
  echo "--- 1. ggml_vulkan device capability line ---"
  grep -m1 'ggml_vulkan: 0 =' "$VERBOSE"
  echo
  echo "--- 2. device enumeration as llama.cpp sees it ---"
  "$BIN/llama-cli" --list-devices 2>&1
  echo
  echo "--- 3. layer offload + buffer sizes ---"
  grep -E 'offloaded [0-9]+/[0-9]+ layers|model buffer size|KV buffer size|compute buffer size|using device' \
    "$VERBOSE"
  echo
  echo "--- 4. number of layers assigned to the GPU ---"
  echo -n "layers assigned to Vulkan0: "
  grep -c 'assigned to device Vulkan0' "$VERBOSE"
} > "$GPU" 2>&1
echo "   ok gpu-evidence-$RUN.txt"

# ---------- 5. CPU-seconds: the metric that actually matters on a phone ------
# Reads utime+stime from /proc/<pid>/stat — a kernel counter, not an estimate.
echo "measuring CPU-seconds (96 tokens generated per offload setting)"
{
  echo "=== collected: $(date -Iseconds) ==="
  echo "method: sample (utime+stime) from /proc/<pid>/stat every 1s, take the max"
  echo "clock ticks assumed 100/s (USER_HZ)"
  echo
  for NGL in 99 0; do
    START=$(date +%s)
    "$BIN/llama-cli" -m "$MODEL" -p "hello" -ngl "$NGL" -n 96 </dev/null >/dev/null 2>&1 &
    PID=$!
    MAXT=0
    while kill -0 "$PID" 2>/dev/null; do
      # fields 14/15 of /proc/<pid>/stat are utime/stime. comm (field 2) is
      # parenthesised and may contain spaces, which would shift the columns —
      # fine for llama-cli, but read the whole tail after the closing paren if
      # you retarget this.
      T=$(awk '{print $14+$15}' "/proc/$PID/stat" 2>/dev/null)
      if [ -n "${T:-}" ] && [ "$T" -gt "$MAXT" ]; then MAXT=$T; fi
      sleep 1
    done
    wait "$PID"; RC=$?
    EL=$(( $(date +%s) - START ))
    printf 'ngl=%-3s rc=%s wall=%ss cpu_ticks=%s cpu_seconds=%s\n' \
           "$NGL" "$RC" "$EL" "$MAXT" "$(( MAXT / 100 ))"
    sleep 5
  done
} > "$CPUSEC" 2>&1
echo "   ok cpu-seconds-$RUN.txt"

# ---------- 6. Restore the server --------------------------------------------
if [ -x "$LAUNCHER" ]; then
  echo "restarting llama-server"
  bash "$LAUNCHER"
fi

echo
echo "done. raw files for run '$RUN':"
ls -la "$RAW"/*-"$RUN".*
