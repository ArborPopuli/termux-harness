#!/data/data/com.termux/files/usr/bin/bash
# agent.sh — a small agent harness for Termux.
#
# Driven by a local llama.cpp server (llama-server) over its OpenAI-compatible
# endpoint. Defaults to Qwen2.5-Coder-7B with Vulkan GPU offload (Adreno).
#
# Usage:
#   bash agent.sh "find jpgs from the last 3 days in Download"
#   bash agent.sh /<plugin> [args]        run a plugin
#
# Config: ~/.agent/config.sh (optional, see config.example.sh)

set -uo pipefail

AGENT_DIR="${AGENT_DIR:-$HOME/.agent}"
PLUGIN_DIR="$AGENT_DIR/plugins"
HISTORY_FILE="$AGENT_DIR/history.txt"
LAUNCHER="${LAUNCHER:-$HOME/termux-harness/start-llama-server.sh}"

# ---- defaults (override in ~/.agent/config.sh) ------------------------------
MODEL="${MODEL:-qwen2.5-coder-7b}"
API_HOST="${API_HOST:-127.0.0.1}"
API_PORT="${API_PORT:-8080}"
MAX_TOKENS="${MAX_TOKENS:-256}"
TEMPERATURE="${TEMPERATURE:-0.2}"
HISTORY_TURNS="${HISTORY_TURNS:-6}"
# Language the model is told to write its explanation in. The command half is
# always shell, i.e. English. Set REPLY_LANG=en in config.sh for English replies.
REPLY_LANG="${REPLY_LANG:-zh}"
# -----------------------------------------------------------------------------

[ -f "$AGENT_DIR/config.sh" ] && . "$AGENT_DIR/config.sh"
API_BASE="http://${API_HOST}:${API_PORT}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'

case "$REPLY_LANG" in
    zh) REPLY_LANG_NAME="Chinese" ;;
    en) REPLY_LANG_NAME="English" ;;
    *)  REPLY_LANG_NAME="$REPLY_LANG" ;;
esac

SYSTEM_PROMPT="You are a terminal assistant running inside Android Termux.
Split your answer into exactly two parts and output nothing else — no extra
prose, no Markdown fences, no other markers.

Part 1, the explanation: say in ${REPLY_LANG_NAME} what you are about to do, in
at most 3 sentences.
Part 2, the command: one single-line shell command, wrapped in [CMD] and [/CMD].
For example: [CMD]find /storage/emulated/0/ -iname '*.jpg' -mtime -3[/CMD]

Other rules:
1. File search and system operations only. Do not solve maths problems.
2. The default search root is /storage/emulated/0/.
3. Never emit a command that waits for user input."

# Start llama-server if it is not already answering (replaces the old check_ollama).
ensure_server() {
    if curl -sf -m 3 "$API_BASE/health" >/dev/null 2>&1; then
        return 0
    fi
    echo -e "${YELLOW}no model server on $API_BASE, starting llama-server (Vulkan GPU)...${NC}"
    # Existence, not the exec bit: the script is invoked through bash, and `-x`
    # is silently false for a file that exists but is not executable. That is not
    # hypothetical — it is how bench/run-bench.sh skipped stopping the server and
    # OOM-killed the phone.
    if [ -f "$LAUNCHER" ]; then
        bash "$LAUNCHER" || { echo -e "${RED}llama-server failed to start, see $AGENT_DIR/llama-server.log${NC}"; return 1; }
    else
        echo -e "${RED}launcher not found: $LAUNCHER${NC}"; return 1
    fi
}

get_context() {
    if [[ -f "$HISTORY_FILE" ]]; then tail -n "$HISTORY_TURNS" "$HISTORY_FILE"; else echo ""; fi
}

save_context() {
    echo "user: $1" >> "$HISTORY_FILE"
    echo "agent: $2" >> "$HISTORY_FILE"
    tail -n "$HISTORY_TURNS" "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
}

# Build the JSON with python3 — hand-escaping quotes, newlines and non-ASCII in
# bash is a losing game.
build_payload() {
    python3 - "$1" "$2" "$MAX_TOKENS" "$TEMPERATURE" <<'PY'
import json, sys
sys_p, user_p, max_tok, temp = sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4])
print(json.dumps({
    "messages": [
        {"role": "system", "content": sys_p},
        {"role": "user",   "content": user_p},
    ],
    "temperature": temp,
    "max_tokens": max_tok,
    "stream": False,
}, ensure_ascii=False))
PY
}

parse_content() {
    python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception as e:
    print("__PARSE_ERROR__ " + str(e)); sys.exit(0)
try:
    print(d["choices"][0]["message"]["content"])
except Exception:
    print("__API_ERROR__ " + json.dumps(d, ensure_ascii=False)[:600])
'
}

