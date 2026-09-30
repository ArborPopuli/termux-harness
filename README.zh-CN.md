# termux-harness

**一份 Android 上 llama.cpp Vulkan GPU 卸载的实测报告 —— 外加一个即插即用的 Termux 本地 Agent harness。**

[English](README.md) · [实测数据](docs/MEASUREMENTS.md) ·
[更正登记](docs/CORRECTIONS.md) · [Termux 踩坑](docs/TERMUX-GOTCHAS.md)

---

## 短版

我们把 **Qwen2.5-Coder-7B Q4_K_M** 全量卸载到了 **Adreno 830** 上,
走 llama.cpp 的 Vulkan 后端,在手机 Termux 里跑。然后认真测了它。

| | CPU (`-ngl 0`) | GPU (`-ngl 99`) | 差异 |
|---|---|---|---|
| 提示处理 (pp64) | 37.10 ± 0.48 t/s | **45.76 ± 0.02 t/s** | **+23%** |
| 生成 (tg32) | 9.86 ± 1.07 t/s | **9.31 ± 0.12 t/s** | **−6%** |
| **96 token 的 CPU 时间** | **33 CPU-秒** | **5 CPU-秒** | **降至 1/6.6** |

`llama-bench -r 3`,两次独立运行结果一致([原始输出](bench/raw/))。

**GPU 上生成反而更慢。** 提示处理更快。但这两个都不是重点。

重点是最后一行:**CPU 的周期被还回来了。**
手机上稀缺的从来不是算力,而是**与前台共存的能力** —— 散热余量、电池、还能响应的界面。
把矩阵乘挪到 GPU 换来的是这个,不是 tokens/sec。我们不会假装它是后者。

### 为什么生成没变快

```
ggml_vulkan: 0 = Adreno (TM) 830 (turnip Mesa driver) | uma: 1 | fp16: 1 | bf16: 0
              | fp4: 0 | warp size: 64 | shared memory: 32768
              | int dot: 0 | matrix cores: none
```

`matrix cores: none`、`int dot: 0`。开源 **Turnip** 驱动**没有向应用暴露**
Adreno 的矩阵/张量单元和整数点积指令,ggml 因此拿不到 cooperative-matrix 路径,
只能退回标量着色器。而 token 生成本来就是内存带宽受限的,这颗 CPU 又有 `i8mm` + `dotprod` 可用。

这不是编译错误,也不是后端配错。**这是该硬件上开源栈当前的天花板。**
如果你的 Turnip 暴露了 `matrix cores`,同样配置会有明显更好的数字。

---

## 包里有什么

| | |
|---|---|
| `agent.sh` | 轻量 Agent 循环:自然语言 → `[CMD]…[/CMD]` → 人工确认 → 执行 |
| `start-llama-server.sh` | 拉起 `llama-server`,带 `99 → 30 → 0` 的卸载阶梯,分配失败自动降级 |
| `install.sh` | 幂等安装;按你的 `$PREFIX` 修正 shebang;建好 `~/.agent/` |
| `bench/run-bench.sh` | 复现本 README 里**每一个数字**,输出到 `bench/raw/*.txt` |
| `tests/integration.sh` | 端到端自测(健康检查/补全/harness/插件) |
| `docs/` | 实测数据、更正登记、以及那些吃掉我们数小时的 Termux/Android 坑 |

**不依赖 Ollama。不需要 `jq`**(目标机上没装,JSON 用 `python3` 处理)。
只用 `curl`、`python3`、`bash`、`git`。

---

## 环境要求

- Termux,已装 `git curl python3`
  ```sh
  pkg install git curl python3
  ```
- 带 **Vulkan 后端**编译的 llama.cpp:
  ```sh
  pkg install shaderc spirv-headers        # glslc 在 shaderc 里，不在 glslang 里
  cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
  cmake --build build -j2
  ```
  > 内存吃紧的手机上 `-j8` 是个让编译被系统杀掉的好办法。
- 一个 GGUF 模型,例如 `~/qwen2.5-coder-7b.gguf`

---

## 安装

```sh
git clone <本仓库地址> ~/termux-harness
cd ~/termux-harness
bash install.sh
```

## 使用

```sh
# 启动服务（首次要把约 4.2 GiB 权重搬进显存）
bash ~/termux-harness/start-llama-server.sh

# 提问
bash ~/termux-harness/agent.sh "找出 Download 目录下最近 3 天的 jpg"
```

服务管理:

```sh
bash start-llama-server.sh --status
bash start-llama-server.sh --stop
```

服务在 `127.0.0.1:8080` 上说的是 **OpenAI chat-completions 协议**,
所以任何能对接 OpenAI 的东西都能指向它。本 harness 只是其中一个客户端。

---

## 这个项目不是什么

- **不是提速宣称。** 看表。生成是变慢的。
- **不是沙箱。** `agent.sh` 会执行模型写出的 shell。每条命令都需人工确认,
  另有 ASCII 检查和高危指令黑名单 —— 但那是**字符串匹配,不是安全边界**。
  只在你愿意交给语言模型的机器上跑。
- **不是新的推理引擎。** 就是 llama.cpp,为手机接好了线。
- **不是严谨的基准科学。** n = 2 次运行、未控制温度状态、而且这台设备的
  负载均值一直在 ~21(来自我们看不见的进程)。详见
  [MEASUREMENTS.md](docs/MEASUREMENTS.md) 末尾的局限说明。

---

## 即使不看代码,也值得看这两份

**[docs/CORRECTIONS.md](docs/CORRECTIONS.md)** —— 我们斩钉截铁说过、后来被推翻的结论,
包括一次"单次未经验证的采样告诉我们 GPU 快 10 倍"、而重复测量给出相反答案。
保留它,是因为**失败模式比修复方法更有用**。

**[docs/TERMUX-GOTCHAS.md](docs/TERMUX-GOTCHAS.md)** —— 十个 Android/Termux 陷阱:
没有 `/bin/bash`、`/tmp` 是 `noexec`、`glslc` 与 `glslang` 的区别、
电池优化杀掉后台任务、两个 Vulkan ICD 其中一个是 CPU 软件光栅、
以及那条**把我们自己的 SSH 会话杀掉的 `pkill` 模式**。

---

## 测试设备

| | |
|---|---|
| 设备 | HONOR **AAK-AN00** |
| SoC | Qualcomm **SM8750**(骁龙 8 Elite),8 核 |
| GPU | **Adreno 830**,经 **Turnip**(Mesa) |
| 系统 | Android **16** (SDK 36),内核 6.6.118-android15 |
| 内存 | 11.2 GB + 12.3 GB swap |
| 模型 | Qwen2.5-Coder-7B **Q4_K_M**(4.36 GiB) |
| 构建 | llama.cpp `0.5.0-dev`,clang 21.1.8,Vulkan loader 1.4.364 |

---

## 许可

MIT —— 见 [LICENSE](LICENSE)。

## 欢迎贡献

最有价值的贡献是一个**反例测量**:不同硬件、不同 Turnip 版本,
或者一个暴露了 `matrix cores` 的 Turnip。
如果你的数字和我们的矛盾,那是一个结果,不是冲突。
