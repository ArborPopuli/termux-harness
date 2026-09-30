#!/data/data/com.termux/files/usr/bin/bash
# bench/run-bench.sh — reproduce every number quoted in the README.
#
# Stops llama-server first: it holds ~4.2 GiB of device memory, which would
# skew (or break) the -ngl 99 measurements. Restarts it at the end.
#
# Output: ./raw/*.txt   (these raw files are what the README cites)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW="$HERE/raw"
mkdir -p "$RAW"

LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
MODEL="${MODEL:-$HOME/qwen2.5-coder-7b.gguf}"
LAUNCHER="${LAUNCHER:-$HOME/termux-harness/start-llama-server.sh}"
BIN="$LLAMA_DIR/build/bin"
export LD_LIBRARY_PATH="$BIN:${LD_LIBRARY_PATH:-}"

echo "▶️  采集开始 $(date -Iseconds)"
echo "   llama.cpp : $LLAMA_DIR"
echo "   model     : $MODEL"
echo "   output    : $RAW"

# ---------- 1. 环境快照 ------------------------------------------------------
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
  echo "--- kernel ---";  uname -a
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
} > "$RAW/device-info.txt" 2>&1
echo "   ✓ device-info.txt"

# ---------- 2. 停掉服务，腾出显存 --------------------------------------------
if [ -x "$LAUNCHER" ]; then
  echo "⏸  停止 llama-server（避免占用显存污染测量）"
  bash "$LAUNCHER" --stop >/dev/null 2>&1
  sleep 3
fi

# ---------- 3. 受控 A/B（核心数据）------------------------------------------
echo "▶️  llama-bench -ngl 0,99 -p 64 -n 32 -r 3"
"$BIN/llama-bench" -m "$MODEL" -ngl 0,99 -p 64 -n 32 -r 3 \
  > "$RAW/llama-bench-raw.txt" 2>&1
echo "   ✓ llama-bench-raw.txt  (exit=$?)"

# ---------- 4. 设备能力 + 层卸载证据 ----------------------------------------
# 注意 `</dev/null`：不加的话 llama-cli 会停在交互式提示符等 stdin，
# 脚本会永久挂住（我们踩过这个坑）。
echo "▶️  verbose 启动，抓设备能力与层分配"
"$BIN/llama-cli" -m "$MODEL" -p hi -ngl 99 -n 1 -v </dev/null \
  > "$RAW/llama-cli-verbose.txt" 2>&1

{
  echo "=== collected: $(date -Iseconds) ==="
  echo
  echo "--- 1. ggml_vulkan device capability line ---"
  grep -m1 'ggml_vulkan: 0 =' "$RAW/llama-cli-verbose.txt"
  echo
  echo "--- 2. device enumeration as llama.cpp sees it ---"
  "$BIN/llama-cli" --list-devices 2>&1
  echo
  echo "--- 3. layer offload + buffer sizes ---"
  grep -E 'offloaded [0-9]+/[0-9]+ layers|model buffer size|KV buffer size|compute buffer size|using device' \
    "$RAW/llama-cli-verbose.txt"
  echo
  echo "--- 4. number of layers assigned to the GPU ---"
  echo -n "layers assigned to Vulkan0: "
  grep -c 'assigned to device Vulkan0' "$RAW/llama-cli-verbose.txt"
} > "$RAW/gpu-evidence.txt" 2>&1
echo "   ✓ gpu-evidence.txt"

# ---------- 5. CPU-秒：手机端真正该看的指标 ---------------------------------
# 读 /proc/<pid>/stat 的 utime+stime（内核计数器，非估算）
echo "▶️  CPU-秒 测量（每档生成 96 token）"
{
  echo "=== collected: $(date -Iseconds) ==="
  echo "method: sample (utime+stime) from /proc/<pid>/stat every 1s, take the max"
  echo "clock ticks assumed 100/s (USER_HZ)"
  echo
  for NGL in 99 0; do
    START=$(date +%s)
    "$BIN/llama-cli" -m "$MODEL" -p "你好" -ngl "$NGL" -n 96 </dev/null >/dev/null 2>&1 &
    PID=$!
    MAXT=0
    while kill -0 "$PID" 2>/dev/null; do
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
} > "$RAW/cpu-seconds.txt" 2>&1
echo "   ✓ cpu-seconds.txt"

# ---------- 6. 恢复服务 ------------------------------------------------------
if [ -x "$LAUNCHER" ]; then
  echo "▶️  重新启动 llama-server"
  bash "$LAUNCHER"
fi

echo
echo "✅ 采集完成。原始文件在 $RAW"
ls -la "$RAW"
