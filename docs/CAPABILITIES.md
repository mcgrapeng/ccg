# CCG 能力全集(Capabilities)

> 本文档基于源码实际行为整理(非宣传文案),覆盖 `ccg`、`ccg.sh`、`ccg-workflow.sh`、`ccg-multi-provider.sh`、`ccg-bailian-models.sh`、`ccg-bailian-integration.sh`、`bin/ccg.js`。
>
> 一句话定位:CCG 是 **多模型代码评审守护者 + 风险感知路由 + 评审记忆 + 4 阶段自动化工作流**（review → commit gate → AI merge → push analysis）的一体化 Git 工作流引擎。

运行约束:**Bash 3.2+(macOS 默认)与 zsh 双兼容**;依赖 `git`、`curl`、`jq`;四家模型至少配置其一。

---

## 1. 入口与使用方式

| 入口 | 形态 | 用途 |
|---|---|---|
| `ccg <action>` | 独立 CLI(bash 包装器) | 四阶段工作流 |
| `source ccg.sh && ccg_xxx` | 函数库 | 直接调用任意公共函数 |
| `bash ccg.sh <subcmd>` | dispatch 守卫 | 命令行直跑单个函数 |
| `/ccg`(Claude Code) | Slash 命令 | 由 `ccg.md` 协议驱动 Claude 编排 |
| `npx @mcgrapeng/ccg <cmd>` | Node CLI(`bin/ccg.js`) | install / uninstall / doctor / about / version |
| `ccg-precommit.bat` | Windows/TortoiseSVN 钩子 | 提交前网关(git 场景) |

CLI 顶层动作(`ccg_workflow`):`review` · `commit` · `merge` · `push`(= `push-check`)· `config` · `models`。

---

## 2. 四阶段工作流(核心)

### Stage 1 — `ccg review` 代码评审 / 分歧检测
- 流程:`ccg_init` → `ccg_diff_capture` → `ccg_risk_score` → 自动选 mode → **任意 2 个 provider 并行** → `ccg_synthesize`(Claude 综合)
- 三段分类输出:
  - **AGREEMENT** — 两边都指出(信号低,降级展示)
  - **DIVERGENCE** — 两边矛盾(★核心价值,需人裁决)
  - **BLINDSPOT** — 一方漏报另一方抓到(最高信号)
- 裁决:`merge` / `fix-required` / `discuss`
- 落 ledger、持久化报告、写状态 `.git/ccg/last-review.json` 供 Stage 2 复用
- `CCG_REVIEW=off` 可整段关闭(review 变 no-op)
- 安全:prompt 注入防御、>200KB diff 警告、Ctrl+C 杀子进程、1/2 成功仍继续

### Stage 2 — `ccg commit "msg"` 评审门禁提交(**0 次 LLM 调用**)
1. 自动 `git add -A`(含**未跟踪文件**;`CCG_NO_AUTO_ADD=1` 关闭)
2. 读状态文件,**校验暂存 diff 哈希 == 已评审哈希**(改了即拒绝;`CCG_COMMIT_FORCE=1` 绕过)
3. 按裁决:`merge`=✅ / `discuss`=⚠️默认放行(`CCG_GATE_DISCUSS=block` 可拦)/ `fix-required`=❌阻断
4. 提交后删状态文件(一次性消费)

| 失败场景 | 结果 |
|---|---|
| 无前置评审 | ❌ 提示先 `ccg review`(或 `CCG_REVIEW=off`) |
| diff 已变 | ❌ 哈希不匹配 |
| 绕过哈希 | `CCG_COMMIT_FORCE=1` |

### Stage 3 — `ccg merge <target>` AI 冲突解决(核心竞争力)
- 安全前置:拒绝脏工作区 / 游离 HEAD / 进行中操作(rebase·merge·cherry-pick·revert·bisect)/ 远程分叉 / source==target
- fetch + 同步 target;**合并前备份 target** → `ccg-backup/<target>-<ts>-<pid>-<rand>`
- `git checkout target` → `git merge --no-commit --no-ff <source>`
- **冲突分类**(仅 `content` 交给 AI):

| 类型 | 处理 |
|---|---|
| content | AI 解决 |
| binary / submodule / symlink | 需人工 |
| delete_modify / both_deleted | 需人工 |
| added_one_side / both_added / unknown | 需人工 |

