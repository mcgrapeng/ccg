# ccg — Code Divergence Detector

> Claude Code のスラッシュコマンド。一度インストールして、diff の上で `/ccg` と入力するだけ。

[![Tests](https://img.shields.io/badge/tests-99%20passing-brightgreen.svg)]()
[![npm](https://img.shields.io/npm/v/@mcgrapeng/ccg.svg)](https://www.npmjs.com/package/@mcgrapeng/ccg)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[English](README.md) ｜ [简体中文](README.zh-CN.md) ｜ **日本語** ｜ [한국어](README.ko.md)　·　[アーキテクチャ →](docs/ARCHITECTURE.ja.md)

---

## ccg とは

あなたは `auth/login.go` を編集し終え、マージしようとしています。念のため確認したい。今の選択肢は 3 つしかなく、全て欠点があります：

- **単一モデルのレビュー**（Copilot、Cursor `/review`、Aider）は **1 つの視点** しか提供しません。Claude が timing attack を見逃せば、あなたも一緒に見逃します。
- **複数モデル集約ツール**（zen-mcp-server 等）は意見を **平均化** してしまい、優秀なモデル同士が意見を異にした箇所——人間が本当に助けを必要とする箇所——を覆い隠してしまいます。
- **手動の二重チェック** は時間が無限にあればやりますが、ありませんね。

ccg は Claude Code 用の `/ccg` スラッシュコマンドで、この 3 つを本当に解決します。任意の diff に対して：

1. 同じ prompt を **Codex（OpenAI）** と **Gemini（Google）** に並列で送信
2. **Claude** に両方のレポートを読ませ、**両者が意見を異にした箇所を浮かび上がらせる**——そこが人間の判断が必要な場所
3. コストを記録、リスクに応じて最安充足モデルを自動選択、過去のレビュー履歴を保持

**例え話**：別チームの 2 人のシニアエンジニアに同じ PR をレビューさせ、テックリードに統合させる：「ここは両方同意、ここは意見が分かれた——あなたが決めて、私の見解は以下」。

## いつ ccg を使うか

| シーン | 使う？ | 理由 |
|---|---|---|
| auth / 決済 / マイグレーション / 暗号関連の変更 | ✅ Yes | 訓練データが違うと検出するバグが違う。$0.04 の価値あり。 |
| 単独開発 / 2 人小チーム、第二レビュアーなし | ✅ Yes | "もう一対の目" に最も近い |
| 200 行 PR のマージ前最終チェック | ✅ Yes | リスクルーターが適切なモデルを自動選択 |
| 変数のリネーム | ❌ No | ���のまま commit |
| ドキュメント編集のみ | ❌ No | リスクルーターが ~$0.0007 に自動降格するが本当に不要 |
| 1 つのモデルとストリーミング対話したい | ❌ No | codex / gemini CLI を直接使う |

## なぜ ccg なのか（他ツールとの比較）

**1. 意見の相違こそがシグナル、ノイズではない。**
Codex が「`subtle.ConstantTimeCompare` を使え」と言い、Gemini が「bcrypt は既に恒定時間、それは cargo-cult」と言った時、**そここそ考える必要がある場所**。他のツールはこれを「timing attack に注意」とぼやかして混ぜます。ccg は両者の生の言葉を見せます。

**2. コスト可視化が組み込み。**
Codex / Gemini CLI は支出を教えません。ccg は全呼び出しを記録、リスクに応じて最安充足モデルを自動選択（リスクルーティング）、同一プロンプトは 24h キャッシュでゼロコスト。`ccg_usage --this-month` が「今月いくら使った？」に即答。

**3. セッションを跨いで残るレビュー履歴。**
「2 週間前、モデルは `src/auth.ts` について何と言ったか？」——ccg の追記専用台帳がこれに答えます。ステートレスなツールには不可能です。

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

## 使い方の完全な例

`auth/login.go` を編集したとします：

```go
// before                                            // after
func Login(user, pw string) bool {                   func Login(user, pw string) bool {
    u := lookupUser(user)                                u := lookupUser(user)
-   return u.Hash == sha256.Sum256([]byte(pw))           hashed, err := bcrypt.GenerateFromPassword([]byte(pw), 12)
+                                                        if err != nil { return false }
+                                                        return subtle.ConstantTimeCompare(u.Hash, hashed) == 1
}
```

Claude Code を開いて入力：

```
/ccg
```

約 30 秒後に表示されるもの——**実際の出力例**、プレースホルダーではない：

```
📍 範囲：worktree · 1 ファイル · +4 -1 行
🎯 モード：quality  (risk=65 · auth+35 size>0+5 crypto-mention+25)
🩺 両レビュアー正常：Codex ✓ · Gemini ✓
💰 コスト：$0.041

═══ AGREEMENT (2) — 両方が指摘、低シグナル ═══
• auth/login.go:3 — sha256 はパスワードハッシュでない；bcrypt が正しい
• auth/login.go:5 — bcrypt エラーは明示的に処理（やっている）

═══ DIVERGENCE (1) — 両モデルが意見不一致 ★ あなたが決定 ═══

▸ auth/login.go:6 — bcrypt ハッシュの比較方法
  🔵 Codex： 「bcrypt を使っても timing attack を防ぐため
              subtle.ConstantTimeCompare でラップせよ」
  🟢 Gemini：「bcrypt.CompareHashAndPassword は既に恒定時間。
              ラッピングは cargo-cult、長さ不一致 panic を生み得る」
  ⚖️ Claude： Gemini が正しい。bcrypt.CompareHashAndPassword が標準的な
              比較方法；その生の出力に対する ConstantTimeCompare は
              カテゴリ誤り——「ハッシュした pw」と「保存されたハッシュ」を
              比較しているが、bcrypt は毎回新しいソルトを使うので
              直接比較は常に false を返す。
  ➡️ アクション：ConstantTimeCompare 行を以下に置換：
              `err := bcrypt.CompareHashAndPassword(u.Hash, []byte(pw))`
              `return err == nil`

═══ BLINDSPOT (1) — どちらも見ていないが Claude が疑う ═══
• エラーパス：bcrypt エラー時に false を返すのは呼び出し側には正しいが、
  インフラエラー（bcrypt OOM 等）を静かに飲み込む。ログを追加せよ。

═══ VERDICT: fix-required ═══
現在の比較ロジックは正しいパスワードを常に拒否する。DIVERGENCE の
アクションを適用 + エラーログ追加で、マージ可能。
```

### この出力をどう読むか

| セクション | 意味 | 何をすべきか |
|---|---|---|
| **AGREEMENT** | Codex と Gemini の両方が同じ問題を指摘。単一の Claude でも見つかる可能性が高い——**新規情報量低**。 | 流し読み、未修正なら修正。 |
| **DIVERGENCE** ★ | 両モデルが意見不一致。**これが ccg の存在意義**。Claude の「アクション」行が推奨をくれるが、最終判断はあなた。 | 注意深く読む、Claude の判断を受け入れるかオーバーライド。 |
| **BLINDSPOT** | どちらのモデルも気付かなかったが Claude が合成時に疑った。**控えめに**——1 回あたり最大 2 件。 | ヒントとして扱う、聖典ではない。 |
| **VERDICT** | `merge` / `fix-required` / `discuss`。1 行サマリー。 | マージゲートとして使用。 |

レビュー後、`ccg_ledger_record` が JSONL 1 行を台帳に書きます。2 週間後：

```bash
source ~/.claude/commands/ccg.sh
ccg_ledger_query "auth/login.go"
# → "auth/login.go: 3 レビュー · 最新 2026-05-23 (fix-required) · 2026-05-09 (merge) · 2026-04-28 (discuss)"
```

## 設定（デフォルトで通常は十分）

モードとモデルの選択は自動です。必要なときだけ上書き：

```bash
CCG_MODE=quality /ccg          # 任意の diff で quality モデルを強制
CCG_CODEX_MODEL=o3 /ccg        # 1 つのモデルだけ上書き
CCG_NO_CACHE=1 /ccg            # この呼び出しのみ 24h キャッシュをスキップ
```

よく使うもの（全部は [アーキテクチャ §5](docs/ARCHITECTURE.ja.md#5-拡張ポイント)）：

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

ccg は **7 層** で構成されており、「分岐検出」は最上位 1 層にすぎません。下の 6 層（キャッシュ、台帳、使用量、リスクルーティング、スマート diff、安全な CLI スケジューリング）はそれぞれ独立して実問題を解決します。`ccg.sh` を変更する前に [docs/ARCHITECTURE.ja.md](docs/ARCHITECTURE.ja.md) を読んでください。

テスト：

```bash
bash tests/test_ccg.sh                # 99 個の回帰テスト、~31s
REAL_CLI=1 bash tests/test_ccg.sh     # +2 個のライブ API テスト（課金あり）
```

## ライセンスと謝辞

MIT —— [LICENSE](LICENSE) を参照。

[oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) の元々の `/ccg` コンセプト · Claude Code · OpenAI Codex CLI · Google Gemini CLI を基に構築。
