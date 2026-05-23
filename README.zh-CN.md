# ccg — 代码分歧检测器

> Claude Code 的 slash command。装一次，在 diff 上输入 `/ccg`。

[![Tests](https://img.shields.io/badge/tests-99%20passing-brightgreen.svg)]()
[![npm](https://img.shields.io/npm/v/@mcgrapeng/ccg.svg)](https://www.npmjs.com/package/@mcgrapeng/ccg)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[English](README.md) ｜ **简体中文** ｜ [日本語](README.ja.md) ｜ [한국어](README.ko.md)　·　[架构文档 →](docs/ARCHITECTURE.md)

---

## ccg 是什么

ccg 让 **Codex（OpenAI）** 和 **Gemini（Google）** 并行评审同一份 diff，然后由 **Claude** 聚焦两者意见不一致的地方——这才是真正需要人来拍板的点。

大多数 AI 审查工具追求"共识"，ccg 反其道而行。一致 = 低信号，分歧 = 黄金。

## ccg 能做什么

ccg 给你三件单模型审查工具都给不了的东西：

**1. 一个不像 Claude 那样思考的第二意见。**
Codex 和 Gemini 训练数据不同，发现的问题也不同。当它们在 `auth/login.go` 的同一处改动上意见不一致时，那就是你该慢下来仔细看的地方。

**2. 内置成本可见性。**
Codex / Gemini CLI 都不告诉你花了多少钱。ccg 记录每次调用，按风险自动选最便宜的够用模型（风险路由），相同 prompt 24 小时内命中缓存零成本。

**3. 跨会话保留的评审历史。**
"两周前模型对 `src/auth.ts` 说了什么？"——ccg 的 append-only 账本能回答。任何无状态工具都做不到。

## 怎么安装

二选一：

```bash
# npm（推荐）
npx @mcgrapeng/ccg install

# 或 curl 一行装，无需 Node
curl -fsSL https://raw.githubusercontent.com/mcgrapeng/ccg/main/scripts/curl-install.sh | bash
```

再装两个 AI CLI（一次性）：

```bash
npm i -g @openai/codex @google/gemini-cli
echo 'export GEMINI_API_KEY="<你的-key>"' >> ~/.zshenv
```

验证：

```bash
npx @mcgrapeng/ccg doctor      # 检查 Codex / Gemini / API key
npx @mcgrapeng/ccg about       # 看 7 层能力 + 当前环境状态
```

## 怎么使用

在任意有改动的 git 仓库里，打开 Claude Code，输入：

```
/ccg
```

ccg 会自动：

1. 抓取当前 diff（worktree → staged → upstream → origin-head 四级回退）
2. 风险打分，自动选 `cost` / `balanced` / `quality` 模型
3. 并行调用 Codex + Gemini 评同一份 prompt
4. 综合成三段输出：

```
═══ AGREEMENT (N)  ═══   两边都标记 —— 低信号，一行带过
═══ DIVERGENCE (M) ═══   ★ ccg 的核心价值
                          - Codex 说 X
                          - Gemini 说 Y
                          - Claude 综合判断：___ 或 NEEDS HUMAN DECISION
═══ BLINDSPOT (≤2) ═══  两边都没看见 Claude 怀疑 —— 慎用
═══ VERDICT ═══         merge / fix-required / discuss
```

然后 `ccg_ledger_record` 记一行 JSONL。`ccg_cleanup` 清理 workdir。

## 配置（默认值通常够用）

模式和模型都是自动的���需要时再覆盖：

```bash
CCG_MODE=quality /ccg          # 任意 diff 都强制 quality 模型
CCG_CODEX_MODEL=o3 /ccg        # 单独换某个模型
CCG_NO_CACHE=1 /ccg            # 本次跳过 24h 缓存
```

所有配置在 [架构文档 § 5 扩展点](docs/ARCHITECTURE.md#5-extension-points)。常用：

| 变量 | 默认 | 用途 |
|---|---|---|
| `CCG_MODE` | `auto` | `auto` / `cost` / `balanced` / `quality` |
| `CCG_CACHE_TTL_HOURS` | `24` | 缓存 TTL |
| `CCG_MAX_PROMPT_KB` | `100` | 单次 prompt 大小硬上限 |

成本参考（USD / 次，缓存命中 $0）：

| 模式 | Codex | Gemini | 单次典型 |
|---|---|---|---|
| `cost`     | gpt-5-nano  | gemini-2.5-flash-lite | ~$0.0007 |
| `balanced` | gpt-5-mini  | gemini-2.5-flash      | ~$0.0046 |
| `quality`  | gpt-5       | gemini-2.5-pro        | ~$0.0440 |

随时查累计：

```bash
source ~/.claude/commands/ccg.sh
ccg_usage --this-month
```

## 不适合的场景

- Claude Code 之外的 IDE（试试 [zen-mcp-server](https://github.com/BeehiveInnovations/zen-mcp-server)）
- 替代静态分析（要配合 Semgrep / CodeQL 用）
- 每个 PR 自动跑（ccg 是分诊工具，不是机器人）
- 流式输出或多轮对话

## 架构与贡献

ccg 一共 **7 层**，"分歧检测"只是最上面一层。下面 6 层（缓存、账本、用量、风险路由、智能 diff、安全 CLI 调度）各自独立解决真问题。改 `ccg.sh` 之前先读 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

测试：

```bash
bash tests/test_ccg.sh                # 99 个回归测试，~31s
REAL_CLI=1 bash tests/test_ccg.sh     # +2 个真实 API 测试（会扣费）
```

## 许可证与致谢

MIT —— 见 [LICENSE](LICENSE)。

基于 [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) 最初的 `/ccg` 概念 · Claude Code · OpenAI Codex CLI · Google Gemini CLI。
