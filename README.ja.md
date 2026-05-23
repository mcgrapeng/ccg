# ccg — Code Divergence Detector

> Claude Code のスラッシュコマンド。一度インストールして、diff の上で `/ccg` と入力するだけ。

[![Tests](https://img.shields.io/badge/tests-99%20passing-brightgreen.svg)]()
[![npm](https://img.shields.io/npm/v/@mcgrapeng/ccg.svg)](https://www.npmjs.com/package/@mcgrapeng/ccg)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[English](README.md) ｜ [简体中文](README.zh-CN.md) ｜ **日本語** ｜ [한국어](README.ko.md)　·　[アーキテクチャ →](docs/ARCHITECTURE.md)

---

## ccg とは

ccg は **Codex（OpenAI）** と **Gemini（Google）** に同じ diff を並列で評価させ、**Claude** が両者の意見が食い違う箇所を浮かび上がらせます——人間が本当に判断すべきポイントです。

多くの AI レビューツールはコンセンサスを追求します。ccg はその逆。意見の一致 = 低シグナル、分岐 = ゴールド。

## ccg にできること

単一モデルのレビューツールでは得られない 3 つのこと：

**1. Claude とは違う思考をする「セカンドオピニオン」。**
Codex と Gemini は訓練データが異なり、検出するものも違います。`auth/login.go` の同じ変更で意見が分かれた時、そここそ立ち止まる場所です。

**2. コストの可視化。**
Codex / Gemini CLI は支出を教えてくれません。ccg は全ての呼び出しを記録し、リスクに応じて最も安く十分なモデルを自動選択（リスクルーティング）、同一プロンプトは 24 時間キャッシュでゼロコストになります。

**3. セッションを跨いで残るレビュー履歴。**
「2 週間前、モデルは `src/auth.ts` について何と言ったか？」 ——ccg の追記専用台帳がこれに答えます。ステートレスなツールには不可能です。

## インストール

どちらかを選択：

```bash
# npm (推奨)
npx @mcgrapeng/ccg install

# または curl ワンライナー、Node 不要
curl -fsSL https://raw.githubusercontent.com/mcgrapeng/ccg/main/scripts/curl-install.sh | bash
```

次に AI CLI を一度だけインストール：

```bash
npm i -g @openai/codex @google/gemini-cli
echo 'export GEMINI_API_KEY="<your-key>"' >> ~/.zshenv
```

確認：

```bash
npx @mcgrapeng/ccg doctor      # Codex / Gemini / API key をチェック
npx @mcgrapeng/ccg about       # 7 層の機能と現在の環境状態を表示
```

## 使い方

変更のある任意の git リポジトリで Claude Code を開き、入力：

```
/ccg
```

ccg は自動で：

1. アクティブな diff をキャプチャ（worktree → staged → upstream → origin-head の 4 段階フォールバック）
2. リスクを採点し `cost` / `balanced` / `quality` モデルを自動選択
3. Codex + Gemini に同じプロンプトを並列で実行
4. 3 セクションに合成：

```
═══ AGREEMENT (N)  ═══   両方とも指摘 — 低シグナル、各 1 行のみ
═══ DIVERGENCE (M) ═══   ★ ccg の核心価値
                          - Codex: X と言った
                          - Gemini: Y と言った
                          - Claude の判定: ___ もしくは NEEDS HUMAN DECISION
═══ BLINDSPOT (≤2) ═══  どちらも見ていないが Claude が疑う — 控えめに
═══ VERDICT ═══         merge / fix-required / discuss
```

その後 `ccg_ledger_record` が JSONL 1 行を追記。`ccg_cleanup` が作業ディレクトリを削除します。

## 設定（デフォルトで通常は十分）

モードとモデルの選択は自動です。必要なときだけ上書き：

```bash
CCG_MODE=quality /ccg          # 任意の diff で quality モデルを強制
CCG_CODEX_MODEL=o3 /ccg        # 1 つのモデルだけ上書き
CCG_NO_CACHE=1 /ccg            # この呼び出しのみ 24h キャッシュをスキップ
```

全ての設定は [アーキテクチャ §5 拡張ポイント](docs/ARCHITECTURE.md#5-extension-points) にあります。よく使うもの：

| 変数 | デフォルト | 用途 |
|---|---|---|
| `CCG_MODE` | `auto` | `auto` / `cost` / `balanced` / `quality` |
| `CCG_CACHE_TTL_HOURS` | `24` | キャッシュ TTL |
| `CCG_MAX_PROMPT_KB` | `100` | 1 回あたりのプロンプトサイズ上限 |

コスト目安（USD / 呼び出し、キャッシュヒット後）：

| モード | Codex | Gemini | 標準コスト |
|---|---|---|---|
| `cost`     | gpt-5-nano  | gemini-2.5-flash-lite | ~$0.0007 |
| `balanced` | gpt-5-mini  | gemini-2.5-flash      | ~$0.0046 |
| `quality`  | gpt-5       | gemini-2.5-pro        | ~$0.0440 |

累計支出はいつでも確認可能：

```bash
source ~/.claude/commands/ccg.sh
ccg_usage --this-month
```

## 適さない用途

- Claude Code 以外の IDE（[zen-mcp-server](https://github.com/BeehiveInnovations/zen-mcp-server) を試してください）
- 静的解析の置き換え（Semgrep / CodeQL と併用してください）
- 全 PR で自動実行（ccg はトリアージツール、ボットではありません）
- ストリーミング出力やマルチターン会話

## アーキテクチャとコントリビュート

ccg は **7 層** で構成されており、「分岐検出」は最上位 1 層にすぎません。下の 6 層（キャッシュ、台帳、使用量、リスクルーティング、スマート diff、安全な CLI スケジューリング）はそれぞれ独立して実問題を解決します。`ccg.sh` を変更する前に [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) を読んでください。

テスト：

```bash
bash tests/test_ccg.sh                # 99 個の回帰テスト、~31s
REAL_CLI=1 bash tests/test_ccg.sh     # +2 個のライブ API テスト（課金あり）
```

## ライセンスと謝辞

MIT —— [LICENSE](LICENSE) を参照。

[oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) の元々の `/ccg` コンセプト · Claude Code · OpenAI Codex CLI · Google Gemini CLI を基に構築。