generate_response() {
    local context payload resp content
    context=$(get_context)
    payload=$(build_payload "$SYSTEM_PROMPT" "--- conversation history ---
$context
--- end of history ---

New request: $1")
    resp=$(curl -s -m 600 -X POST "$API_BASE/v1/chat/completions" \
                -H 'Content-Type: application/json' -d "$payload")
    if [ -z "$resp" ]; then echo "__API_ERROR__ empty response (server may have died)"; return; fi
    content=$(printf '%s' "$resp" | parse_content)
    printf '%s' "$content"
}

run_plugin() {
    local plugin_name="$1"; shift
    local plugin_file="$PLUGIN_DIR/${plugin_name}.sh"
    if [[ -f "$plugin_file" ]]; then
        echo -e "${CYAN}loading plugin: $plugin_name${NC}"
        source "$plugin_file" "$@"
    else
        echo -e "${YELLOW}no such plugin: $plugin_name. Available:${NC}"
        ls -1 "$PLUGIN_DIR" 2>/dev/null | sed 's/\.sh$//' | awk '{print "  - /"$1}'
    fi
}

main() {
    if [[ $# -eq 0 ]]; then echo -e "usage: $0 \"what you want\""; exit 1; fi
    if [[ "$1" == /* ]]; then run_plugin "${1:1}" "${@:2}"; exit 0; fi

    ensure_server || exit 1

    local user_prompt="$*"
    echo -e "${CYAN}thinking (model: $MODEL @ $API_BASE)...${NC}"
    local raw_response; raw_response=$(generate_response "$user_prompt")

    if [[ "$raw_response" == __API_ERROR__* || "$raw_response" == __PARSE_ERROR__* ]]; then
        echo -e "${RED}model server returned an error:${NC}"
        echo "$raw_response"
        exit 1
    fi

    # Extract exactly [CMD]...[/CMD]
    local cmd; cmd=$(echo "$raw_response" | sed -n 's/.*\[CMD\]//;s/\[\/CMD\].*//p' | tr -d '\r')
    local explanation; explanation=$(echo "$raw_response" | sed 's/\[CMD\].*//g' | tr -d '\r' | xargs)

    if [[ -z "$cmd" ]]; then
        echo -e "${RED}model did not emit [CMD]command[/CMD].${NC}"
        echo -e "${YELLOW}raw reply: $raw_response${NC}"
        exit 1
    fi

    # Check 1: the command should be plain ASCII. The usual cause of a non-ASCII
    # command is the model leaking prose into [CMD]...[/CMD] — but a legitimate
    # command can contain a CJK path, and the default search root is
    # /storage/emulated/0/, where Chinese filenames are common. Set
    # ALLOW_NON_ASCII=1 in config.sh to permit those.
    if [ "${ALLOW_NON_ASCII:-0}" != "1" ] && printf '%s' "$cmd" | LC_ALL=C grep -q '[^ -~]'; then
        echo -e "${RED}blocked: the generated command contains non-ASCII characters.${NC}"
        echo -e "${YELLOW}If this is a legitimate CJK path, set ALLOW_NON_ASCII=1 in $AGENT_DIR/config.sh${NC}"
        exit 1
    fi

    # Check 2: destructive commands. The root/home patterns are anchored so that
    # a legitimate path is not caught: `rm -rf /storage/emulated/0/tmp` must pass
    # while `rm -rf /` must not. Note this is string matching on a single line —
    # it is a speed bump, not a security boundary (see README).
    DANGEROUS_PATTERNS='rm[[:space:]]+-[a-zA-Z]+[[:space:]]+(/|~|\$HOME)(/|\*)?([[:space:]]|$)'
    DANGEROUS_PATTERNS="$DANGEROUS_PATTERNS"'|mkfs'
    DANGEROUS_PATTERNS="$DANGEROUS_PATTERNS"'|dd[[:space:]]+.*(if|of)=/dev/'
    DANGEROUS_PATTERNS="$DANGEROUS_PATTERNS"'|chmod[[:space:]]+-R[[:space:]]+777[[:space:]]+(/|~)([[:space:]]|$)'
    DANGEROUS_PATTERNS="$DANGEROUS_PATTERNS"'|shutdown|reboot'
    if printf '%s' "$cmd" | grep -qE "$DANGEROUS_PATTERNS"; then
        echo -e "${RED}blocked: dangerous pattern detected.${NC}"
        exit 1
    fi

    echo -e "${GREEN}==================== explanation ====================${NC}"
    echo -e "${NC}$explanation${NC}"
    echo -e "${GREEN}==================== command     ====================${NC}"
    echo -e "${YELLOW}$cmd${NC}"
    echo -e "${GREEN}====================================================${NC}"

    read -p "run this command? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}running: $cmd${NC}"
        local output; output=$(eval "$cmd" < /dev/null 2>&1)
        if [[ -z "$output" ]]; then
            echo -e "${YELLOW}the command finished but produced no output.${NC}"
        else
            echo -e "${GREEN}output:${NC}"
            echo "$output"
        fi
        # Record what the command *produced*, not just what was run. Without the
        # output, a follow-up like "move it to ~/" is unanswerable: the model
        # knows the command it issued but not the path that came back, so it
        # guesses. Truncated, because this goes back into a 4096-token context.
        local brief
        brief=$(printf '%s' "$output" | head -c "${HISTORY_OUTPUT_CHARS:-600}" | tr '\n' ' ')
        save_context "$user_prompt" "ran: $cmd | output: ${brief:-<no output>}"
    else
        echo -e "${CYAN}cancelled.${NC}"
    fi
}

main "$@"