- **3 级 AI 兜底**:Bailian → Claude → Codex+Gemini 并行 → `NEEDS_HUMAN_DECISION`
- 解析 `<<<<<<< ======= >>>>>>>`(diff3 的 `|||||||` base 段丢弃)
- 产物校验:无 markdown 围栏、无残留冲突标记、非空、无 `NEEDS_HUMAN_DECISION`
- 原子写回:mktemp + mv,保留文件权限,拒绝穿透符号链接,跨文件系统回退 cp
- **绝不静默丢码**:主模型若产出非法内容 → 升级人工,而非偷换副模型答案
- 实时进度 `[3/12] file ... ✅ resolved`;`CCG_MERGE_MAX_CONFLICTS`(默认 50)防失控
- 任一冲突需人工 → 不提交,留 target 供审;成功后默认删备份(`CCG_MERGE_KEEP_BACKUP=1` 保留)
- 开关:`CCG_MERGE_DRY_RUN` / `CCG_MERGE_NO_AI` / `CCG_MERGE_NO_FETCH`

### Stage 4 — `ccg push <remote> <branch>` 推送前图形化决策
- 检测上游 / 远程 URL / ahead·behind / 终端宽度自适应(70–100 列)
- 提交质量标记(✓ 规范 / ⚠ WIP·FIXME·非规范)
- 文件分类:💻 代码 / 🧪 测试 / 📖 文档 / ⚙️ 配置 / 📦 其他
- **敏感文件检测**:`.env` `*.pem` `*.key` `id_rsa*` `*credentials*` `secrets*`
- 风险评估 + 可视化进度条
- **5 项质量记分卡**:规范提交 · 代码配套测试 · 无敏感文件 · 与远程同步 · 风险可接受
- 推荐:🟢 READY / 🟡 CAUTION / 🔴 NOT RECOMMENDED
- 决策 `y/n/d(diff)/l(log)` → **同意后真正 `git push`**(首推自动 `-u`)

### 一键交付 — `ccg_ship [target] [msg]`
staged → `ccg_autocommit`(评审通过才提交)→ `ccg_merge <target>`。

---

## 3. Provider × Mode 模型策略

### 四家独立 Provider
| Provider | 通道 | 依赖 | 自定义端点 |
|---|---|---|---|
| `codex` | Codex CLI(OpenAI) | `codex` 二进制 | `CCG_CODEX_BASE_URL` / `OPENAI_BASE_URL` |
| `gemini` | Gemini CLI(Google) | `gemini` 二进制 + `GEMINI_API_KEY` | `CCG_GEMINI_BASE_URL` / `GEMINI_BASE_URL` |
| `claude` | Anthropic API 直连 | `ANTHROPIC_API_KEY` / `CLAUDE_API_KEY` | `CCG_CLAUDE_BASE_URL` / `ANTHROPIC_BASE_URL` |
| `bailian` | 阿里云百炼 API 直连 | `BAILIAN_API_KEY` | `CCG_BAILIAN_BASE_URL` |

> ⚠️ **claude 在 Stage 1 强制禁用**,专留给综合步骤做独立第三方视角。

### 三档 Mode(按风险自动选,`CCG_MODE` 可强制)
| Mode | 触发 | codex | claude | gemini | bailian |
|---|---|---|---|---|---|
| `cost` | risk < 30 | deepseek-v4 | claude-haiku-4-5 | qwen-3.7 | kimi-k2.6 |
| `balanced` | 30–70 | gpt-5.4 | claude-sonnet-4-6 | gemini-2.5-flash | qwen-3.6 |
| `quality` | > 70 | gpt-5.5 | claude-opus-4-7 | gemini-3.5-flash | deepseek-v4 |

> 默认模型名为本项目设定,第三方代理若不支持会 4xx/5xx,用 `CCG_*_MODEL` 显式指定代理实际支持的型号。

### `CCG_PROVIDERS` 语法(Stage 1,最多 2 路并行)
```bash
CCG_PROVIDERS="codex gemini"                       # 默认
CCG_PROVIDERS="bailian:qwen-3.7 bailian:deepseek-v4"  # 同 provider 两个模型
CCG_PROVIDERS="codex:gpt-5.5 gemini:gemini-3.5-flash" # 显式模型
# claude 会被拒绝
```

### 百炼模型注册表(15 个,`ccg models` 可查)
qwen-3.7 / 3.6 / 3.6-plus / 3.5-sonnet / 3.5-haiku · deepseek-v4 / -lite · kimi-k2.6 / -lite · glm-5.1 / -lite · mimo-v2.5-pro / v2.5 · minimax-m2 / minimax-m2-lite(各含输入·输出价与档位)。

---

