#!/data/data/com.termux/files/usr/bin/bash
# bench/harness-bench/run-bench.sh — score a model on the 30 harness tasks.
#
# Usage:
#   bash run-bench.sh <label> <model.gguf> [ngl]
#
# What it measures, per task:
#   pass/fail      the checker in tasks.tsv, evaluated against the command's stdout
#   wall seconds   request sent -> command finished
#   CPU seconds    the SERVER's utime+stime delta across the request
#
# That last one is the metric this project is actually about. On a phone the
# scarce resource is not tokens per second, it is the CPU time the foreground
# has to give up — so a model that is slower but cheaper can still be the right
# choice, and the two numbers have to be read together.
#
# The prompt sent is agent.sh's SYSTEM_PROMPT, not a benchmark-specific one, so
# the score reflects the model as the harness actually drives it.
#
# Results go to bench/harness-bench/results/<label>.tsv — one row per task, plus
# the raw reply so a failure can be read rather than guessed at.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="${LAB:-/storage/emulated/0/bench-lab}"
PORT="${PORT:-8099}"
CTX="${CTX:-4096}"
LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp-new}"
PIDFILE="${PIDFILE:-$HOME/.agent/llama-server.pid}"

LABEL="${1:?usage: run-bench.sh <label> <model.gguf> [ngl]}"
MODEL="${2:?usage: run-bench.sh <label> <model.gguf> [ngl]}"
NGL="${3:-99}"

BIN="$LLAMA_DIR/build/bin"
export LD_LIBRARY_PATH="$BIN:${LD_LIBRARY_PATH:-}"
OUTDIR="$HERE/results"
mkdir -p "$OUTDIR"
RESFILE="$OUTDIR/$LABEL.tsv"
[ -e "$RESFILE" ] && { echo "refusing to overwrite $RESFILE" >&2; exit 3; }

# The harness's own prompt, EXTRACTED from agent.sh, not copied.
#
# An earlier version of this file carried its own copy under a comment claiming
# the two were identical. They were not: the copy was a Chinese translation of
# agent.sh's English prompt. The comment was true about the intent and false
# about the file, which is the worst kind — it would have gone on being believed.
# Extracting means the benchmark physically cannot score a prompt nobody runs.
AGENT_SH="${AGENT_SH:-$HOME/termux-harness/agent.sh}"
SYS_PROMPT=$(
    REPLY_LANG_NAME="${REPLY_LANG_NAME:-Chinese}"
    eval "$(awk '/^SYSTEM_PROMPT=/{f=1} f{print} f&&/"$/ {exit}' "$AGENT_SH")"
    printf '%s' "$SYSTEM_PROMPT"
)
[ -n "$SYS_PROMPT" ] || {
    echo "could not read SYSTEM_PROMPT out of $AGENT_SH" >&2; exit 6; }
echo "prompt: ${#SYS_PROMPT} chars from $AGENT_SH"

ask() {  # ask <user prompt> -> prints the raw model reply
    python3 - "$SYS_PROMPT" "$1" <<'PY'
import json, sys, urllib.request
sys_p, user_p = sys.argv[1], sys.argv[2]
body = json.dumps({
    "messages": [{"role": "system", "content": sys_p},
                 {"role": "user", "content": user_p}],
    "temperature": 0.2, "max_tokens": 256, "stream": False,
}).encode()
req = urllib.request.Request(f"http://127.0.0.1:{__import__('os').environ.get('PORT','8099')}/v1/chat/completions",
                             data=body, headers={"Content-Type": "application/json"})
try:
    d = json.loads(urllib.request.urlopen(req, timeout=600).read())
    print(d["choices"][0]["message"]["content"])
except Exception as e:
    print("__ERROR__ " + str(e))
PY
}

server_cpu_ticks() {
    local p="$1"
    awk '{print $14+$15}' "/proc/$p/stat" 2>/dev/null || echo 0
}

# Find the running server's pid.
#
# `pgrep -x llama-server` is NOT usable on this device: it returns nothing while
# the process is plainly running, which is how the cpu_s column silently came
# out all zeros in the first version of this script.
#
# /proc/*/comm is matched rather than cmdline on purpose. Matching a cmdline
# would also match THIS script's own process, since the pattern would appear in
# its own command line — that is gotcha #7 in docs/TERMUX-GOTCHAS.md, and it has
# already killed a shell four times in this project.
find_server_pid() {
    local p d
    p=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "${p:-}" ] && [ -r "/proc/$p/stat" ]; then printf '%s' "$p"; return 0; fi
    for d in /proc/[0-9]*; do
        [ -r "$d/comm" ] || continue
        if [ "$(cat "$d/comm" 2>/dev/null)" = "llama-server" ]; then
            printf '%s' "${d#/proc/}"; return 0
        fi
    done
    return 1
}

# ---- start the server ------------------------------------------------------
# RUNNING=1 scores a server that is already up (the harness's own, started by
# start-llama-server.sh with its real -ngl ladder). That is the only way to
# measure the configuration users actually run: starting our own server here
# would score a setup nobody has. Default is still to start one, so a run on a
# quiet device stays reproducible.
if [ "${RUNNING:-0}" = "1" ]; then
    curl -sf -m 5 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 || {
        echo "RUNNING=1 but no server answering on port $PORT" >&2; exit 5; }
    SPID=$(find_server_pid)
    [ -n "$SPID" ] || { echo "could not find the running server's pid" >&2; exit 5; }
    STARTED=0
    echo "scoring $LABEL against the ALREADY-RUNNING server on port $PORT (pid=$SPID)"
