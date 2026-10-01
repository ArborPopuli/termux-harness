#!/data/data/com.termux/files/usr/bin/bash
# bench/capture-evidence.sh — re-capture the "is the GPU actually being used" evidence.
#
# Usage:
#   bash bench/capture-evidence.sh [label] [--force]
#
# Same [label]/[--force] convention as run-bench.sh; artifacts are written as
# <name>-<label>.<ext> and are never overwritten without --force.
#
# This script assumes run-bench.sh has already produced bench/raw/llama-bench-<label>.txt
# for the same label — it quotes the ggml_vulkan capability line out of it. Run
# run-bench.sh first, or point LLAMA_BENCH_FILE at an existing file.
#
# Lesson from last time: llama-cli writes its interactive UI straight to the
# terminal when it sees a tty, so redirecting to a file silently loses output and
# ends up with several runs mixed together. Every capture here therefore gets its
# own file, its own `</dev/null` to detach stdin (so it cannot sit at the
# interactive prompt), and its own grep.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW="$HERE/raw"
BIN="${LLAMA_DIR:-$HOME/llama.cpp}/build/bin"
MODEL="${MODEL:-$HOME/qwen2.5-coder-7b.gguf}"
LAUNCHER="${LAUNCHER:-$HOME/termux-harness/start-llama-server.sh}"
export LD_LIBRARY_PATH="$BIN:${LD_LIBRARY_PATH:-}"
mkdir -p "$RAW"

RUN=""
FORCE=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    -*)      echo "unknown option: $a" >&2; exit 2 ;;
    *)       if [ -z "$RUN" ]; then RUN="$a"
             else echo "usage: capture-evidence.sh [label] [--force]" >&2; exit 2; fi ;;
  esac
done
[ -n "$RUN" ] || RUN="run$(date -u +%Y%m%d-%H%M%S)"

EV="$RAW/proc-evidence-$RUN.log"
OUT="$RAW/llama-cli-ngl99-verbose-$RUN.txt"
GPU="$RAW/gpu-evidence-$RUN.txt"
BENCH_FILE="${LLAMA_BENCH_FILE:-$RAW/llama-bench-$RUN.txt}"

if [ "$FORCE" -ne 1 ]; then
  for f in "$EV" "$OUT" "$GPU"; do
    if [ -e "$f" ]; then
      echo "refusing to overwrite $f" >&2
      echo "  (re-run with --force if that is what you want)" >&2
      exit 3
    fi
  done
fi

if [ ! -f "$BENCH_FILE" ]; then
  echo "missing $BENCH_FILE" >&2
  echo "  run 'bash bench/run-bench.sh $RUN' first, or set LLAMA_BENCH_FILE" >&2
  exit 4
fi

# Stop the server first. This script starts its own `-ngl 99` process, and a 7B
# Q4_K_M needs ~4.2 GiB of device memory — on top of the ~4.2 GiB a running
# llama-server already holds. Two of them do not fit, and Android resolves that
# by killing Termux, which takes the SSH session with it. Same guard as
# bench/run-bench.sh, for the same reason.
if [ ! -f "$LAUNCHER" ]; then
  echo "refusing to start: no launcher at $LAUNCHER" >&2
  echo "  this script must stop llama-server first or the phone runs out of memory" >&2
  exit 7
fi
echo "stopping llama-server (it would hold device memory and skew the capture)"
bash "$LAUNCHER" --stop >/dev/null 2>&1
sleep 3
if bash "$LAUNCHER" --status >/dev/null 2>&1; then
  echo "refusing to start: llama-server is still answering after --stop" >&2
  echo "  a second -ngl 99 process now would run the phone out of memory" >&2
  exit 8
fi

NEED_MB="${NEED_MB:-4500}"
AVAIL_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
if [ -n "${AVAIL_MB:-}" ] && [ "$AVAIL_MB" -lt "$NEED_MB" ]; then
  echo "refusing to start: ${AVAIL_MB} MiB available, ~${NEED_MB} MiB needed for -ngl 99" >&2
  echo "  free up memory, or set NEED_MB to override" >&2
  exit 9
fi
echo "available memory: ${AVAIL_MB:-unknown} MiB (need >= $NEED_MB)"