## 4. 基础设施 7 层(每层独立可用)

| 层 | 能力 | 关键实现 |
|---|---|---|
| **L1 安全 CLI 调度** | 超时 / stdin 保护 / 脱敏 / 清理安全 | 可移植 `timeout`(无则纯 bash 轮询);7+ 类密钥脱敏;Ctrl+C 杀子进程树;mktemp 700 工作区 + 24h 孤儿清扫 |
| **L2 内容寻址缓存** | 同 prompt 不重复付费(省 ~90%) | SHA-256(prompt+model)键,24h TTL,原子写,失败不入缓存,权限 600 |
| **L3 智能 diff 抓取** | 提交后也能抓到改动 | 4 级回退 worktree(含未跟踪)→ staged → upstream → origin-head,输出 `CCG_DIFF_SOURCE` |
| **L4 用量与成本遥测** | 按月 / 按模型看花费 | tab 分隔 usage.log;`ccg_usage`;字符数→token 估算(±15%) |
| **L5 风险感知路由** | 自动选档,纯规则可解释可改 | 见下方权重表(纯规则引擎;可选启用 LLM: `CCG_RISK_LLM=1`) |
| **L6 评审账本(双向)** | "上次模型对这文件怎么判的" | append-only JSONL;`ccg_ledger_query`;`ccg_ledger_context` 注入历史;超 10000 行轮转 |
| **L7 分歧检测(综合)** | 单模型看不到自己盲区 | 同 prompt 双投喂 → Claude 综合;兜底链 Claude→codex→bailian→gemini |

### L5 风险打分规则(纯规则引擎)
- **路径**:auth+35 · payment+40 · migration+30 · crypto+30 · security+25 · infra+20 · ci+15;纯文档 −40
- **内容**:sql_interp+30 · shell_exec+25 · privilege+25 · fs_delete+20 · hardcoded_host+5 · todo_marker+5
- **规模**:>600 行 +25 / >300 +15 / >100 +5;文件数 >8 +10
- 阈值:<30 cost · 30-70 balanced · >70 quality

---

## 5. 提交门禁与 Git 钩子(另一条提交路径)

- **`ccg_precommit_gate`** — 跑评审并以退出码门禁(0 放行 / 1 阻断 / 2 错误);带 **per-call nonce 哨兵防 prompt 注入**(diff 内伪造的 `VERDICT: merge` 无效);**失败闭合(fail-closed)**;`CCG_GATE_OFFLINE=1` 跳过
- **`ccg_autocommit`** — **仅评审已暂存内容**(默认安全,防误提 `.env`/构建产物);评审期间索引被改则拒绝;`CCG_AUTOCOMMIT_ALL=1` 才 add -A;`CCG_AUTOCOMMIT_DRY_RUN=1` 演练
- **`ccg_install_hook` / `ccg_uninstall_hook`** — 安装/卸载 git `pre-commit` 钩子:链式保留已有钩子、备份原钩子、honor `core.hooksPath`(husky/lefthook)、原子写入 + 失败回滚、zsh 路径自省

---

## 6. 配置环境变量(全量)

**总开关 / 模式**:`CCG_MODE` · `CCG_REVIEW` · `CCG_PROVIDERS`
**模型覆盖**:`CCG_CODEX_MODEL` · `CCG_CLAUDE_MODEL` · `CCG_GEMINI_MODEL` · `CCG_BAILIAN_MODEL`
**密钥**:`BAILIAN_API_KEY` · `ANTHROPIC_API_KEY`/`CLAUDE_API_KEY` · `GEMINI_API_KEY`
**端点代理**:`CCG_CODEX_BASE_URL`/`OPENAI_BASE_URL` · `CCG_CLAUDE_BASE_URL`/`ANTHROPIC_BASE_URL` · `CCG_GEMINI_BASE_URL`/`GEMINI_BASE_URL` · `CCG_BAILIAN_BASE_URL`
**超时 / 参数**:`CCG_CODEX_TIMEOUT`(240)· `CCG_GEMINI_TIMEOUT`(120)· `CCG_BAILIAN_TIMEOUT`(120)· `CCG_BAILIAN_TEMP`(0.7)· `CCG_BAILIAN_MAX_TOKENS`(4096)· `CCG_BAILIAN_RETRIES`(3)· `CCG_CLAUDE_RETRIES`(3)
**门禁 / 提交**:`CCG_GATE_OFFLINE` · `CCG_GATE_DISCUSS` · `CCG_NO_AUTO_ADD` · `CCG_COMMIT_FORCE` · `CCG_AUTOCOMMIT_ALL` · `CCG_AUTOCOMMIT_DRY_RUN` · `CCG_DIFF_CACHED_ONLY`
**合并**:`CCG_MERGE_DRY_RUN` · `CCG_MERGE_NO_AI` · `CCG_MERGE_NO_FETCH` · `CCG_MERGE_MAX_CONFLICTS`(50)· `CCG_MERGE_KEEP_BACKUP`
**缓存 / 账本 / 报告**:`CCG_NO_CACHE` · `CCG_CACHE_TTL_HOURS`(24)· `CCG_CACHE_DIR` · `CCG_MAX_PROMPT_KB`(100)· `CCG_USAGE_LOG` · `CCG_LEDGER_LOG` · `CCG_LEDGER_MAX_LINES`(10000)· `CCG_NO_HISTORY` · `CCG_HISTORY_MAX`(3)· `CCG_NO_REPORT` · `CCG_REPORT_DIR` · `CCG_KEEP_ARTIFACTS`

