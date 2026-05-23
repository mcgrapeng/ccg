# `/ccg` — Code Divergence Detector

[![Tests](https://img.shields.io/badge/tests-99%20passing-brightgreen.svg)]()
[![npm](https://img.shields.io/npm/v/@mcgrapeng/ccg.svg)](https://www.npmjs.com/package/@mcgrapeng/ccg)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[English](README.md) ｜ [简体中文](README.zh-CN.md) ｜ **日本語** ｜ [한국어](README.ko.md)

> **「より良いコードレビューツール」ではなく、コード分岐検出ツールです。**
> 多くの AI レビューツールはコンセンサスを追求します。`/ccg` はその逆です—Codex（OpenAI）と Gemini（Google）に同じ diff を並列で評価させ、Claude が **両者の意見が食い違う箇所** を浮かび上がらせます。これこそ人間が判断すべきポイントです。意見の一致 = 低シグナル、分岐 = ゴールド。

---

## 主張

| 既存の AI レビューツール | `/ccg` |
|---|---|
| 単一モデル、単一視点 | 2 つの独立したモデルファミリー（訓練データが異なる） |
| 出力は長文レビューレポート | 出力は **分岐マップ** |
| 「問題なさそう」と流し読み | 「Codex が X を指摘、Gemini は同意せず、人の判断が必要」が見える |
| pre-commit フック型（承認 / ブロック） | トリアージツール（「考えるべきは本当にこの 2 つ」） |

この立ち位置はユニークです。**AI 間の意見の相違を浮かび上がらせること自体を製品目標とする** OSS ツールを、私たちは他に把握していません。

---

## 三本の柱

### Pillar 1 — 分岐エンジン
同じプロンプトを Codex と Gemini の両方に投げ、構造化された `[FINDING]` フォーマットを要求します。Claude の合成器が以下の 3 セクションを出力：

```
AGREEMENT (N)    — 両方が指摘 → 低シグナル、各 1 行のみ
DIVERGENCE (M)   — 判断が異なる → 展開、★ 人の判断が必要
BLINDSPOT (≤2)  — どちらも見ていないが Claude が疑う → 控えめに
```

AGREEMENT セクションは**意図的に短く**保たれます。プロダクトの立場：両方の AI レビュアーが合意しているなら、あなたの単一ソース Claude も同じことに気付くはず——新しい情報量は低い。DIVERGENCE こそが価値です。

### Pillar 2 — リスク対応自動ルーティング
`cost` / `balanced` / `quality` を手動で選ぶ必要はありません。`ccg_risk_score` が diff を見て決定論的にスコア付けします（このレイヤーに LLM はなし）：

| シグナル | 重み |
|---|---|
| パスが `auth/payment/migration/crypto/security` にマッチ | +25..+40 |
| 本文に `exec/eval/spawn` または SQL+補間 | +20..+30 |
| diff > 600 行 | +25 |
| ファイル > 8 個 | +10 |
| ドキュメントのみの変更 | **-40** |

スコア < 20 → cost。< 60 → balanced。≥ 60 → quality。手動指定が常に優先。

スコアリングは **透明、ゼロコスト、PR 可能** ——誰でも重みを調整できます。

### Pillar 3 — レビュー台帳
各レビューが `$XDG_DATA_HOME/ccg/ledger.jsonl`（fallback `~/.local/share/ccg/ledger.jsonl`；古い `~/.ccg/` は自動移行）に JSONL 1 行を追記：

```json
{"ts":"2026-05-22T18:35:06Z","repo":"/path","branch":"feat-x","sha":"91c16ec",
 "mode":"quality","risk":60,"files":1,"lines":"+5-0","paths":["auth/login.go"],
 "synthesis":"divergence on constant-time compare; NEEDS HUMAN DECISION..."}
```

使い方：

```bash
ccg_ledger_query                    # 最新 5 件のレビュー
ccg_ledger_query "src/auth"         # このパスは何回レビューされたか
```

最初の 50 件では価値が見えませんが、長期的にステートレスツールには真似できない構造的記憶になります。

---

## インストール

どちらか選択。どちらも `/ccg` スラッシュコマンドを `~/.claude/commands/` にインストールします。

### Option 1 — npm（推奨）

```bash
npx @mcgrapeng/ccg install        # 一回だけ、グローバル汚染なし
# または
npm i -g @mcgrapeng/ccg && ccg install
```

### Option 2 — curl ワンライナー（Node 不要）

```bash
curl -fsSL https://raw.githubusercontent.com/mcgrapeng/ccg/main/scripts/curl-install.sh | bash
```

### 次に AI CLI をインストール

```bash
npm i -g @openai/codex @google/gemini-cli
echo 'export GEMINI_API_KEY="<your-key>"' >> ~/.zshenv
```

確認：

```bash
npx @mcgrapeng/ccg doctor         # または：ccg doctor
```

新しい Claude Code セッションを開いて `/ccg` を試してください。

## 使い方

```bash
# 自動モード：git diff → リスクスコア → 実行 → 合成 → 台帳記録
/ccg

# 明示的なタスク（リスクスコアスキップ、CCG_MODE 設定済みなら使用）
/ccg evaluate the lock-free queue implementation in src/queue.ts

# モードを強制
CCG_MODE=quality /ccg

# 特定のモデルを強制
CCG_CODEX_MODEL=o3 /ccg

# 履歴クエリ
source ~/.claude/commands/ccg.sh
ccg_usage --this-month
ccg_ledger_query "src/payment"
```

## 設定

| 変数 | デフォルト | 用途 |
|---|---|---|
| `CCG_MODE` | `auto` | `auto` / `cost` / `balanced` / `quality`。`auto` はリスクスコア |
| `CCG_CODEX_MODEL` | （モードデフォルト） | codex モデルを上書き |
| `CCG_GEMINI_MODEL` | （モードデフォルト） | gemini モデルを上書き |
| `CCG_CODEX_TIMEOUT` | `240` | Codex ハードタイムアウト（秒） |
| `CCG_GEMINI_TIMEOUT` | `120` | Gemini ハードタイムアウト（秒） |
| `CCG_NO_CACHE` | `0` | `1` = プロンプトキャッシュをバイパス |
| `CCG_CACHE_TTL_HOURS` | `24` | キャッシュ TTL |
| `CCG_CACHE_DIR` | `$XDG_CACHE_HOME/ccg/cache` | キャッシュディレクトリ |
| `CCG_MAX_PROMPT_KB` | `100` | プロンプトサイズハードリミット |
| `CCG_USAGE_LOG` | `$XDG_DATA_HOME/ccg/usage.log` | 使用量ログパス |
| `CCG_LEDGER_LOG` | `$XDG_DATA_HOME/ccg/ledger.jsonl` | 台帳パス |
| `CCG_KEEP_ARTIFACTS` | `0` | `1` = デバッグ用に作業ディレクトリ保持 |

## `/ccg` が輝くとき

- **リスクの高い変更**：auth / 支払い / マイグレーション / 暗号——まさに「もう一つのモデルは私が見逃したものを見つけたか？」を知りたい場面
- **マージ前の PR レビュー**：ブランチが上流より進んでいるとき、`/ccg` は自動でブランチ差分をレビュー
- **個人開発者の安全網**：人間レビュアーがいない？`/ccg` は「もう一対の目」に最も近い存在

## `/ccg` が過剰なとき

- 変数のリネーム
- 1 行の typo 修正
- README の編集
- 強力なテストカバレッジでの日常的なリファクタ

リスクルーターはこれらを自動的に `cost` モード（~$0.0007）に下げますが、正直なところ：そのまま commit して進めましょう。`/ccg` が真価を発揮するのは、本当に重要な 5–10% の変更です。

## ライセンス

MIT — [LICENSE](LICENSE) を参照。

## 謝辞

- [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) の元々の `/ccg` コンセプト
- Anthropic Claude Code、OpenAI Codex CLI、Google Gemini CLI
