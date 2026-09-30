# config.example.sh — 复制为 ~/.agent/config.sh 后按需修改
#
# agent.sh 与 start-llama-server.sh 都会读取这里导出的变量。
# 这个文件被 .gitignore 忽略（config.sh），避免把本地路径/端口提交上去。

# ---- 模型服务（agent.sh 用）------------------------------------------------
API_HOST="127.0.0.1"
API_PORT="8080"
MODEL="qwen2.5-coder-7b"

# 生成参数：终端命令生成任务建议低温度。
# 注意：CPU 侧实测约 10 t/s（tg），max_tokens 越大等待越久。
MAX_TOKENS="256"
TEMPERATURE="0.2"

# 注入到提示词里的历史轮数（行数）
HISTORY_TURNS="6"

# ---- llama-server 启动器（start-llama-server.sh 用）------------------------
# GPU 卸载档位阶梯：先试全量，失败自动降级。
#   -ngl 99 → 28 层全上 Adreno（需约 4.2 GiB 显存）
#   -ngl 30 → 内存吃紧时的安全档
#   -ngl 0  → 兜底纯 CPU
NGL_LADDER="99 30 0"

# 上下文长度。7B 下 4096 约需 448 MiB KV cache。
CTX="4096"

# 就绪等待上限（秒）。首次把 4.3 GiB 权重搬进显存较慢。
HEALTH_TIMEOUT="240"
