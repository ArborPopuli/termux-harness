#!/data/data/com.termux/files/usr/bin/bash
# capture-evidence.sh — 干净地重采 GPU 使用证据
#
# 上一次的教训：llama-cli 在检测到 tty 时会直接把界面写到终端，
# 重定向到文件反而抓不全，还会把多次运行的内容混在一起。
# 这里对每一次采集都用 `</dev/null` 断开 stdin（避免停在交互提示符），
# 并单独成文件、单独 grep，不复用同一份日志。
set -uo pipefail
RAW="$HOME/termux-harness/bench/raw"
BIN="$HOME/llama.cpp/build/bin"
MODEL="$HOME/qwen2.5-coder-7b.gguf"
export LD_LIBRARY_PATH="$BIN:${LD_LIBRARY_PATH:-}"
mkdir -p "$RAW"

EV="$RAW/proc-evidence.log"
OUT="$RAW/llama-cli-ngl99-verbose.txt"
rm -f "$EV" "$OUT"

echo "▶️  启动一次 -ngl 99 运行，同时采样 /proc"
"$BIN/llama-cli" -m "$MODEL" -p "你好" -ngl 99 -n 8 -v </dev/null >"$OUT" 2>&1 &
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

echo "▶️  汇总"
{
  echo "=== collected: $(date -Iseconds) ==="
  echo "device: HONOR AAK-AN00 / SM8750 (Snapdragon 8 Elite) / Adreno 830"
  echo
  echo "--- [1] ggml_vulkan device capability line (from llama-bench) ---"
  grep -m1 'ggml_vulkan: 0 =' "$RAW/llama-bench-raw.txt"
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
  echo "--- [5] /proc evidence while the -ngl 99 process was alive ---"
  cat "$EV"
  echo
  echo "--- [5b] maxima ---"
  printf 'max_fd_kgsl_open : '; grep -o 'fd_kgsl_open=[0-9]*'  "$EV" | cut -d= -f2 | sort -rn | head -1
  printf 'max_maps_freedreno: '; grep -o 'maps_freedreno=[0-9]*' "$EV" | cut -d= -f2 | sort -rn | head -1
  printf 'max_maps_lvp     : '; grep -o 'maps_lvp=[0-9]*'      "$EV" | cut -d= -f2 | sort -rn | head -1
  echo
  echo "--- [6] model reply produced during that run ---"
  sed -n '/^> /,/^$/p' "$OUT" | head -4
} > "$RAW/gpu-evidence.txt" 2>&1

cat "$RAW/gpu-evidence.txt"
