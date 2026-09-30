# config.example.sh — copy to ~/.agent/config.sh and edit as needed
#
# Both agent.sh and start-llama-server.sh read this file.
# `config.sh` is gitignored so your local paths and ports stay out of the repo.

# ---- model server (used by agent.sh) ---------------------------------------
API_HOST="127.0.0.1"
API_PORT="8080"
MODEL="qwen2.5-coder-7b"

# Generation parameters. Low temperature suits terminal-command generation.
# Note: measured at roughly 10 t/s (tg) on the CPU path, so a large max_tokens
# means a long wait.
MAX_TOKENS="256"
TEMPERATURE="0.2"

# Language the agent is told to write its explanation half in.
# The command half is always English shell. Set to "en" for English replies.
REPLY_LANG="zh"

# History injected into the prompt, counted in LINES (2 lines per exchange).
HISTORY_TURNS="6"

# How much of each command's OUTPUT is kept in the history. The model needs it:
# without it, "move it to ~/" cannot be resolved, because the reply that named
# the path was never shown. Truncated so the history still fits the context.
HISTORY_OUTPUT_CHARS="600"

# ---- llama-server launcher (used by start-llama-server.sh) -----------------
# GPU offload ladder: try full offload first, degrade automatically on failure.
#   -ngl 99 → all 29 blocks on the Adreno (needs ~4.2 GiB of shared memory)
#   -ngl 30 → safe step when memory is tight
#   -ngl 0  → CPU only, the fallback
NGL_LADDER="99 30 0"

# Context length. At 7B, 4096 needs about 448 MiB of KV cache.
CTX="4096"

# Readiness timeout in seconds. The first load moves 4.3 GiB of weights into
# device memory, which is slow.
HEALTH_TIMEOUT="240"
