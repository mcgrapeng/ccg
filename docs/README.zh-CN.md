# CCG — Code Change Guardian

[![License](https://img.shields.io/badge/License-MIT-blue.svg)](../LICENSE)
[![Bash](https://img.shields.io/badge/Shell-Bash%203.2%2B-green.svg)]()
[![Models](https://img.shields.io/badge/Models-27%2B-purple.svg)]()

> **CCG（Code Change Guardian）** 是一套多模型代码评审与 Git 工作流守护系统。
> 两个独立的模型家族守护你代码的每次变更，从评审、提交、合并，到推送——完整四阶段工作流。

**其他语言**：[English](../README.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

---

## 目录

- [为什么用 CCG](#为什么用-ccg)
- [安装](#安装)
- [快速开始](#快速开始)
- [四阶段能力集](#四阶段能力集)
- [模型策略](#模型策略)
- [配置](#配置)
- [架构](#架构)
- [文档](#文档)

---

## 为什么用 CCG

| 痛点 | CCG 的解法 |
|---|---|
| 单模型评审有盲区 | 两个独立模型家族并行评审——浮现它们**不一致**的地方 |
| 一刀切的模型既浪费又不够用 | 风险感知自动路由：低风险用便宜的，关键代码用顶级的 |
| Merge 冲突繁琐且容易出错 | **AI 冲突解决（Bailian 主力）**——多重防护，绝不静默丢代码 |
| Push 决策缺少上下文 | Stage 4 在 push 前生成**图形化质量评分卡** |
| 评审无法复用 | JSONL ledger 记录每次评审，按路径可查 |

---

## 安装

### npm 安装（推荐）

```bash
npm install -g @mcgrapeng/ccg
```

### 从源码安装

```bash
git clone https://github.com/mcgrapeng/ccg.git
cd ccg
npm link
```

### 验证安装

```bash
ccg --version
ccg doctor        # 检查环境配置
ccg config        # 显示当前配置
ccg models        # 列出所有可用模型
```

**环境要求：**
- `bash 3.2+`、`git`、`curl`、`jq`
- Node.js >= 16

**配置 API 密钥（至少一个）：**
```bash
# 阿里云百炼（国内推荐，无需翻墙）
export BAILIAN_API_KEY="sk-xxxx"

# Anthropic Claude
export ANTHROPIC_API_KEY="sk-ant-xxxx"

# Google Gemini
export GEMINI_API_KEY="AIzaSy-xxxx"
```

---

## 快速开始

```bash
# 1. 评审当前改动
ccg review

# 2. 评审门禁通过后自动 commit
ccg commit "feat: 添加用户认证"

# 3. AI 冲突解决合并分支
ccg merge main

# 4. Push 前图形化分析 & 决策
ccg push origin main

# 辅助命令
ccg config           # 显示当前配置
ccg models           # 列出所有可用模型
```

---

## 四阶段能力集

CCG 围绕四个阶段构建，每个阶段都有明确的目的、模型策略和安全保证。

### Stage 1 — 代码评审（`ccg review`）

**目的**：发现 diff 中的 bug、安全问题和质量问题。

**模型策略**：
- **2 个模型并行**（默认 Codex + Bailian）
- 用户可通过 `CCG_PROVIDERS` 覆盖
- 模型由当前 `CCG_MODE` 决定（详见[模型策略](#模型策略)）

**输出**：合成结果分类为：
- `AGREEMENT` — 两个评审都标记相同问题（高置信度）
- `DIVERGENCE` — 评审者意见冲突（需要人类判断）
- `BLINDSPOT` — 一方漏掉了另一方发现的问题（最高价值）

**流水线**：
```
git diff → 风险评分 → 模式选择
   → 并行：[Codex 评审 + Bailian 评审]
   → 合成 → AGREEMENT | DIVERGENCE | BLINDSPOT
```

**安全保证**：
- Prompt injection 防御（不可信内容标记、每次调用独立 nonce）
- 大 diff 警告（>200KB 可能超过 context）
- Cleanup trap（Ctrl+C 杀子进程）
- 部分失败处理（1/2 成功 → 继续并警告）

---

### Stage 2 — 自动提交（`ccg commit`）

**目的**：只有通过评审的代码才进入 git 历史——**不做额外的 LLM 调用**。

**🚫 Stage 2 零 LLM 调用**——直接复用 Stage 1 的评审结果（synthesis verdict）。

**模型策略**：无。读取上一步的 `.git/ccg/last-review.json`，逐字节校验 diff 哈希，防止改动后偷偷提交。

**Verdicts**（继承自 Stage 1）：
| Verdict | 行为 |
|---|---|
| `merge` | ✅ 允许 commit |
| `discuss` | ⚠️ 默认允许（可设 `CCG_GATE_DISCUSS=block` 阻止）|
| `fix-required` | ❌ 阻止 commit（要求修复重新评审）|

**流水线**：
```
staged diff → 计算 SHA256 → 对比 last-review.json 中的哈希
  → 完全匹配 → 读 verdict
    ✅ merge/discuss → 提交
    ❌ fix-required → 拒绝（输出上次评审缺陷）
  → 哈希不匹配 → diff 被篡改，拒绝提交（要求重新评审）
```

**安全保证**：
- 提交网关完全确定性：无 API 调用，无超时，无幻觉
- diff 篡改检测：哈希不匹配立即拒绝
- 评审一次，可靠执行：不会因为 API 抖动弱化决策

---

### Stage 3 — AI 合并（`ccg merge <target>`）⭐ **核心竞争力**

**目的**：专业、可靠地解决合并冲突。

**模型策略**：
- **Bailian 是主要解决器**（代码可靠性最高）
- 如果 Bailian 失败，降级到 **Codex + Gemini 并行**
- 全部失败 → `NEEDS_HUMAN_DECISION`

**冲突分类**（只有 `content` 进入 AI）：
| 类型 | 处理方式 |
|---|---|
| `content` | AI 解决 |
| `binary` | 转人工 |
| `submodule` | 转人工 |
| `symlink` | 转人工 |
| `delete_modify` | 转人工 |
| `both_deleted` | 转人工 |
| `added_one_side` | 转人工 |
| `both_added` | 转人工 |

**流水线**：
```
checkout target → 备份分支 → git merge --no-commit
  ↓ (每个冲突文件)
  分类 → 解析 <<<<<<< 块
  → Bailian 解决
    ↓ (失败)
    Codex + Gemini 并行
    ↓ (都失败)
    NEEDS_HUMAN_DECISION
  → 校验（无 markdown fence、无冲突标记、内容非空）
  → 原子文件重写（mktemp + mv、保留权限）
  → git add（如解决）
  ↓
  commit（如全部干净）| 不 commit（如有需人工）
```

**安全保证**：
- 合并前创建备份分支（`ccg-backup/<target>-<时间戳>-<pid>-<rand>`）
- 工作树不干净、detached HEAD、操作中等 → 拒绝
- 远端分叉 → 拒绝
- 每个冲突独立 nonce 防止 OURS/THEIRS 注入
- 校验解决内容（无 markdown fence、无冲突标记、内容非空）
- 原子文件替换（`mktemp` + `mv`）
- 保留文件权限，拒绝写入 symlink
- **绝不静默丢代码** —— 失败转 NEEDS_HUMAN
- 实时进度：`[3/12] src/auth.js ... ✅ 已解决`
- 限制最大冲突数（默认 50，可通过 `CCG_MERGE_MAX_CONFLICTS` 覆盖）

---

### Stage 4 — Push 前分析（`ccg push <remote> <branch>`）

**目的**：在 push 前给用户一份全面、图形化的报告——让用户做出明智决定。

**模型策略**：使用 Bailian LLM 做风险评分（失败时降级到规则引擎）。

**报告内容**：
```
╔══════════════════════════════════════════════════════════╗
║          🚀  CCG Pre-Push Analysis Report  🚀            ║
╚══════════════════════════════════════════════════════════╝

  📍 分支 / 远程 / HEAD / 作者 / 时间

  ┌─ 提交摘要 ─────────────────────────────────────────────┐
  │  Ahead: N 个 / Behind: M 个
  └────────────────────────────────────────────────────────┘

  📝 带质量标记的提交（✓ 规范提交 / ⚠ WIP）

  ┌─ 代码变更 ─────────────────────────────────────────────┐
  │  文件 / 新增 / 删除 + 视觉条形图
  └────────────────────────────────────────────────────────┘

  📂 文件分类：💻 代码 / 🧪 测试 / 📖 文档 / ⚙️ 配置

  🚨 检测到敏感文件（.env、*.pem、credentials 等）

  ┌─ 风险评估 ─────────────────────────────────────────────┐
  │  评分：🔴 CRITICAL (85) — auth + payment
  │  [████████████████████████████████████████████]
  └────────────────────────────────────────────────────────┘

  📊 Push 质量评分卡：
     ✅ 规范的 commit message
     ✅ 代码变更伴随测试
     ❌ 包含敏感文件
     ✅ 与远端同步
     ⚠️  高风险——需谨慎审查

  ┌─ 推荐 ─────────────────────────────────────────────────┐
  │  🔴 NOT RECOMMENDED (3/5 通过)
  └────────────────────────────────────────────────────────┘

  ┌─ 决策 ─────────────────────────────────────────────────┐
  │  y — push   |   n — 取消   |   d — 查 diff   |   l — 查 log
  └────────────────────────────────────────────────────────┘
```

**质量检查项**：
1. 规范的 commit message（`feat|fix|chore|...:`）
2. 代码变更伴随测试文件更新
3. 不包含敏感文件（`.env`、`*.pem`、`credentials` 等）
4. 与远端同步（不落后）
5. 风险等级可接受（<80）

---

## 模型策略

### 三种模式

CCG 基于风险评分自动选择模式，或通过 `CCG_MODE` 强制指定。

| 风险评分 | 自动模式 | 策略 |
|---|---|---|
| `< 30` | `cost` | 全部使用便宜的 Bailian 模型 |
| `30 – 70` | `balanced` | Claude/GPT/Gemini 混合（中级）|
| `> 70` | `quality` | Claude/GPT/Gemini 顶级 |

### 每种模式的模型

| 模式 | Codex 槽位 | Claude 槽位 | Gemini 槽位 | Bailian 槽位 |
|---|---|---|---|---|
| **`cost`** | `deepseek-v4` | `claude-haiku-4-5` | `qwen-3.7` | `kimi-k2.6` |
| **`balanced`** | `gpt-5.4` | `claude-sonnet-4-6` | `gemini-2.5-flash` | `qwen-3.6` |
| **`quality`** | `gpt-5.5` | `claude-opus-4-7` | `gemini-3.5-flash` | `deepseek-v4` |

- **Cost 模式**：全 Bailian 平台国产顶级模型（DeepSeek、Qwen、Kimi、GLM、Mimo）
- **Balanced 模式**：Claude/GPT/Gemini 中级
- **Quality 模式**：Claude Opus + GPT-5.5 + Gemini-3.5-flash 顶级

### 各阶段的模型使用

| 阶段 | 用模型？ | 使用哪个 |
|---|---|---|
| **Diff Capture** | ❌ | 纯 git 操作 |
| **Risk Score** | ❌ 默认 | 纯规则、确定性、零成本；`CCG_RISK_LLM=1` 才用 Bailian LLM |
| **Stage 1: 评审** | ✅ 2 个并行（不同厂商）| 非 quality：两个不同厂商 Bailian（默认 qwen + deepseek）；quality：codex/gemini/claude 三选二 |
| **Synthesize** | ✅ 1 个 | 非 quality：Bailian；quality：三件套里没上场的那个（缺省 claude）|
| **Stage 2: 提交门禁** | ❌ 0 次 LLM | 复用 Stage 1 verdict（零额外成本）|
| **Stage 3: Merge 冲突** | ✅ **Bailian 优先** | Claude → Codex + Gemini 作为降级 |
| **Stage 4: Push 检查** | ❌ 默认 | 风险评分（纯规则，同 Risk Score）|

### 可用的 Bailian 模型

| 模型 | 等级 | 输入 ¥/1M | 输出 ¥/1M | 说明 |
|---|---|---|---|---|
| `qwen-3.7` | quality | 0.30 | 0.90 | 最新 Qwen |
| `deepseek-v4` | quality | 0.35 | 1.05 | 顶级推理 |
| `kimi-k2.6` | quality | 0.32 | 0.96 | 长上下文 |
| `glm-5.1` | quality | 0.28 | 0.84 | 多模态 |
| `qwen-3.6` | balanced | 0.25 | 0.75 | |
| `mimo-v2.5-pro` | balanced | 0.22 | 0.66 | |
| `qwen-3.6-plus` | balanced | 0.20 | 0.60 | |
| `qwen-3.5-sonnet` | balanced | 0.15 | 0.45 | |
| `deepseek-v4-lite` | balanced | 0.18 | 0.54 | |
| `kimi-k2.6-lite` | balanced | 0.16 | 0.48 | |
| `glm-5.1-lite` | balanced | 0.14 | 0.42 | |
| `mimo-v2.5` | cost | 0.11 | 0.33 | |
| `qwen-3.5-haiku` | cost | 0.05 | 0.15 | 最便宜 |

---

## 配置

### 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| **开关 / 模式** | | |
| `CCG_MODE` | auto | `cost` / `balanced` / `quality` |
| `CCG_REVIEW` | `on` | 主开关：`on` / `off`（关闭时 `ccg review` 为空操作，`ccg commit` 跳过状态检查）|
| `CCG_PROVIDERS` | auto（按模式）| Stage 1 的提供商（最多 2 个并行）。quality: codex+gemini, cost/balanced: bailian 对。Claude 默认保留给综合步骤。|
| **提供商模型** | | |
| `CCG_CODEX_MODEL` | 按模式 | 覆盖 Codex 模型 |
| `CCG_CLAUDE_MODEL` | 按模式 | 覆盖 Claude 模型 |
| `CCG_GEMINI_MODEL` | 按模式 | 覆盖 Gemini 模型 |
| `CCG_BAILIAN_MODEL` | 按模式 | 覆盖 Bailian 模型 |
| `CCG_DEEPSEEK_MODEL` | 按模式 | 覆盖 DeepSeek 模型 |
| `CCG_KIMI_MODEL` | 按模式 | 覆盖 Kimi 模型 |
| `CCG_GLM_MODEL` | 按模式 | 覆盖 GLM 模型 |
| `CCG_MINIMAX_MODEL` | 按模式 | 覆盖 MiniMax 模型 |
| `CCG_MIMO_MODEL` | 按模式 | 覆盖 Mimo 模型 |
| **API 密钥** | | |
| `BAILIAN_API_KEY` | — | Bailian（阿里云）API 密钥 |
| `ANTHROPIC_API_KEY` / `CLAUDE_API_KEY` | — | Anthropic API 密钥 |
| `GEMINI_API_KEY` | — | Google Gemini API 密钥 |
| `DEEPSEEK_API_KEY` | — | DeepSeek 官方 API 密钥 |
| `KIMI_API_KEY` | — | Kimi（月之暗面）官方 API 密钥 |
| `GLM_API_KEY` | — | GLM（智谱）官方 API 密钥 |
| `MINIMAX_API_KEY` | — | MiniMax 官方 API 密钥 |
| `MIMO_API_KEY` | — | Mimo 官方 API 密钥 |
| **自定义端点（代理）** | | |
| `CCG_CODEX_BASE_URL` / `OPENAI_BASE_URL` | OpenAI | Codex / OpenAI 代理 URL |
| `CCG_CLAUDE_BASE_URL` / `ANTHROPIC_BASE_URL` | api.anthropic.com | Claude 代理 URL |
| `CCG_GEMINI_BASE_URL` / `GEMINI_BASE_URL` | Google | Gemini 代理 URL |
| `CCG_BAILIAN_BASE_URL` | dashscope.aliyuncs.com | Bailian 代理 URL |
| `CCG_DEEPSEEK_BASE_URL` | api.deepseek.com/v1 | DeepSeek 官方 API URL |
| `CCG_KIMI_BASE_URL` | api.moonshot.cn/v1 | Kimi 官方 API URL |
| `CCG_GLM_BASE_URL` | open.bigmodel.cn/api/paas/v4 | GLM 官方 API URL |
| `CCG_MINIMAX_BASE_URL` | api.minimax.chat/v1 | MiniMax 官方 API URL |
| `CCG_MIMO_BASE_URL` | — | Mimo 官方 API URL（必填）|
| **超时 / 参数** | | |
| `CCG_CODEX_TIMEOUT` | 240 | Codex 超时（秒）|
| `CCG_GEMINI_TIMEOUT` | 120 | Gemini 超时（秒）|
| `CCG_BAILIAN_TIMEOUT` | 120 | Bailian 超时（秒）|
| `CCG_CLAUDE_TIMEOUT` | 120 | Claude 超时（秒）|
| `CCG_DEEPSEEK_TIMEOUT` | 120 | DeepSeek 超时（秒）|
| `CCG_KIMI_TIMEOUT` | 120 | Kimi 超时（秒）|
| `CCG_GLM_TIMEOUT` | 120 | GLM 超时（秒）|
| `CCG_MINIMAX_TIMEOUT` | 120 | MiniMax 超时（秒）|
| `CCG_MIMO_TIMEOUT` | 120 | Mimo 超时（秒）|
| `CCG_BAILIAN_TEMP` | 0.7 | Bailian 温度 |
| `CCG_BAILIAN_MAX_TOKENS` | 4096 | Bailian 最大 token 数 |
| `CCG_BAILIAN_RETRIES` | 3 | Bailian 重试次数 |
| `CCG_CLAUDE_RETRIES` | 3 | Claude 重试次数 |
| **门禁 / 提交** | | |
| `CCG_GATE_OFFLINE` | 0 | 设为 1 跳过 Stage 2 评审 |
| `CCG_GATE_DISCUSS` | allow | 设为 `block` 阻止 discuss verdict |
| `CCG_NO_AUTO_ADD` | 0 | Stage 2：跳过自动 `git add -A`，仅使用已暂存内容 |
| `CCG_COMMIT_FORCE` | 0 | Stage 2：绕过 diff 哈希检查（强制提交）|
| `CCG_AUTOCOMMIT_ALL` | 0 | 自动提交所有更改（包括未跟踪文件）|
| `CCG_AUTOCOMMIT_DRY_RUN` | 0 | 自动提交干跑模式 |
| `CCG_DIFF_CACHED_ONLY` | 0 | 仅使用缓存的 diff |
| **合并** | | |
| `CCG_MERGE_DRY_RUN` | 0 | Stage 3：解决但不 commit |
| `CCG_MERGE_NO_AI` | 0 | Stage 3：跳过 AI 解决 |
| `CCG_MERGE_NO_FETCH` | 0 | Stage 3：跳过远程 fetch |
| `CCG_MERGE_MAX_CONFLICTS` | 50 | Stage 3：最大冲突文件数 |
| `CCG_MERGE_KEEP_BACKUP` | 0 | Stage 3：成功后保留备份分支 |
| **缓存 / 账本 / 报告** | | |
| `CCG_NO_CACHE` | 0 | 禁用 prompt 缓存 |
| `CCG_CACHE_TTL_HOURS` | 24 | Prompt 缓存 TTL |
| `CCG_CACHE_DIR` | XDG 默认 | 自定义缓存目录 |
| `CCG_MAX_PROMPT_KB` | 100 | 最大 prompt 大小（KB）|
| `CCG_USAGE_LOG` | XDG 默认 | 自定义用量日志路径 |
| `CCG_LEDGER_LOG` | XDG 默认 | 自定义账本日志路径 |
| `CCG_LEDGER_MAX_LINES` | 10000 | 账本最大行数（超过后轮转）|
| `CCG_NO_HISTORY` | 0 | 禁用评审历史注入 |
| `CCG_HISTORY_MAX` | 3 | 注入的历史评审最大数量 |
| `CCG_NO_REPORT` | 0 | 禁用报告持久化 |
| `CCG_REPORT_DIR` | .ccg/reports | 自定义报告目录 |
| `CCG_KEEP_ARTIFACTS` | 0 | 保留 workdir 用于调试 |
| **其他** | | |
| `CCG_ALLOW_SAME_VENDOR` | 0 | 允许 Stage 1 使用相同供应商 |
| `CCG_SYNTH_PROVIDER` | auto | 覆盖综合器提供商 |
| `CCG_RISK_LLM` | 0 | 启用基于 LLM 的风险评分 |

### 使用示例

```bash
# 关键评审强制 quality 模式
CCG_MODE=quality ccg review

# 仅使用 Bailian（国内友好）
CCG_PROVIDERS="bailian" ccg review

# 指定 Bailian 模型
CCG_BAILIAN_MODEL=deepseek-v4 ccg review

# 使用 DeepSeek 官方 API
DEEPSEEK_API_KEY="sk-xxx" CCG_PROVIDERS="deepseek" ccg review

# 使用 Kimi（月之暗面）官方 API
KIMI_API_KEY="sk-xxx" CCG_PROVIDERS="kimi" ccg review

# 使用 GLM（智谱）官方 API
GLM_API_KEY="xxx.xxx" CCG_PROVIDERS="glm" ccg review

# 使用 MiniMax 官方 API
MINIMAX_API_KEY="xxx" CCG_PROVIDERS="minimax" ccg review

# 使用 Mimo 官方 API（需要自定义 base URL）
MIMO_API_KEY="sk-xxx" CCG_MIMO_BASE_URL="https://api.mimo.com/v1" CCG_PROVIDERS="mimo" ccg review

# 混合独立提供商（不同厂商）
DEEPSEEK_API_KEY="sk-xxx" KIMI_API_KEY="sk-xxx" CCG_PROVIDERS="deepseek kimi" ccg review

# 干跑 merge（解决但不 commit）
CCG_MERGE_DRY_RUN=1 ccg merge main

# 跳过 AI merge（仅检测冲突）
CCG_MERGE_NO_AI=1 ccg merge main
```

---

## 架构

```
ccg/
├── ccg                              # 入口（4 行委托）
├── ccg.sh                           # 核心引擎（~3000 行）
│   ├── _ccg_xdg_* / _ccg_vcs_*     # XDG 路径 + git 抽象
│   ├── ccg_init / ccg_preflight    # workdir 初始化
│   ├── ccg_diff_capture            # 4 层 diff fallback
│   ├── ccg_risk_score              # Bailian LLM + 规则引擎
│   ├── ccg_codex / ccg_gemini      # 提供商执行器
│   ├── _ccg_bailian_retry          # Bailian 带重试/退避
│   ├── ccg_synthesize              # AGREEMENT/DIVERGENCE/BLINDSPOT
│   ├── ccg_precommit_gate          # Stage 2 提交门禁
│   └── ccg_merge                   # Stage 3 AI 合并
│       ├── _ccg_classify_conflict  # content/binary/submodule/...
│       ├── _ccg_parse_conflicts    # 提取 <<<<<<<>>>>>>> 块
│       ├── _ccg_resolve_one_conflict  # Bailian 优先的 AI 解决
│       └── _ccg_apply_resolutions  # 原子文件重写
├── ccg-bailian-models.sh           # 13 个模型的 Bailian 注册表
├── ccg-bailian-integration.sh      # Bailian API 调用辅助
├── ccg-multi-provider.sh           # 多提供商编排
├── ccg-workflow.sh                 # 4 阶段工作流入口
└── ccg.md                          # Claude Code slash command 规范

docs/
├── README.zh-CN.md / .ja.md / .ko.md    # 翻译
├── ARCHITECTURE.md（+ 3 个翻译）        # 架构深度
└── CHANGELOG.md                         # 版本历史
```

### 存储路径（遵循 XDG 规范）

| 路径 | 内容 |
|---|---|
| `$XDG_DATA_HOME/ccg/usage.log` | Token 用量 + 成本日志 |
| `$XDG_DATA_HOME/ccg/ledger.jsonl` | 按评审的 JSONL ledger |
| `$XDG_CACHE_HOME/ccg/cache/` | Prompt hash → 结果缓存（24h TTL）|
| `$XDG_CONFIG_HOME/ccg/` | 用户配置 |

旧版 `~/.ccg/*` 首次运行时自动迁移。

---

## 文档

- [架构深度解析](ARCHITECTURE.zh-CN.md)（[English](ARCHITECTURE.md) · [日本語](ARCHITECTURE.ja.md) · [한국어](ARCHITECTURE.ko.md)）
- [更新日志](CHANGELOG.md)
- [Slash command 规范](../ccg.md) — Claude Code `/ccg` 命令

---

## 许可证

MIT
