#!/data/data/com.termux/files/usr/bin/bash
# tests/integration.sh — end-to-end smoke test for termux-harness.
#
# Exits 0 only if every check passed, so it is usable from a script or CI.
# Requires llama-server to be up: run `bash start-llama-server.sh` first.
#
# `timeout` is used when coreutils provides it and skipped otherwise — it is not
# part of the base Termux install that the README lists.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${BASE:-http://127.0.0.1:8080}"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

tw() {  # tw <seconds> <command...>
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; else "$@"; fi
}

echo "########## 0. server reachable ##########"
if curl -sf -m 10 "$BASE/health" >/dev/null 2>&1; then
    ok "llama-server is answering on $BASE"
else
    bad "llama-server is not answering on $BASE — run: bash $HERE/start-llama-server.sh"
    echo
    echo "aborting: no server, the remaining checks would all fail for the same reason."
    exit 1
fi

echo
echo "########## 1. /health ##########"
HEALTH=$(curl -s -m 10 "$BASE/health" 2>/dev/null)
printf '  body: %s\n' "$HEALTH"
if [ -n "$HEALTH" ]; then ok "/health returned a body"; else bad "/health returned nothing"; fi

echo
echo "########## 2. /v1/models ##########"
MODELS=$(curl -s -m 10 "$BASE/v1/models" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
ids = [m.get("id") for m in d.get("data", [])]
for i in ids: print("  model id:", i)
sys.exit(0 if ids else 1)
' 2>&1)
MODELS_RC=$?
if [ "$MODELS_RC" -eq 0 ] && [ -n "$MODELS" ]; then
    echo "$MODELS"; ok "/v1/models listed at least one model"
else
    bad "/v1/models did not list a model"
fi

echo
echo "########## 3. /v1/chat/completions ##########"
PAYLOAD=$(python3 - <<'PY'
import json
print(json.dumps({
    "messages": [
        {"role": "system", "content": "You generate terminal commands. Output only [CMD]command[/CMD], no explanation."},
        {"role": "user", "content": "list the 5 most recently modified python files in the home directory"},
    ],
    "max_tokens": 128, "temperature": 0.2, "stream": False,
}, ensure_ascii=False))
PY
)
CONTENT=$(curl -s -m 300 -X POST "$BASE/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$PAYLOAD" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d["choices"][0]["message"]["content"])
except Exception as e:
    print("__ERROR__ " + str(e))
' 2>&1)
printf '  content: %s\n' "$CONTENT"
case "$CONTENT" in
    __ERROR__*) bad "chat completion did not return usable content" ;;
    "")         bad "chat completion returned empty content" ;;
    *)          ok "chat completion returned content" ;;
esac

echo
echo "########## 4. harness: agent.sh (answering 'n', nothing is executed) ##########"
OUT=$(echo "n" | tw 400 bash "$HERE/agent.sh" "list the 5 most recently modified python files in the home directory" 2>&1)
# agent.sh strips the [CMD] markers and prints the bare command, then waits at the
# confirmation prompt — so the literal string "[CMD]" never appears in its output.
# Reaching "cancelled" means it did parse a command out of the model's reply.
if printf '%s' "$OUT" | grep -q 'cancelled' && ! printf '%s' "$OUT" | grep -q 'did not emit'; then
    ok "agent.sh parsed a command and reached the confirmation prompt"
else
    bad "agent.sh never got as far as a confirmable command"
    printf '%s\n' "$OUT" | tail -20 | sed 's/^/    /'
fi

echo
echo "########## 5. harness via the ~/.agent/agent.sh wrapper ##########"
if [ -f "$HOME/.agent/agent.sh" ]; then
    OUT=$(echo "n" | tw 400 bash "$HOME/.agent/agent.sh" "count the .py files in the home directory" 2>&1)
    if printf '%s' "$OUT" | grep -q 'cancelled' && ! printf '%s' "$OUT" | grep -q 'did not emit'; then
        ok "wrapper parsed a command and reached the confirmation prompt"
    else
        bad "wrapper never got as far as a confirmable command"
        printf '%s\n' "$OUT" | tail -20 | sed 's/^/    /'
    fi
else
    bad "$HOME/.agent/agent.sh missing — run bash $HERE/install.sh"
fi

echo
echo "########## 6. plugin dispatch ##########"
OUT=$(bash "$HERE/agent.sh" /example a b 2>&1)
if printf '%s' "$OUT" | grep -q 'example'; then
    ok "plugin /example was dispatched"
else
    bad "plugin /example was not dispatched"
fi

echo
echo "########## 7. server status ##########"
if bash "$HERE/start-llama-server.sh" --status >/dev/null 2>&1; then
    ok "--status reports the server up"
else
    bad "--status does not report the server up"
fi

echo
echo "=================================================="
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
