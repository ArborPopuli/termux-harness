# plugins/example.sh — plugin template
#
# A plugin is a bash fragment that gets sourced, invoked with /name:
#     bash agent.sh /example arg1 arg2
#
# Inside a plugin, $@ holds the arguments, and agent.sh's exported variables are
# available: $AGENT_DIR  $API_BASE  $MODEL
#
# Note: plugins run in the same shell as agent.sh, so they can change its
# variables too.

set -uo pipefail

echo "example plugin loaded"
echo "   argc   : $#"
echo "   argv   : $*"
echo "   endpoint: ${API_BASE:-<unset>}"
echo "   agent dir: ${AGENT_DIR:-<unset>}"

# A plugin can also talk to the model directly (OpenAI-compatible shape)
# resp=$(curl -s -X POST "$API_BASE/v1/chat/completions" \
#     -H 'Content-Type: application/json' \
#     -d '{"messages":[{"role":"user","content":"Describe Termux in one sentence"}],"max_tokens":64}')
# echo "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["content"])'