---

## 7. 存储布局(XDG 规范)

| 路径 | 内容 |
|---|---|
| `$XDG_DATA_HOME/ccg/usage.log` | 用量 + 成本日志 |
| `$XDG_DATA_HOME/ccg/ledger.jsonl` | 逐次评审 JSONL 账本 |
| `$XDG_CACHE_HOME/ccg/cache/` | prompt 哈希 → 结果缓存(24h) |
| `$XDG_CONFIG_HOME/ccg/` | 用户配置 |
| `<repo>/.git/ccg/last-review.json` | Stage 1→2 复用状态 |
| `<repo>/.ccg/reports/<sha>_<ts>.md` | 持久化评审报告(自带 `.gitignore`) |

旧 `~/.ccg/*` 首次运行自动迁移到 XDG 路径(非破坏式)。

---

## 8. 安全保证

- **密钥脱敏**:stderr / ledger / 报告(sk- · AIza · Bearer · JWT · ghp_ · AKIA · Slack · URL query)
- **prompt 注入防御**:不可信内容标记 + 每次调用唯一 nonce 哨兵(评审网关、冲突解决双侧标记)
- **合并安全**:先备份分支、绝不静默丢码、产物校验、原子写、拒穿符号链接、保留权限
- **门禁安全**:fail-closed;哈希门禁保证"评审什么 = 提交什么"
- **清理安全**:路径遍历防护(仅删绝对路径、basename 为 `ccg.*`、非符号链接)
- **prompt 大小硬限**:默认 100KB,防止把整个仓库塞进 prompt

---

## 9. 公共函数 API 速查

**初始化 / 探测**:`ccg_init` · `ccg_preflight`
**Diff / 风险**:`ccg_diff_capture <out>` · `ccg_risk_score <diff>`
**Provider 调用**:`ccg_codex` · `ccg_gemini` · `ccg_bailian` · `ccg_claude` · `ccg_bailian_stream`(均缓存感知、用量记账)
**综合 / 成本 / 用量**:`ccg_synthesize <a> <b> <out>` · `ccg_actual <prompt> <result> <provider>` · `ccg_usage [--this-month|--all|--since=]`
**账本 / 报告 / 清理**:`ccg_ledger_record` · `ccg_ledger_query [path]` · `ccg_ledger_context <diff>` · `ccg_persist_report <workdir>` · `ccg_cleanup <dir>`
**工作流**:`ccg_review` · `ccg_commit` · `ccg_merge` · `ccg_push_check` · `ccg_ship`
**门禁 / 钩子**:`ccg_precommit_gate` · `ccg_autocommit` · `ccg_install_hook` · `ccg_uninstall_hook`
**多 provider / 百炼辅助**:`ccg_with_providers`(ccg_review 轻量版)· `ccg_with_bailian` · `ccg_compare_models` · `ccg_benchmark` · `ccg_list_models` · `ccg_show_config`

---

## 10. 已知边界

- **SVN**:`_ccg_vcs_*` 抽象层目前仅支持 git;`bin/ccg-precommit.bat`(TortoiseSVN)调用的是 git-only 网关,SVN 工作副本下会判定"非 git 仓库"。SVN diff 支持属待补功能。
- **价格估算**:基于字符数 / 3.0 的启发式,±15%;部分默认模型为本项目设定的型号,价格为按档位的估算,正式费率发布后需更新 `_ccg_price`。
- **Codex 沙箱**:`codex exec` 在沙箱运行,不修改本地文件。
