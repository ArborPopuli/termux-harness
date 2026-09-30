#!/data/data/com.termux/files/usr/bin/bash
# agent.sh — Termux 端轻量 Agent Harness
#
# 由本地 llama.cpp (llama-server) 驱动，OpenAI 兼容端点。
# 默认使用 Qwen2.5-Coder-7B + Vulkan GPU 加速（Adreno）。
#
# 用法：
#   bash agent.sh "找出 Download 目录下最近 3 天的 jpg"
#   bash agent.sh /<plugin> [args]        执行插件
#
# 配置：~/.agent/config.sh（可选，见 config.example.sh）

set -uo pipefail

AGENT_DIR="${AGENT_DIR:-$HOME/.agent}"
PLUGIN_DIR="$AGENT_DIR/plugins"
HISTORY_FILE="$AGENT_DIR/history.txt"
LAUNCHER="${LAUNCHER:-$HOME/termux-harness/start-llama-server.sh}"

# ---- 默认配置（可被 ~/.agent/config.sh 覆盖）---------------------------------
MODEL="${MODEL:-qwen2.5-coder-7b}"
API_HOST="${API_HOST:-127.0.0.1}"
API_PORT="${API_PORT:-8080}"
MAX_TOKENS="${MAX_TOKENS:-256}"
TEMPERATURE="${TEMPERATURE:-0.2}"
HISTORY_TURNS="${HISTORY_TURNS:-6}"
# -----------------------------------------------------------------------------

[ -f "$AGENT_DIR/config.sh" ] && . "$AGENT_DIR/config.sh"
API_BASE="http://${API_HOST}:${API_PORT}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'

SYSTEM_PROMPT="你是一个运行在Android Termux环境下的终端助手。
你的回答必须严格分为两部分：
第一部分【思路】：用简单易懂的中文解释你打算怎么做（不超过3句话）。
第二部分【命令】：给出可以直接执行的单行Shell命令，必须用 [CMD] 和 [/CMD] 包裹。
例如：[CMD]find /storage/emulated/0/ -iname '*.jpg' -mtime -3[/CMD]
绝对不要输出任何多余的文字、Markdown代码块或其他标记。
其他规则：
1. 专注文件检索与系统操作，不做任何数学题。
2. 默认搜索路径为 /storage/emulated/0/。
3. 严禁生成任何需要等待用户输入的命令。"

# 确保 llama-server 在跑（替代原先的 check_ollama）
ensure_server() {
    if curl -sf -m 3 "$API_BASE/health" >/dev/null 2>&1; then
        return 0
    fi
    echo -e "${YELLOW}⚠️  本地模型服务未运行，正在拉起 llama-server（Vulkan GPU）...${NC}"
    if [ -x "$LAUNCHER" ]; then
        bash "$LAUNCHER" || { echo -e "${RED}❌ llama-server 启动失败，见 $AGENT_DIR/llama-server.log${NC}"; return 1; }
    else
        echo -e "${RED}❌ 找不到启动脚本：$LAUNCHER${NC}"; return 1
    fi
}

get_context() {
    if [[ -f "$HISTORY_FILE" ]]; then tail -n "$HISTORY_TURNS" "$HISTORY_FILE"; else echo ""; fi
}

save_context() {
    echo "用户: $1" >> "$HISTORY_FILE"
    echo "助手: $2" >> "$HISTORY_FILE"
    tail -n "$HISTORY_TURNS" "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
}

# 用 python3 构造 JSON —— 避免在 bash 里手工转义引号/换行/中文
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
    payload=$(build_payload "$SYSTEM_PROMPT" "--- 历史对话 ---
$context
--- 历史结束 ---

用户新需求：$1")
    resp=$(curl -s -m 600 -X POST "$API_BASE/v1/chat/completions" \
                -H 'Content-Type: application/json' -d "$payload")
    if [ -z "$resp" ]; then echo "__API_ERROR__ 空响应（服务可能已崩溃）"; return; fi
    content=$(printf '%s' "$resp" | parse_content)
    printf '%s' "$content"
}

run_plugin() {
    local plugin_name="$1"; shift
    local plugin_file="$PLUGIN_DIR/${plugin_name}.sh"
    if [[ -f "$plugin_file" ]]; then
        echo -e "${CYAN}🔌 加载插件: $plugin_name${NC}"
        source "$plugin_file" "$@"
    else
        echo -e "${YELLOW}⚠️ 插件 $plugin_name 不存在。可用插件：${NC}"
        ls -1 "$PLUGIN_DIR" 2>/dev/null | sed 's/\.sh$//' | awk '{print "  - /"$1}'
    fi
}

main() {
    if [[ $# -eq 0 ]]; then echo -e "用法：$0 \"你的需求\""; exit 1; fi
    if [[ "$1" == /* ]]; then run_plugin "${1:1}" "${@:2}"; exit 0; fi

    ensure_server || exit 1

    local user_prompt="$*"
    echo -e "${CYAN}🧠 思考中 (模型: $MODEL @ $API_BASE)...${NC}"
    local raw_response; raw_response=$(generate_response "$user_prompt")

    if [[ "$raw_response" == __API_ERROR__* || "$raw_response" == __PARSE_ERROR__* ]]; then
        echo -e "${RED}❌ 模型服务返回错误：${NC}"
        echo "$raw_response"
        exit 1
    fi

    # 严格提取 [CMD]...[/CMD]
    local cmd; cmd=$(echo "$raw_response" | sed -n 's/.*\[CMD\]//;s/\[\/CMD\].*//p' | tr -d '\r')
    local explanation; explanation=$(echo "$raw_response" | sed 's/\[CMD\].*//g' | tr -d '\r' | xargs)

    if [[ -z "$cmd" ]]; then
        echo -e "${RED}❌ 模型未按规定格式输出 [CMD]命令[/CMD]。${NC}"
        echo -e "${YELLOW}原始回复：$raw_response${NC}"
        exit 1
    fi

    # 安全检查 1：命令必须是纯 ASCII
    if echo "$cmd" | LC_ALL=C grep -q '[^ -~]'; then
        echo -e "${RED}❌ 拦截：生成的命令中包含非 ASCII 字符（可能是中文）。${NC}"
        exit 1
    fi

    # 安全检查 2：高危指令
    DANGEROUS_PATTERNS="rm -rf /|rm -rf ~|mkfs|dd if=|dd of=/dev/|chmod -R 777 /|shutdown|reboot"
    if echo "$cmd" | grep -qE "$DANGEROUS_PATTERNS"; then
        echo -e "${RED}🚨 高危警告：检测到危险指令，已拦截！${NC}"
        exit 1
    fi

    echo -e "${GREEN}==================== 思路与解释 ====================${NC}"
    echo -e "${NC}$explanation${NC}"
    echo -e "${GREEN}==================== 生成的命令 ====================${NC}"
    echo -e "${YELLOW}$cmd${NC}"
    echo -e "${GREEN}====================================================${NC}"

    read -p "是否执行该命令？(y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}🚀 正在执行：$cmd${NC}"
        local output; output=$(eval "$cmd" < /dev/null 2>&1)
        if [[ -z "$output" ]]; then
            echo -e "${YELLOW}💡 命令执行完毕，但没有产生任何输出。${NC}"
        else
            echo -e "${GREEN}✅ 执行结果：${NC}"
            echo "$output"
        fi
        save_context "$user_prompt" "思路: $explanation | 执行了: $cmd"
    else
        echo -e "${CYAN}🚫 已取消。${NC}"
    fi
}

main "$@"
