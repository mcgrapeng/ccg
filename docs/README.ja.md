# ccg — Code Divergence Detector

> Codex と Gemini があなたのコード上で意見を異にした箇所を浮かび上がらせる——そこが、あなたが判断を下す必要がある場所。
> 
> Claude Code のスラッシュコマンド。一度インストールして、diff の上で `/ccg` と入力するだけ。

[![Tests](https://img.shields.io/badge/tests-111%20passing-brightgreen.svg)]()
[![npm](https://img.shields.io/npm/v/@mcgrapeng/ccg.svg)](https://www.npmjs.com/package/@mcgrapeng/ccg)
[![npm downloads](https://img.shields.io/npm/dm/@mcgrapeng/ccg.svg)](https://www.npmjs.com/package/@mcgrapeng/ccg)
[![GitHub stars](https://img.shields.io/github/stars/mcgrapeng/ccg.svg?style=social&label=Star)](https://github.com/mcgrapeng/ccg/stargazers)
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

## ccg の能力セット（5 つのコア機能）

1. **並行レビュー** — 同じ prompt を Codex と Gemini に同時送信
2. **分岐検出** — Claude は両者が意見を異にした箇所を浮かび上がらせる（同意した箇所ではなく）
3. **リスク認識ルーティング** — 自動的に diff をスコアリングし、cost / balanced / quality モードを選択
4. **コスト追跡** — すべての呼び出しを記録；24h キャッシュで繰り返しレビューは無料（$0.00）
5. **レビュー記憶** — 過去のレビューを保存；次回レビューは自動的に履歴を注入するため、再発パターンが浮かび上がり、セッション間で消えない

## いつ ccg を使うか

トリガーは **領域** ではなく **感覚** です。書き終えた自分の diff を見ながら、心の中で次のように考えていたら、ccg の場面です：

| 心の中の独り言 | ccg を使う？ |
|---|---|
| 「これを間違えたら午前 3 時に呼び出される」 | ✅ Yes |
| 「これは判断問題 — 明らかに正しい答えはない」 | ✅ Yes |
| 「誰か他に先に見てほしい」 | ✅ Yes |
| 「変数の名前を変えただけ」 | ❌ No |
| 「ドキュメント変更だけ」 | ❌ No |
| 「単一モデルとストリーミング対話したい」 | ❌ No（CLI を直接使う） |

**ドメイン横断の実例** —— auth / 暗号ではないが、すべて「シニア 2 人が意見を異にしうる」瞬間：

- **ソーシャルプラットフォーム** —— フィードに新エンゲージメントシグナルを追加して再ランキング · コメントツリー fan-out 戦略 · A/B テストバケッティングロジック · 反スパムレート制限ポリシー · フォロー関係のグラフ DB スキーマ
- **データ / AI インフラ** —— embedding モデル切替（再インデックスする？） · chunking 戦略変更 · RAG 検索スコアリング · prompt injection 防御レイヤリング
- **フロントエンド** —— 新ページに SSR vs ISR vs RSC · キャッシュ無効化戦略 · 状態管理リファクタリング · アクセシビリティのトレードオフ
- **API 設計** —— cursor vs offset ページング · エラーレスポンスモデル · バージョニング方式 · 冪等性キーの扱い
- **分散システム** —— タイムアウト / 再試行ポリシー · cache TTL vs イベント駆動無効化 · partition tolerance トレードオフ · leader election のセマンティクス
- **データベース** —— マルチステップマイグレーションの順序 · ホットパスのインデックス選択 · トランザクション分離レベル · 論理削除 vs 物理削除
- **セキュリティ** —— ええ、auth / 暗号 / 決済もここ —— ただし多くのドメインの 1 つに過ぎない

**パターン**：「妥当なエンジニアが選択肢 A を選ぶこともあれば、別の妥当なエンジニアが B を選ぶこともある」変更 —— これが分岐検出が $0.04 を稼ぐ瞬間。

## なぜ ccg なのか（他ツールとの比較）

**1. 意見の相違こそがシグナル、ノイズではない。**
Codex が「`subtle.ConstantTimeCompare` を使え」と言い、Gemini が「bcrypt は既に恒定時間、それは cargo-cult」と言った時、**そここそ考える必要がある場所**。他のツールはこれを「timing attack に注意」とぼやかして混ぜます。ccg は両者の生の言葉を見せます。

**2. コスト可視化が組み込み。**
Codex / Gemini CLI は支出を教えません。ccg は全呼び出しを記録、リスクに応じて最安充足モデルを自動選択（リスクルーティング）、同一プロンプトは 24h キャッシュでゼロコスト。典型的な支出：意味のある分岐検出ごとに $0.02-0.15——シニアエンジニアのコードレビューは $200-300 の時間コストがかかります。分岐検出は最初の contentious PR で元が取れます。`ccg_usage --this-month` でいつでも累計を確認できます。

**3. セッションを跨いで残るレビュー履歴——*しかも次のレビューに供給される*。**
「2 週間前、モデルは `src/auth.ts` について何と言ったか？」——ccg の追記専用台帳がこれに答えます。ステートレスなツールには不可能です。v3.2 から、同じファイルに触れた過去のレビューが次のプロンプトに自動注入されるため、再発パターンが浮かび上がり、セッション間で消えなくなります。未解決の `fix-required` も失われません。

## インストール

ワンライナー（Node 不要）：

```bash
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

## 分岐検出の例（ccg が捕捉する一般的パターン）

分岐は全領域で発生し、セキュリティだけではありません。異なるドメインでの分岐の様子を見てください：

**暗号/セキュリティ（古典的）**
```
▸ auth/login.go:6 — bcrypt ハッシュの比較方法
  🔵 Codex： 「subtle.ConstantTimeCompare でラップせよ、timing 攻撃防ぐため」
  🟢 Gemini：「bcrypt は既に恒定時間。ラッピングは cargo-cult」
  ⚖️ 決定者：脅威モデルに基づいてあなたが選択
```

**フロントエンド（キャッシュ戦略）**
```
▸ cache.ts:42 — 書き込み時に無効化、またはイベント駆動無効化？
  🔵 Codex： 「写入时总是重验（予測可能、よりシンプル）」
  🟢 Gemini：「イベント購読の方が拡張性良い；書き込み時無効化はキャッシュストーム原因」
  ⚖️ 決定者：トラフィックパターンと SLA に基づいてあなたが選択
```

**API 設計（ページング）**
```
▸ pagination.go:18 — cursor vs offset ページング？
  🔵 Codex： 「offset はシンプル、ユーザーは慣れている」
  🟢 Gemini：「cursor は O(1)、offset は削除時 O(n)；成長率で選べ」
  ⚖️ 決定者：データ変動频度と成長予測に基づいてあなたが選択
```

この分岐が ccg が元を取る箇所です。下に完全な深掘り例があります。

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
| **VERDICT** | `merge` / `fix-required` / `discuss`。1 行サマリー。 | **マージゲートとして使用。** |

レビュー後、`ccg_ledger_record` が JSONL 1 行を台帳に書きます。2 週間後：

```bash
source ~/.claude/commands/ccg.sh
ccg_ledger_query "auth/login.go"
# → "auth/login.go: 3 レビュー · 最新 2026-05-23 (fix-required) · 2026-05-09 (merge) · 2026-04-28 (discuss)"
```

同じレビューはリポジトリ内の `.ccg/reports/<sha>_<utc-timestamp>.md` にも自己完結型の Markdown レポートとして保存されます。Claude Code を閉じても、再実行せずに完全な出力（synthesis + Codex 生 + Gemini 生）を後から読めます。無効化は `CCG_NO_REPORT=1`、保存先変更は `CCG_REPORT_DIR=<path>`。（レポートを git に入れたくなければ `.ccg/` を `.gitignore` に追加するのを推奨。）

## 四阶段能力集

CCG は 4 つのステージで構成され、各ステージは明確な目的、モデル戦略、安全保証を持ちます。

### Stage 1 — コードレビュー（`ccg review`）

**目的**：diff にバグ、セキュリティ問題、品質問題がないかを発見。

**モデル戦略**：
- **2 つのモデルを並列実行**（デフォルト Codex + Bailian）
- ユーザーが `CCG_PROVIDERS` で上書き可能
- モデル選択は現在の `CCG_MODE` に依存（詳細は[モデル戦略](#設定)を参照）

**出力**：合成結果は以下のように分類：
- `AGREEMENT` — 両レビュアーが同じ問題を指摘（高信頼度）
- `DIVERGENCE` — レビュアーが意見不一致（人間の判断が必要）
- `BLINDSPOT` — 一方が見落とした別の発見（最高価値）

**パイプライン**：
```
git diff → リスク評分 → モード選択
   → 並列：[Codex レビュー + Bailian レビュー]
   → 合成 → AGREEMENT | DIVERGENCE | BLINDSPOT
```

**安全保証**：
- Prompt injection 防御（信頼不可能な内容をマーク、各呼び出しで独立した nonce）
- 大 diff 警告（>200KB は context 超過の可能性）
- Cleanup trap（Ctrl+C で子プロセス終了）
- 部分失敗対応（1/2 成功 → 続行かつ警告）

---

### Stage 2 — 自動コミット（`ccg commit`）

**目的**：評審を通過したコードのみが git 履歴に入る——**追加の LLM 呼び出しなし**。

**🚫 Stage 2 ゼロ LLM 呼び出し**——Stage 1 の評審結果（synthesis verdict）を直接再利用。

**モデル戦略**：なし。前ステップの `.git/ccg/last-review.json` を読取、diff ハッシュをバイト単位で検証して、改ざん後の隠れた提交を防止。

**Verdicts**（Stage 1 から継承）：
| Verdict | 動作 |
|---|---|
| `merge` | ✅ コミット許可 |
| `discuss` | ⚠️ デフォルト許可（`CCG_GATE_DISCUSS=block` で阻止可）|
| `fix-required` | ❌ コミット拒否（修正と再評審が必須）|

**パイプライン**：
```
ステージ済み diff → SHA256 計算 → last-review.json 内のハッシュと比較
  → 完全一致 → verdict 読取
    ✅ merge/discuss → コミット
    ❌ fix-required → 拒否（前回の評審欠陥を出力）
  → ハッシュ不一致 → diff 改ざん、コミット拒否（再評審要求）
```

**安全保証**：
- コミットゲート完全確定性：API 呼び出しなし、タイムアウトなし、幻覚なし
- diff 改ざん検出：ハッシュ不一致で即座に拒否
- 一度の評審、確実な実行：API グリッチで判定が弱くならない

---

### Stage 3 — AI マージ（`ccg merge <target>`）⭐ **核心競争力**

**目的**：プロフェッショナルで確実なマージコンフリクト解決。

**モデル戦略**：
- **Bailian が主要なソルバー**（コード信頼性最高）
- Bailian 失敗時は **Codex + Gemini 並列** へ降格
- 全て失敗 → `NEEDS_HUMAN_DECISION`

**コンフリクト分類**（`content` のみ AI へ）：
| タイプ | 処理方法 |
|---|---|
| `content` | AI で解決 |
| `binary` | 人工へ |
| `submodule` | 人工へ |
| `symlink` | 人工へ |
| `delete_modify` | 人工へ |
| `both_deleted` | 人工へ |
| `added_one_side` | 人工へ |
| `both_added` | 人工へ |

**パイプライン**：
```
checkout target → バックアップブランチ作成 → git merge --no-commit
  ↓ (各コンフリクトファイル)
  分類 → <<<<<<< ブロック解析
  → Bailian で解決
    ↓ (失敗)
    Codex + Gemini 並列
    ↓ (全て失敗)
    NEEDS_HUMAN_DECISION
  → 検証（markdown fence なし、コンフリクトマーク なし、内容非空）
  → アトミックファイル書き直し（mktemp + mv、パーミッション保持）
  → git add（解決時）
  ↓
  commit（全て解決時）| コミットなし（人工対応必要時）
```

**安全保証**：
- マージ前にバックアップブランチ作成（`ccg-backup/<target>-<timestamp>-<pid>-<rand>`）
- ワークツリー非クリーン、detached HEAD、操作中 → 拒否
- リモートフォーク → 拒否
- 各コンフリクトで独立 nonce（OURS/THEIRS インジェクション防止）
- 解決内容検証（markdown fence なし、コンフリクトマーク なし、内容非空）
- アトミックファイル置換（`mktemp` + `mv`）
- ファイルパーミッション保持、symlink 書き込み拒否
- **決してコード消失しない** —— 失敗は NEEDS_HUMAN へ
- リアルタイム進捗：`[3/12] src/auth.js ... ✅ 解決済み`
- 最大コンフリクト数制限（デフォルト 50、`CCG_MERGE_MAX_CONFLICTS` で上書き可）

---

### Stage 4 — Push 前分析（`ccg push <remote> <branch>`）

**目的**：push 前にユーザーへ包括的でグラフィカルなレポート提供——賢明な判定を可能に。

**モデル戦略**：Bailian LLM でリスク評分（失敗時はルールエンジンへ降格）。

**レポート内容**：
```
╔══════════════════════════════════════════════════════════╗
║          🚀  CCG Pre-Push Analysis Report  🚀            ║
╚══════════════════════════════════════════════════════════╝

  📍 ブランチ / リモート / HEAD / 作者 / 時刻

  ┌─ コミット概要 ─────────────────────────────────────────┐
  │  先行: N 個 / 後行: M 個
  └────────────────────────────────────────────────────────┘

  📝 品質マーク付きコミット（✓ 規範的 / ⚠️ WIP）

  ┌─ コード変更 ─────────────────────────────────────────┐
  │  ファイル / 追加 / 削除 + ビジュアル棒グラフ
  └────────────────────────────────────────────────────────┘

  📂 ファイル分類：💻 コード / 🧪 テスト / 📖 ドキュメント / ⚙️ 設定

  🚨 機密ファイル検出（.env、*.pem、credentials など）

  ┌─ リスク評価 ─────────────────────────────────────────┐
  │  スコア：🔴 CRITICAL (85) — auth + payment
  │  [████████████████████████████████████████████]
  └────────────────────────────────────────────────────────┘

  📊 Push 品質スコアカード：
     ✅ 規範的なコミットメッセージ
     ✅ コード変更に伴うテスト
     ❌ 機密ファイル含む
     ✅ リモートと同期
     ⚠️  高リスク——慎重な審査が必要

  ┌─ 推奨 ──────────────────────────────────────────────┐
  │  🔴 NOT RECOMMENDED (3/5 合格)
  └────────────────────────────────────────────────────────┘
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
| `CCG_NO_HISTORY` | `0` | `1` に設定してレビュー履歴注入を無効化 |
| `CCG_HISTORY_MAX` | `3` | 注入する過去レビューの最大数 |

コスト目安（USD / 呼び出し、キャッシュヒット後）：

| モード | Codex | Gemini | 標準コスト |
|---|---|---|---|
| `cost`     | gpt-5-nano  | gemini-2.5-flash-lite | ~$0.0007 |
| `balanced` | gpt-5-mini  | gemini-2.5-flash      | ~$0.0046 |
| `quality`  | gpt-5       | gemini-2.5-pro        | ~$0.0440 |

累計支出はいつでも確認可能：

```bash
source ~/.claude/commands/ccg.sh
ccg_usage --this-month     # 今月を provider 別に
ccg_usage --all            # 累計
```

## 適さない用途（スコープの境界）

ccg は高度な判断が必要なコードレビュー用に設計されています。以下の*代替品ではありません*：

- **静的解析** — Semgrep / CodeQL と並行使用；代替ではない
- **Lint またはフォーマッタ** — スタイルチェック用；ccg はアーキテクチャを見る
- **自動ゲーティング** — ccg はトリアージツール、ボットではない（すべての PR で自動実行しないこと）
- **ストリーミング対話** — ccg は one-shot；マルチターン会話は Codex / Gemini CLI で直接使用
- **Claude Code 以外の IDE** — [zen-mcp-server](https://github.com/BeehiveInnovations/zen-mcp-server) を VS Code / JetBrains で試してください

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