else
    pkill -x llama-server 2>/dev/null; sleep 3
    avail=$(free -m | awk '/^Mem:/{print $7}')
    need=$(( $(stat -Lc%s "$MODEL" 2>/dev/null || echo 0) / 1048576 + 800 ))
    if [ "$avail" -lt "$need" ]; then
        echo "refusing to start: ${avail} MiB available, ~${need} MiB needed for $MODEL" >&2
        exit 4
    fi
    echo "available ${avail} MiB, need ~${need} MiB"

    nohup "$BIN/llama-server" -m "$MODEL" -ngl "$NGL" -c "$CTX" \
          --host 127.0.0.1 --port "$PORT" > "$OUTDIR/$LABEL.server.log" 2>&1 &
    SPID=$!    # capture it here, not with pgrep: the first version used
               # `pgrep -x llama-server`, which returned nothing on this device
               # and silently made every CPU-seconds reading 0
    STARTED=1
    for i in $(seq 1 60); do
        curl -sf -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
        sleep 3
    done
    curl -sf -m 3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 || {
        echo "server never became ready; see $OUTDIR/$LABEL.server.log" >&2; exit 5; }
    echo "server up (pid=$SPID), scoring $LABEL on $(basename "$MODEL") -ngl $NGL"
fi

# ---- header ----------------------------------------------------------------
{
    printf '# label\t%s\n'   "$LABEL"
    printf '# model\t%s\n'   "$MODEL"
    printf '# ngl\t%s\n'     "$NGL"
    printf '# started\t%s\n' "$(date -Iseconds)"
    printf '#\n'
    printf 'id\tresult\twall_s\tcpu_s\tcmd\treply\n'
} > "$RESFILE"

PASS=0; FAIL=0; N=0

while IFS=$'\t' read -r tid req check; do
    case "$tid" in ''|'#'*) continue ;; esac
    N=$((N+1))
    # LIMIT=n runs only the first n tasks — for smoke-testing the machinery
    # without spending 30 model calls to find out the checker is broken.
    # A LIMIT run must never be reported as a score: it is a partial run.
    [ -n "${LIMIT:-}" ] && [ "$N" -gt "$LIMIT" ] && break

    bash "$HERE/setup-fixtures.sh" >/dev/null 2>&1

    # tasks.tsv writes the fixture path as $LAB so the file stays readable; the
    # model has to be told where to look, the same way a real user would say it.
    req_expanded="${req//\$LAB/$LAB}"

    cpu0=$(server_cpu_ticks "$SPID")
    t0=$(date +%s)
    reply=$(PORT="$PORT" ask "$req_expanded")
    t1=$(date +%s)
    cpu1=$(server_cpu_ticks "$SPID")
    wall=$(( t1 - t0 ))
    # Two decimals, NOT integer division. With -ngl 99 the GPU does the work and
    # the server's own CPU time is a small fraction of wall — measured on this
    # device: 82 ticks (0.82 s) for a 13.2 s request. A whole-second column
    # therefore reads as a row of zeros, which looks like a broken instrument
    # rather than the real asymmetry between wall and CPU.
    cpus=$(awk -v a="$cpu0" -v b="$cpu1" 'BEGIN{printf "%.2f", (b-a)/100}')

    # the same extraction agent.sh does
    cmd=$(printf '%s' "$reply" | sed -n 's/.*\[CMD\]//;s/\[\/CMD\].*//p' | tr -d '\r' | head -1)

    if [ -z "$cmd" ]; then
        result="noCMD"
    else
        OUT="$(eval "$cmd" </dev/null 2>&1)"
        export OUT LAB
        if eval "$check" >/dev/null 2>&1; then result="PASS"; PASS=$((PASS+1))
        else result="FAIL"; FAIL=$((FAIL+1)); fi
    fi
    [ "$result" = "noCMD" ] && FAIL=$((FAIL+1))

    cmd1=$(printf '%s' "$cmd" | tr '\t\n' '  ' | cut -c1-120)
    rep1=$(printf '%s' "$reply" | tr '\t\n' '  ' | cut -c1-120)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tid" "$result" "$wall" "$cpus" "$cmd1" "$rep1" >> "$RESFILE"
    printf '  %-5s %-6s %2ss %3s CPU-s  %s\n' "$tid" "$result" "$wall" "$cpus" "${cmd1:-<none>}"
done < "$HERE/tasks.tsv"

# ---- stop the server -------------------------------------------------------
# Only if we started it. In RUNNING=1 mode this is somebody else's server — the
# harness's own — and killing it would be a side effect the caller never asked
# for.
if [ "$STARTED" = "1" ]; then
    kill "$SPID" 2>/dev/null; sleep 3; kill -9 "$SPID" 2>/dev/null
else
    echo "leaving the running server alone (we did not start it)"
fi

TOTAL=$(( PASS + FAIL ))
{
    printf '#\n'
    printf '# passed\t%s/%s\n' "$PASS" "$TOTAL"
    printf '# finished\t%s\n'  "$(date -Iseconds)"
} >> "$RESFILE"

echo
echo "=== $LABEL: $PASS/$TOTAL ==="
echo "results: $RESFILE"
