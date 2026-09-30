#!/data/data/com.termux/files/usr/bin/bash
# install.sh — install termux-harness on this device.
#
# Does four things:
#   1. Rewrite each script's shebang to the real $PREFIX (Termux has no
#      /bin/bash and no /usr/bin/env)
#   2. Create ~/.agent/ and plugins/, and generate config.sh from
#      config.example.sh (never overwrites an existing one)
#   3. Point ~/.agent/agent.sh at this repo's implementation, so there is only
#      one copy of the code that can drift
#   4. Mark the scripts executable and check dependencies
#
# Safe to run repeatedly (idempotent).

set -uo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="${AGENT_DIR:-$HOME/.agent}"
BASH_BIN="$PREFIX/bin/bash"

c_ok()   { printf '\033[0;32m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[0;31m%s\033[0m\n' "$*"; }

c_ok "installing termux-harness"
echo "   repo  : $REPO_DIR"
echo "   agent : $AGENT_DIR"
echo "   bash  : $BASH_BIN"

[ -x "$BASH_BIN" ] || { c_err "no $BASH_BIN, set PREFIX"; exit 1; }

# ---- 1. shebangs ------------------------------------------------------------
for f in "$REPO_DIR/agent.sh" "$REPO_DIR/start-llama-server.sh" "$REPO_DIR/install.sh"; do
    [ -f "$f" ] || continue
    if head -1 "$f" | grep -q '^#!.*bash'; then
        # temp file + mv rather than `sed -i`: works with both busybox and GNU sed
        sed "1s|^#!.*bash.*|#!$BASH_BIN|" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
        chmod +x "$f"
        echo "   shebang -> $BASH_BIN  ($(basename "$f"))"
    fi
done

# ---- 2. ~/.agent ------------------------------------------------------------
mkdir -p "$AGENT_DIR/plugins"

if [ ! -f "$AGENT_DIR/config.sh" ]; then
    cp "$REPO_DIR/config.example.sh" "$AGENT_DIR/config.sh"
    c_ok "   wrote $AGENT_DIR/config.sh"
else
    c_warn "   $AGENT_DIR/config.sh exists, left alone"
fi

if [ -f "$REPO_DIR/plugins/example.sh" ] && [ ! -f "$AGENT_DIR/plugins/example.sh" ]; then
    cp "$REPO_DIR/plugins/example.sh" "$AGENT_DIR/plugins/example.sh"
    c_ok "   installed the example plugin into $AGENT_DIR/plugins/"
fi

[ -f "$AGENT_DIR/history.txt" ] || : > "$AGENT_DIR/history.txt"

# ---- 3. ~/.agent/agent.sh forwards to this repo -----------------------------
# One implementation only, so the repo copy and the ~/.agent copy cannot drift.
if [ -f "$AGENT_DIR/agent.sh" ] && ! grep -q 'termux-harness/agent.sh' "$AGENT_DIR/agent.sh" 2>/dev/null; then
    cp "$AGENT_DIR/agent.sh" "$AGENT_DIR/agent.sh.pre-llama.bak"
    c_warn "   backed up the previous agent.sh as agent.sh.pre-llama.bak"
fi
cat > "$AGENT_DIR/agent.sh" <<WRAPEOF
#!/data/data/com.termux/files/usr/bin/bash
# Forwards to the single implementation in termux-harness, so the two cannot drift.
# The previous version is kept alongside as agent.sh.pre-llama.bak
exec bash "$REPO_DIR/agent.sh" "\$@"
WRAPEOF
chmod +x "$AGENT_DIR/agent.sh"
c_ok "   ~/.agent/agent.sh -> $REPO_DIR/agent.sh"

# ---- 4. dependency check ----------------------------------------------------
echo
c_ok "checking dependencies"
miss=0
for t in curl python3 git; do
    if command -v "$t" >/dev/null 2>&1; then
        echo "   ok  $t"
    else
        echo "   MISSING $t -> pkg install $t"
        miss=1
    fi
done
# Not checked above because only tests/integration.sh needs it, and it falls back
# gracefully when absent.
command -v timeout >/dev/null 2>&1 && echo "   ok  timeout" \
    || c_warn "   no timeout (coreutils) — tests/integration.sh will run without a hard cap"

LLAMA_BIN="${LLAMA_BIN:-$HOME/llama.cpp/build/bin/llama-server}"
if [ -x "$LLAMA_BIN" ]; then
    echo "   ok  llama-server: $LLAMA_BIN"
else
    c_warn "   no llama-server at $LLAMA_BIN"
    c_warn "     build first: cmake -B build -DGGML_VULKAN=ON && cmake --build build -j2"
    c_warn "     or set LLAMA_BIN to an existing binary"
fi

MODEL="${MODEL:-$HOME/qwen2.5-coder-7b.gguf}"
if [ -f "$MODEL" ]; then
    echo "   ok  model: $MODEL ($(du -hL "$MODEL" 2>/dev/null | cut -f1))"
else
    c_warn "   no model at $MODEL"
fi

echo
[ "$miss" -eq 0 ] && c_ok "done. start it with: bash $REPO_DIR/start-llama-server.sh" \
                  || c_err "dependencies missing, install them before running"
