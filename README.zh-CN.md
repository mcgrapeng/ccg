# ccg — 代码分歧检测器

> 浮现 Codex 和 Gemini 在你 diff 上意见不一致的地方——那才是你需要拍板的地方。
> 
> Claude Code 的 slash command。装一次，在 diff 上输入 `/ccg`。

[![Tests](https://img.shields.io/badge/tests-111%20passing-brightgreen.svg)]()
[![npm](https://img.shields.io/npm/v/@mcgrapeng/ccg.svg)](https://www.npmjs.com/package/@mcgrapeng/ccg)
[![npm downloads](https://img.shields.io/npm/dm/@mcgrapeng/ccg.svg)](https://www.npmjs.com/package/@mcgrapeng/ccg)
[![GitHub stars](https://img.shields.io/github/stars/mcgrapeng/ccg.svg?style=social&label=Star)](https://github.com/mcgrapeng/ccg/stargazers)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[English](README.md) ｜ **简体中文** ｜ [日本語](README.ja.md) ｜ [한국어](README.ko.md)　·　[架构文档 →](docs/ARCHITECTURE.zh-CN.md)

---

## ccg 是什么

你刚改完 `auth/login.go`，准备 merge。你想"保险一下"再走。今天你只有三种选择，每种都有硬伤：

- **单模型 review**（Copilot、Cursor `/review`、Aider）只给**一种视角**。如果 Claude 漏看了 timing attack，你也会一起漏。
- **多模型聚合工具**（zen-mcp-server 等）把多个模型的意见**平均化**，恰好遮盖了它们意见分歧的地方——而那才是你真正需要思考的位置。
- **手工双查**理论上最稳，但你没那个时间。

ccg 是 Claude Code 的 `/ccg` slash command，针对这三件事都做了真正的解决：

1. 把同一个 prompt **并行**发给 **Codex（OpenAI）** 和 **Gemini（Google）**
2. 让 **Claude** 读完两份报告，**聚焦它们意见不一致的地方**——人需要拍板的就在那里
3. 自动按代码风险选最便宜够用的模型、记录每次调用成本、保留历史评审账本

**类比理解**：就像让两个不同团队的 senior 工程师 review 同一份 PR，再让一个 tech lead 综合："这几点他们都同意，这一点他们意见不一致——你来定，下面是我的看法。"

## ccg 的能力集（5 个核心功能）

1. **平行评审** — 同一个 prompt 同时发给 Codex 和 Gemini
2. **分歧检测** — Claude 浮现它们意见不一致的地方（不是一致的地方）
3. **风险感知路由** — 自动给 diff 评分，选 cost / balanced / quality 模式
4. **成本追踪** — 记录每次调用；24h 缓存让重复评审成本为零（$0.00）
5. **评审记忆** — 保存过去的评审；下一次评审自动注入历史，这样重复问题会浮现，不会在会话间蒸发

## 什么时候用 ccg

触发条件不是**领域**，而是**感觉**。当你看着自己刚写完的 diff，心里冒出下面这种念头，就是 ccg 的场景：

| 你心里在想 | 用 ccg？ |
|---|---|
| "这个改错了，我凌晨会被叫起来" | ✅ 用 |
| "这是个判断题，没有一定对的答案" | ✅ 用 |
| "我希望有第二个人帮我看一眼" | ✅ 用 |
| "我就是改了个变量名" | ❌ 不用 |
| "只改了文档" | ❌ 不用 |
| "我想跟单个模型流式对话" | ❌ 不用（直接用 CLI） |

**跨领域真实例子** —— 都不是 auth / 加密的场景，但都是"两个资深工程师真会吵起来"的瞬间：

- **社交平台** —— feed 排序换了新的互动信号 · 评论树 fan-out 策略 · A/B 实验分桶逻辑 · 反滥用限流策略 · 关注关系的图数据库 schema
- **数据 / AI 基建** —— 换 embedding 模型（向量库要不要重建？） · 改 chunking 策略 · RAG 检索打分 · prompt injection 防御分层
- **前端** —— 新页面用 SSR 还是 ISR 还是 RSC · 缓存失效策略 · 状态管理重构 · 可访问性取舍
- **API 设计** —— 分页用 cursor 还是 offset · 错误响应模型 · 版本管理策略 · 幂等性 key 处理
- **分布式系统** —— 超时 / 重试策略 · cache TTL vs 事件驱动失效 · 分区容忍度取舍 · leader election 语义
- **数据库** —— 多步迁移的拆分顺序 · 热点路径的索引选择 · 事务隔离级别 · 软删 vs 硬删
- **安全** —— 对，auth / 加密 / 支付也属于这类 —— 但只是众多领域之一

**判断标准**：任何一个"合理的工程师可能选 A、另一个合理的工程师可能选 B"的改动，就是分歧检测赚回 $0.04 的时刻。

## 为什么是 ccg（和其他工具的对比）

**1. 分歧才是信号，不是噪音。**
当 Codex 说"加上 `subtle.ConstantTimeCompare` 防 timing attack"，而 Gemini 说"bcrypt 自己就是恒定时间的，加包装是 cargo-cult"——**这才是你需要思考的地方**。别的工具会把这种冲突糊成一句模糊的"注意 timing 攻击"。ccg 把两边原话端给你。

**2. 内置成本可见性。**
Codex / Gemini CLI 都不告诉你花了多少钱。ccg 记录每次调用，按风险自动选最便宜够用的模型（risk-aware routing），相同 prompt 24h 内命中缓存零成本。典型花费：每次有意义的分歧检测 $0.02-0.15——一次资深工程师 code review 要花 $200-300 的时间成本。分歧检测在第一个有争议的 PR 就赚回成本。随时用 `ccg_usage --this-month` 查看累计。

**3. 跨会话保留的评审历史——*并喂给下一次评审*。**
"两周前模型对 `src/auth.ts` 说了什么？"——ccg 的 append-only 账本能回答。任何无状态工具都做不到。v3.2 起，过去触及同一文件的评审会自动注入下次 prompt。重复出现的问题会浮现出来，不再随 session 关闭蒸发。未解决的 `fix-required` 项也不会丢失。

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

## 分歧示例（ccg 抓住的常见模式）

分歧发生在各个领域，不只是安全。看看不同领域的分歧是什么样子的：

**加密/安全（经典）**
```
▸ auth/login.go:6 — bcrypt 哈希比较
  🔵 Codex：     "外包一层 subtle.ConstantTimeCompare 防 timing 攻击"
  🟢 Gemini：    "bcrypt 自身是恒定时间。外包是 cargo-cult"
  ⚖️ 决策方：你根据威胁模型来选择
```

**前端（缓存策略）**
```
▸ cache.ts:42 — 写时失效还是事件驱动失效？
  🔵 Codex：     "写时总是重验（可预测，更简单）"
  🟢 Gemini：    "事件订阅扩展更好；写时重验会导致缓存风暴"
  ⚖️ 决策方：你根据流量模式和 SLA 选择
```

**API 设计（分页）**
```
▸ pagination.go:18 — cursor 还是 offset 分页？
  🔵 Codex：     "offset 更简单，用户熟悉"
  🟢 Gemini：    "cursor O(1)，offset 删除时 O(n)；根据增长率选"
  ⚖️ 决策方：你根据数据变动频率和增长预测选择
```

这种分歧就是 ccg 赚回成本的地方。下面是完整的深度示例。

## 完整使用示例

假设你刚改了 `auth/login.go`：

```go
// 改前                                              // 改后
func Login(user, pw string) bool {                   func Login(user, pw string) bool {
    u := lookupUser(user)                                u := lookupUser(user)
-   return u.Hash == sha256.Sum256([]byte(pw))           hashed, err := bcrypt.GenerateFromPassword([]byte(pw), 12)
+                                                        if err != nil { return false }
+                                                        return subtle.ConstantTimeCompare(u.Hash, hashed) == 1
}
```

你在 Claude Code 输入：

```
/ccg
```

约 30 秒后你会看到——**真实输出示例**，不是占位符：

```
📍 范围：worktree · 1 个文件 · +4 -1 行
🎯 模式：quality  (风险=65 · auth+35 size>0+5 crypto-mention+25)
🩺 两个评审者都正常：Codex ✓ · Gemini ✓
💰 成本：$0.041

═══ AGREEMENT (2) — 两边都标记，信号弱 ═══
• auth/login.go:3 — sha256 不是密码哈希；换成 bcrypt 是对的
• auth/login.go:5 — bcrypt 错误要显式处理（你做了）

═══ DIVERGENCE (1) — 两个模型不一致 ★ 你来决定 ═══

▸ auth/login.go:6 — 怎么比较 bcrypt 哈希
  🔵 Codex 说： "外包一层 subtle.ConstantTimeCompare 防 timing 攻击，
                即使用了 bcrypt 也要加。"
  🟢 Gemini 说："bcrypt.CompareHashAndPassword 自身就是恒定时间的。
                外包一层是 cargo-cult，反而可能因为长度不一致 panic。"
  ⚖️ Claude 综合：Gemini 是对的。bcrypt.CompareHashAndPassword 才是
                标准比较方式；对它的原始输出做 ConstantTimeCompare 是
                根本性错误——你比较的是"刚 hash 的 pw"和"存储的 hash"，
                而 bcrypt 每次 hash 都用新的盐，所以直接比较永远返回 false。
  ➡️ 建议动作： 把 ConstantTimeCompare 那行替换为：
                `err := bcrypt.CompareHashAndPassword(u.Hash, []byte(pw))`
                `return err == nil`

═══ BLINDSPOT (1) — 两边都没看到 Claude 怀疑 ═══
• 错误处理路径：bcrypt 出错时返回 false 对调用方是对的，但是会静默吞掉
  基础设施错误（比如 bcrypt OOM）。建议加日志。

═══ VERDICT: fix-required ═══
当前比较逻辑会永远拒绝合法密码。按 DIVERGENCE 的建议改完 + 加错误日志，
就可以 merge 了。
```

### 怎么看懂这份输出

| 段落 | 是什么意思 | 你该怎么办 |
|---|---|---|
| **AGREEMENT** | Codex 和 Gemini 都标记的同一个问题。你单源用 Claude 也大概率能发现——**新信息量低**。 | 扫一眼，没改的就改。 |
| **DIVERGENCE** ★ | 两个模型意见不一致。**这才是 ccg 存在的真正原因。** Claude 的"建议动作"给你推荐，但你是最终拍板的人。 | 仔细读，接受 Claude 判断或自己覆盖。 |
| **BLINDSPOT** | 两个模型都没看到，但 Claude 综合时怀疑。**慎用**——每次最多 2 条。 | 当提示看，不是金科玉律。 |
| **VERDICT** | `merge` / `fix-required` / `discuss`。一句话结论。 | **当 merge 门禁用。** |

评审完，`ccg_ledger_record` 会写一行 JSONL 到账本。两周后你可以：

```bash
source ~/.claude/commands/ccg.sh
ccg_ledger_query "auth/login.go"
# → "auth/login.go: 3 次评审 · 最近 2026-05-23 (fix-required) · 2026-05-09 (merge) · 2026-04-28 (discuss)"
```

同一次评审还会保存为一份独立的 markdown 报告，写到仓库根目录下的 `.ccg/reports/<sha>_<utc-时间戳>.md`。Claude Code 一关，回头还能在仓库里直接翻出来，不用重跑。要关掉就 `CCG_NO_REPORT=1`；要换位置就 `CCG_REPORT_DIR=<路径>`。（建议把 `.ccg/` 加进 `.gitignore`，除非你想把报告也提交进 git。）

## 配置（默认值通常够用）

模式和模型都是自动的。需要时再覆盖：

```bash
CCG_MODE=quality /ccg          # 任意 diff 都强制 quality 模型
CCG_CODEX_MODEL=o3 /ccg        # 单独换某个模型
CCG_NO_CACHE=1 /ccg            # 本次跳过 24h 缓存
```

常用配置（全部在 [架构文档 § 5](docs/ARCHITECTURE.zh-CN.md#5-扩展点)）：

| 变量 | 默认 | 用途 |
|---|---|---|
| `CCG_MODE` | `auto` | `auto` / `cost` / `balanced` / `quality` |
| `CCG_CACHE_TTL_HOURS` | `24` | 缓存 TTL |
| `CCG_MAX_PROMPT_KB` | `100` | 单次 prompt 大小硬上限 |
| `CCG_NO_HISTORY` | `0` | 设为 `1` 禁用评审历史注入 |
| `CCG_HISTORY_MAX` | `3` | 注入历史的最大条数 |

成本参考（USD / 次，缓存命中 $0）：

| 模式 | Codex | Gemini | 单次典型 |
|---|---|---|---|
| `cost`     | gpt-5-nano  | gemini-2.5-flash-lite | ~$0.0007 |
| `balanced` | gpt-5-mini  | gemini-2.5-flash      | ~$0.0046 |
| `quality`  | gpt-5       | gemini-2.5-pro        | ~$0.0440 |

追踪支出：

```bash
source ~/.claude/commands/ccg.sh
ccg_usage --this-month     # 本月按 provider 分类
ccg_usage --all            # 累计
```

## 不适合的场景（范围边界）

ccg 是为高判断力 code review 专门设计的。*不是*以下的替代品：

- **静态分析** — 配合 Semgrep / CodeQL 用，不要替代
- **Linter 或代码格式化工具** — 那些抓风格；ccg 抓架构
- **自动化门禁** — ccg 是分诊工具，不是机器人（不要在每个 PR 上自动跑）
- **流式对话** — ccg 是一次性的；多轮对话用 Codex / Gemini CLI 直接用
- **非 Claude Code 的 IDE** — 试试 [zen-mcp-server](https://github.com/BeehiveInnovations/zen-mcp-server) 用于 VS Code / JetBrains

## 架构与贡献

ccg 一共 **7 层**，"分歧检测"只是最上面一层。下面 6 层（缓存、账本、用量、风险路由、智能 diff、安全 CLI 调度）各自独立解决真问题。改 `ccg.sh` 之前先读 [docs/ARCHITECTURE.zh-CN.md](docs/ARCHITECTURE.zh-CN.md)。

测试：

```bash
bash tests/test_ccg.sh                # 99 个回归测试，~31s
REAL_CLI=1 bash tests/test_ccg.sh     # +2 个真实 API 测试（会扣费）
```

## 许可证与致谢

MIT —— 见 [LICENSE](LICENSE)。

基于 [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) 最初的 `/ccg` 概念 · Claude Code · OpenAI Codex CLI · Google Gemini CLI。
