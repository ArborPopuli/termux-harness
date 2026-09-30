#!/data/data/com.termux/files/usr/bin/bash
# Integration test for termux-harness
BASE="http://127.0.0.1:8080"

echo "########## 1. /health ##########"
curl -s -m 10 "$BASE/health"; echo

echo
echo "########## 2. /v1/models ##########"
curl -s -m 10 "$BASE/v1/models" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for m in d.get("data",[]): print("  model id:", m.get("id"))
' 2>&1

echo
echo "########## 3. raw /v1/chat/completions ##########"
PAYLOAD=$(python3 - <<'PY'
import json
print(json.dumps({
 "messages":[
   {"role":"system","content":"你是一个终端命令生成器。只输出 [CMD]命令[/CMD]，不要任何解释。"},
   {"role":"user","content":"列出主目录下最近修改的5个python文件"}],
 "max_tokens":128,"temperature":0.2,"stream":False}, ensure_ascii=False))
PY
)
curl -s -m 300 -X POST "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d "$PAYLOAD" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("  content:", repr(d["choices"][0]["message"]["content"]))
print("  usage  :", d.get("usage"))
' 2>&1

echo
echo "########## 4. full harness (agent.sh, answer=no) ##########"
echo "n" | timeout 400 bash "$HOME/termux-harness/agent.sh" "列出主目录下最近修改的5个python文件" 2>&1 | tail -20

echo
echo "########## 5. harness via ~/.agent/agent.sh wrapper ##########"
echo "n" | timeout 400 bash "$HOME/.agent/agent.sh" "统计主目录下有多少个 .py 文件" 2>&1 | tail -12

echo
echo "########## 6. plugin dispatch ##########"
bash "$HOME/termux-harness/agent.sh" /example a b 2>&1 | tail -8

echo
echo "########## 7. server status ##########"
bash "$HOME/termux-harness/start-llama-server.sh" --status 2>&1
