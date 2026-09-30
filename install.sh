#!/data/data/com.termux/files/usr/bin/bash
# install.sh — 把 termux-harness 装到本机
#
# 做三件事：
#   1. 按真实的 $PREFIX 修正脚本 shebang（Termux 没有 /bin/bash 和 /usr/bin/env）
#   2. 建好 ~/.agent/ 与 plugins/，并从 config.example.sh 生成 config.sh（已存在则不覆盖）
#   3. 赋可执行权限
#
# 可重复执行（幂等）。

set -uo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="${AGENT_DIR:-$HOME/.agent}"
BASH_BIN="$PREFIX/bin/bash"

c_ok()   { printf '\033[0;32m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[0;31m%s\033[0m\n' "$*"; }

c_ok "▶️  安装 termux-harness"
echo "   仓库目录 : $REPO_DIR"
echo "   Agent 目录: $AGENT_DIR"
echo "   bash     : $BASH_BIN"

[ -x "$BASH_BIN" ] || { c_err "❌ 找不到 $BASH_BIN，请设置 PREFIX"; exit 1; }

# ---- 1. 修正 shebang --------------------------------------------------------
for f in "$REPO_DIR/agent.sh" "$REPO_DIR/start-llama-server.sh" "$REPO_DIR/install.sh"; do
    [ -f "$f" ] || continue
    if head -1 "$f" | grep -q '^#!.*bash'; then
        # 用 sed -i 的临时文件写法，兼容 busybox/GNU 两种 sed
        sed "1s|^#!.*bash.*|#!$BASH_BIN|" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
        chmod +x "$f"
        echo "   ✓ shebang → $BASH_BIN  ($(basename "$f"))"
    fi
done

# ---- 2. ~/.agent 目录 -------------------------------------------------------
mkdir -p "$AGENT_DIR/plugins"

if [ ! -f "$AGENT_DIR/config.sh" ]; then
    cp "$REPO_DIR/config.example.sh" "$AGENT_DIR/config.sh"
    c_ok "   ✓ 已生成 $AGENT_DIR/config.sh"
else
    c_warn "   · $AGENT_DIR/config.sh 已存在，保持不变"
fi

if [ -f "$REPO_DIR/plugins/example.sh" ] && [ ! -f "$AGENT_DIR/plugins/example.sh" ]; then
    cp "$REPO_DIR/plugins/example.sh" "$AGENT_DIR/plugins/example.sh"
    c_ok "   ✓ 已安装示例插件到 $AGENT_DIR/plugins/"
fi

[ -f "$AGENT_DIR/history.txt" ] || : > "$AGENT_DIR/history.txt"

# ---- 2b. 让 ~/.agent/agent.sh 转发到本仓库（备份原 Ollama 版）---------------
# 只保留一份实现，避免仓库版与 ~/.agent 版漂移。
if [ -f "$AGENT_DIR/agent.sh" ] && ! grep -q 'termux-harness/agent.sh' "$AGENT_DIR/agent.sh" 2>/dev/null; then
    cp "$AGENT_DIR/agent.sh" "$AGENT_DIR/agent.sh.pre-llama.bak"
    c_warn "   · 原 agent.sh（Ollama 版）已备份为 agent.sh.pre-llama.bak"
fi
cat > "$AGENT_DIR/agent.sh" <<WRAPEOF
#!/data/data/com.termux/files/usr/bin/bash
# 转发到 termux-harness 的唯一实现，避免两份代码漂移。
# 原 Ollama 版备份在同目录 agent.sh.pre-llama.bak
exec bash "$REPO_DIR/agent.sh" "\$@"
WRAPEOF
chmod +x "$AGENT_DIR/agent.sh"
c_ok "   ✓ ~/.agent/agent.sh → $REPO_DIR/agent.sh"

# ---- 3. 依赖自检 ------------------------------------------------------------
echo
c_ok "▶️  依赖自检"
miss=0
for t in curl python3 git; do
    if command -v "$t" >/dev/null 2>&1; then
        echo "   ✓ $t"
    else
        echo "   ✗ $t 缺失 → pkg install $t"
        miss=1
    fi
done

LLAMA_BIN="${LLAMA_BIN:-$HOME/llama.cpp/build/bin/llama-server}"
if [ -x "$LLAMA_BIN" ]; then
    echo "   ✓ llama-server: $LLAMA_BIN"
else
    c_warn "   ! 未找到 llama-server: $LLAMA_BIN"
    c_warn "     请先编译：cmake -B build -DGGML_VULKAN=ON && cmake --build build -j2"
    c_warn "     或设置 LLAMA_BIN 指向已编译的二进制"
fi

MODEL="${MODEL:-$HOME/qwen2.5-coder-7b.gguf}"
if [ -f "$MODEL" ]; then
    echo "   ✓ 模型: $MODEL ($(du -hL "$MODEL" 2>/dev/null | cut -f1))"
else
    c_warn "   ! 未找到模型: $MODEL"
fi

echo
[ "$miss" -eq 0 ] && c_ok "✅ 安装完成。启动：bash $REPO_DIR/start-llama-server.sh" \
                  || c_err "⚠️  有依赖缺失，先装完再跑"
