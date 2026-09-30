#!/data/data/com.termux/files/usr/bin/bash
# start-llama-server.sh — launch llama.cpp's OpenAI-compatible server with Vulkan GPU offload.
#
# Termux has no /bin/bash and no /usr/bin/env, so the shebang above is deliberately
# the real Termux path. `install.sh` rewrites it if your $PREFIX differs.
#
# Usage:
#   bash start-llama-server.sh            # start (idempotent)
#   bash start-llama-server.sh --status   # is it up?
#   bash start-llama-server.sh --stop     # stop it
#
# Env overrides: MODEL PORT HOST CTX NGL_LADDER LLAMA_BIN LOG HEALTH_TIMEOUT

set -uo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export PATH="$PREFIX/bin:$PATH"

LLAMA_BIN="${LLAMA_BIN:-$HOME/llama.cpp/build/bin/llama-server}"
MODEL="${MODEL:-$HOME/qwen2.5-coder-7b.gguf}"
PORT="${PORT:-8080}"
HOST="${HOST:-127.0.0.1}"
CTX="${CTX:-4096}"
# GPU offload ladder: try full offload first, drop to a safe value if it dies.
# -ngl 99 (all 28 layers) needs ~4.2 GiB of the Adreno's shared memory;
# -ngl 30 is the documented fallback when the device is short on memory.
NGL_LADDER="${NGL_LADDER:-99 30 0}"
LOG="${LOG:-$HOME/.agent/llama-server.log}"
PIDFILE="${PIDFILE:-$HOME/.agent/llama-server.pid}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-240}"

export LD_LIBRARY_PATH="$(dirname "$LLAMA_BIN"):${LD_LIBRARY_PATH:-}"
BASE_URL="http://${HOST}:${PORT}"

c_ok()   { printf '\033[0;32m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[0;31m%s\033[0m\n' "$*"; }

server_pid() {
    [ -f "$PIDFILE" ] || return 1
    local p; p=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && { echo "$p"; return 0; }
    return 1
}

is_up() { curl -sf -m 3 "$BASE_URL/health" >/dev/null 2>&1; }

do_status() {
    if is_up; then
        c_ok "✅ llama-server 正在运行  pid=$(server_pid 2>/dev/null || echo '?')  $BASE_URL"
        curl -s -m 5 "$BASE_URL/health"; echo
        return 0
    fi
    c_warn "⚠️  llama-server 未在 $BASE_URL 响应"
    return 1
}

do_stop() {
    local p
    if p=$(server_pid); then
        kill "$p" 2>/dev/null
        for _ in $(seq 1 20); do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
        kill -9 "$p" 2>/dev/null
        c_ok "🛑 已停止 llama-server (pid=$p)"
    else
        c_warn "没有正在运行的 llama-server"
    fi
    rm -f "$PIDFILE"
}

# Start one process and wait until /health answers 200 or the process dies.
try_ngl() {
    local ngl="$1" p
    c_warn "▶️  尝试启动：-ngl $ngl  (port $PORT, ctx $CTX)"
    {
        echo "=== start $(date -Iseconds) ngl=$ngl model=$MODEL ==="
    } >> "$LOG"

    nohup "$LLAMA_BIN" \
        -m "$MODEL" \
        -ngl "$ngl" \
        --host "$HOST" \
        --port "$PORT" \
        -c "$CTX" \
        >> "$LOG" 2>&1 &
    p=$!
    echo "$p" > "$PIDFILE"

    local waited=0
    while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
        if ! kill -0 "$p" 2>/dev/null; then
            c_err "❌ -ngl $ngl 启动失败：进程已退出（见 $LOG）"
            return 1
        fi
        if is_up; then
            c_ok "✅ llama-server 就绪 (pid=$p, -ngl $ngl)  $BASE_URL"
            local dev
            dev=$(grep -oE 'Vulkan0 : [^(]*' "$LOG" 2>/dev/null | tail -1)
            [ -n "$dev" ] && c_ok "   GPU: $dev"
            return 0
        fi
        sleep 3; waited=$((waited + 3))
        [ $((waited % 30)) -eq 0 ] && c_warn "   ...加载中 ${waited}s（7B 首次载入显存需要时间）"
    done

    c_err "❌ -ngl $ngl 超时 ${HEALTH_TIMEOUT}s 仍未就绪，杀掉重试"
    kill -9 "$p" 2>/dev/null
    rm -f "$PIDFILE"
    return 1
}

main() {
    case "${1:-}" in
        --status) do_status; exit $? ;;
        --stop)   do_stop;   exit 0 ;;
    esac

    [ -x "$LLAMA_BIN" ] || { c_err "❌ 找不到 llama-server: $LLAMA_BIN"; exit 1; }
    [ -f "$MODEL" ]     || { c_err "❌ 找不到模型: $MODEL"; exit 1; }

    if is_up; then
        c_ok "✅ llama-server 已在运行，无需重复启动  $BASE_URL"
        exit 0
    fi
    # stale pidfile from a crashed run
    rm -f "$PIDFILE"
    mkdir -p "$(dirname "$LOG")"

    local ngl
    for ngl in $NGL_LADDER; do
        if try_ngl "$ngl"; then exit 0; fi
        c_warn "⬇️  降级到下一个 offload 档位..."
        sleep 2
    done

    c_err "❌ 所有 -ngl 档位均失败。最后 40 行日志："
    tail -40 "$LOG"
    exit 1
}

main "$@"
