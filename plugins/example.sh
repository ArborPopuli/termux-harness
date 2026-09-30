# plugins/example.sh — 插件模板
#
# 插件就是一个被 source 进来的 bash 片段，通过 /名字 调用：
#     bash agent.sh /example 参数1 参数2
#
# 插件里可以直接用 $@ 拿到参数，也可以用 agent.sh 导出的环境变量：
#     $AGENT_DIR  $API_BASE  $MODEL
#
# 注意：插件运行在与 agent.sh 同一个 shell 里，所以能改它的变量。

set -uo pipefail

echo "🔌 example 插件已加载"
echo "   参数个数: $#"
echo "   参数内容: $*"
echo "   模型端点: ${API_BASE:-<未设置>}"
echo "   Agent 目录: ${AGENT_DIR:-<未设置>}"

# 插件也可以自己直接问模型（OpenAI 兼容格式）
# resp=$(curl -s -X POST "$API_BASE/v1/chat/completions" \
#     -H 'Content-Type: application/json' \
#     -d '{"messages":[{"role":"user","content":"用一句话介绍 Termux"}],"max_tokens":64}')
# echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["content"])'