echo "starting one -ngl 99 run and sampling /proc alongside it"
"$BIN/llama-cli" -m "$MODEL" -p "hello" -ngl 99 -n 8 -v </dev/null >"$OUT" 2>&1 &
PID=$!
echo "pid=$PID" > "$EV"
while kill -0 "$PID" 2>/dev/null; do
  {
    echo "--- $(date +%H:%M:%S) ---"
    if [ -d "/proc/$PID" ]; then
      echo "fd_kgsl_open=$(ls -l /proc/$PID/fd 2>/dev/null | grep -c kgsl)"
      echo "maps_freedreno=$(grep -c freedreno /proc/$PID/maps 2>/dev/null)"
      echo "maps_lvp=$(grep -c lvp /proc/$PID/maps 2>/dev/null)"
      echo "maps_libvulkan=$(grep -c libvulkan /proc/$PID/maps 2>/dev/null)"
      echo "rss_kb=$(awk '/VmRSS/{print $2}' /proc/$PID/status 2>/dev/null)"
    fi
  } >> "$EV"
  sleep 2
done
wait "$PID"; RC=$?
echo "exit=$RC" >> "$EV"

echo "summarising"
{
  echo "=== collected: $(date -Iseconds) ==="
  echo "device: HONOR AAK-AN00 / SM8750 (Snapdragon 8 Elite) / Adreno 830"
  echo
  echo "--- [1] ggml_vulkan device capability line (from $(basename "$BENCH_FILE")) ---"
  grep -m1 'ggml_vulkan: 0 =' "$BENCH_FILE"
  echo
  echo "--- [2] device enumeration ---"
  "$BIN/llama-cli" --list-devices </dev/null 2>&1
  echo
  echo "--- [3] layer offload + buffer sizes (-ngl 99) ---"
  grep -E 'offloaded [0-9]+/[0-9]+ layers|model buffer size|KV buffer size|compute buffer size|using device' "$OUT"
  echo
  echo "--- [4] layers assigned to Vulkan0 ---"
  printf 'count: '; grep -c 'assigned to device Vulkan0' "$OUT"
  echo
  echo "--- [4b] the same model at -ngl 0, for contrast ---"
  echo "    This is what makes [3] evidence rather than decoration: the lines below"
  echo "    must differ from [3]. They are also the raw backing for the -ngl 0"
  echo "    numbers quoted in docs/MEASUREMENTS.md section 4(b)."
  echo "    (-ngl 0 needs no device memory, so this is cheap.)"
  "$BIN/llama-cli" -m "$MODEL" -p "hi" -ngl 0 -n 1 -v </dev/null 2>&1 \
    | grep -E 'offloaded [0-9]+/[0-9]+ layers|model buffer size' | head -4
  echo
  echo "--- [5] process state while the -ngl 99 run was alive ---"
  echo "    NOTE: these three numbers do NOT distinguish GPU from CPU use. A -ngl 0"
  echo "    run reports the same values, because -ngl 0 still initialises the"
  echo "    Vulkan backend and merely declines to place layers on the device."
  echo "    See docs/CORRECTIONS.md §7. The discriminating evidence is [3] and [4]:"
  echo "    'offloaded N/29 layers' and the Vulkan0 buffer sizes change with -ngl."
  cat "$EV"
  echo
  echo "--- [5b] maxima over the run ---"
  printf 'max_fd_kgsl_open : '; grep -o 'fd_kgsl_open=[0-9]*'  "$EV" | cut -d= -f2 | sort -rn | head -1
  printf 'max_maps_freedreno: '; grep -o 'maps_freedreno=[0-9]*' "$EV" | cut -d= -f2 | sort -rn | head -1
  printf 'max_maps_lvp     : '; grep -o 'maps_lvp=[0-9]*'      "$EV" | cut -d= -f2 | sort -rn | head -1
  echo
  echo "--- [6] model reply produced during that run ---"
  sed -n '/^> /,/^$/p' "$OUT" | head -4
} > "$GPU" 2>&1

if [ -f "$LAUNCHER" ]; then
  echo "restarting llama-server"
  bash "$LAUNCHER"
fi

cat "$GPU"
