# アーキテクチャ

> 対象読者: コントリビューターおよびインテグレーター。`ccg` を使うだけなら [README.ja.md](../README.ja.md) を読んでください。`ccg` を**変更したい**なら本書を読んでください。
>
> 本書は `ccg.sh` と `bin/ccg.js` のコードが実際に行うことを記述します。食い違いがあれば `grep -n '^ccg_\|^_ccg_' ccg.sh` で関数名を照合してください。
>
> 翻訳同期について: 本翻訳は英語版 [docs/ARCHITECTURE.md](ARCHITECTURE.md) を追随します; 遅れがあれば英語版を優先してください。

[English](ARCHITECTURE.md) ｜ [简体中文](ARCHITECTURE.zh-CN.md) ｜ **日本語** ｜ [한국어](ARCHITECTURE.ko.md)

---

## 1. ccg とは

ccg は **Claude Code 内から Codex + Gemini CLI を呼び出すための production-grade なオーケストレーター** です。

「Code Change Guardian」は 6 つの下層に乗った [L7 のプロダクトフック](#l7--分岐合成claude-側) に過ぎません — 各下層は、slash command から LLM CLI に shell-out する際に直面する独立した実問題を解決しています。

> L7 を消しても ccg は依然有用（キャッシュ、台帳、使用量、リスクルーティング）。
> L1 を消すと ccg は安全でなくなる。
> プロダクトストーリーが売るのは L7。エンジニアリング実体は L1–L6。

---

## 2. 7 層アーキテクチャ

```
┌─────────────────────────────────────────────────────────────────────────┐
│  L7  Divergence synthesis  (ccg.md prompt 内に存在, Claude が実行)       │
│      AGREEMENT / DIVERGENCE / BLINDSPOT 3-section output                │
├─────────────────────────────────────────────────────────────────────────┤
│  L6  Review ledger          ccg_ledger_record / ccg_ledger_query        │
│      JSONL append-only, grep 可能, 機密リダクション済み                  │
│      + ccg_persist_report → <repo>/.ccg/reports/<sha>_<ts>.md            │
│      + ccg_ledger_context → history.txt を次のプロンプトに注入           │
├─────────────────────────────────────────────────────────────────────────┤
│  L5  Risk-aware routing     ccg_risk_score                              │
│      Pure-rule scoring on diff → cost / balanced / quality              │
├─────────────────────────────────────────────────────────────────────────┤
│  L4  Usage telemetry        ccg_actual / ccg_usage / _ccg_log_usage     │
│      USD-aware, model-aware, month-aware                                │
├─────────────────────────────────────────────────────────────────────────┤
│  L3  Smart diff capture     ccg_diff_capture                            │
│      4-level fallback: worktree → staged → upstream → origin-head       │
├─────────────────────────────────────────────────────────────────────────┤
│  L2  Content-addressed cache _ccg_cache_lookup / _ccg_cache_store       │
│      SHA-256 prompt+model key · 24h TTL · 失敗呼び出しはキャッシュ不可    │
├─────────────────────────────────────────────────────────────────────────┤
│  L1  Safe CLI scheduling    _ccg_run_with_timeout / _ccg_redact /       │
│      ccg_cleanup / _ccg_check_prompt_size / mktemp 700 isolation        │
└─────────────────────────────────────────────────────────────────────────┘

       ↑                                       ↑
   bin/ccg.js                            ~/.claude/commands/ccg.sh
   (Node CLI: install/about/doctor)      (Claude が source する Bash コア)
```

各層は単独で呼び出せます。`bash -c 'source ccg.sh; ccg_risk_score diff.txt'` は L7 に触れずに動きます。

---

## 3. 各層詳細

### L1 — Safe CLI scheduling
**問題:** shell-out で `codex < prompt.txt` を素朴に実行することは 5 つの面で安全でない: タイムアウト無し、バックグラウンドの子プロセスの stdin が `/dev/null` にリダイレクトされる、API キーがログに漏れる、prompt サイズが無制限、クラッシュ時に temp ディレクトリが残留。

**解法:**
- `_ccg_run_with_timeout` — bash 3.2+ 互換ポータブルタイムアウト。`timeout` / `gtimeout` 優先、純 bash ポーリング + 壁時計デッドラインへフォールバック。重要: バックグラウンドの子に対する明示的な `<&0` で stdin を保持（bash デフォルトの async-stdin-to-devnull は有名な落とし穴）。
- `_ccg_redact` — 7 つの正規表現パターン: `sk-*`, `AIza*`, `Bearer *`, JWT 形式, `ghp_*`, `AKIA*`, Slack `xox[bpoas]-*`。加えて URL クエリ文字列。すべての stderr キャプチャ + ledger synthesis 書き込みに適用。
- `ccg_cleanup` — `rm -rf` の前に相対パス、`..`、シンボリックリンク、`ccg.` 以外の basename を拒否。UID-scoped な孤児ディレクトリスキャン（保守的な 24h 閾値）も実施。
- `_ccg_check_prompt_size` — 呼び出しあたり 100KB のデフォルト上限。「5MB diff を誤って流して $5 請求された」を防ぐ。
- `ccg_init` — `mktemp -d` をモード 0700 で。並行呼び出しで衝突しない。

**この層を削ると:** ccg は機密を漏らし `/tmp` を散らかす `echo prompt | codex` ラッパに成り下がる。出荷不可。

---

### L2 — Content-addressed cache
**問題:** 同じ diff を繰り返しデバッグする（特に ccg 自身を反復する）と、同じ prompt に二重課金される。codex CLI も gemini CLI も「これは前回と同じ」という概念を持たない。

**解法:**
- Key = `sha256(prompt_contents) + model_id`。同一 prompt + 同一モデル = 必ずヒット。
- Value = LLM 出力フル。
- TTL = 24h (`CCG_CACHE_TTL_HOURS` で設定可)。
- **失敗の分離:** 呼び出しが `_FAIL=` を返すか空の場合、キャッシュ**しない**。さもなくば一時的な 503 が 24h キャッシュを汚染する。
- `$XDG_CACHE_HOME/ccg/cache/` に格納。いつでも `rm -rf` 安全 — 最悪 1 回再支払い。

**この層を削ると:** デバッグループのコストが約 5 倍。安全ではなくなるわけではないが、高い。

---

### L3 — Smart diff capture
**問題:** `git diff` は未コミット変更しか見せない。`git commit` した瞬間 `cursor /review` のようなツールは「レビューするものなし」と言う。しかし**ブランチが upstream より進んでいる時こそ最も重要なレビュー窓**だ — マージ直前。

**解法:** `ccg_diff_capture <out_file>` が 4 つの source を順に試す:

| 順序 | Source | 検出条件 |
|---|---|---|
| 1 | `worktree` | `git diff HEAD` の出力が非空 |
| 2 | `staged` | `git diff --cached` の出力が非空 |
| 3 | `upstream:<branch>` | `git rev-parse @{u}` が解決 AND `git diff @{u}` が非空 |
| 4 | `origin-head` | `git rev-parse origin/HEAD` が解決 AND `git diff origin/HEAD` が非空 |

選択された source は `CCG_DIFF_SOURCE` 経由で呼び出し側（L7 の Claude）に晒され、レビューにラベル付けできる。`CCG_DIFF_FAIL=not-a-git-repo` や `=empty-diff` も明示的な非エラー sentinel として返る。

**この層を削ると:** ccg は「コミット済み未プッシュコードのレビュー」能力を黙って失う — 単独開発者にとって最も価値ある窓を。

---

### L4 — Usage telemetry
**問題:** どの LLM CLI も「今月 $X 使った」を教えてくれない。`gh copilot` もない、`codex` もない、`gemini` もない。請求書まで見えない。

**解法:**
- `ccg_actual <prompt> <result> <provider>` — 呼び出し AFTER に測定。prompt + result の実バイト数を読み、`_ccg_tokens_from_chars`（`chars / 3.0` ヒューリスティック; 約 ±15%）でトークン換算、`_ccg_price(model, direction)` で乗算、`$XDG_DATA_HOME/ccg/usage.log` に 1 行追記。
- `ccg_usage [--this-month|--all|--since=YYYY-MM]` — ログ集計。
- **キャッシュヒットは $0.00 として記録**、累計の正確性を保つ。
- **失敗呼び出しはそもそも記録しない** — 何も返さない 503 を $0.001 とカウントすべきでない。

フォーマット: `<iso_ts> <provider> <model> in=<n> out=<n> usd=<float>`。意図的にプレーンテキスト — `grep` と `awk` が使える。

**この層を削ると:** コストが伝説と化す。月 $30 使って何に使ったか分からない。

---

### L5 — Risk-aware routing
**問題:** `cost` / `balanced` / `quality` モードには 60 倍の価格差（≈$0.0007 vs ≈$0.0440 / call）。毎回ユーザーに選ばせるのは UX 災害。LLM に自選させるとフィードバックループ。どちらも間違い。

**解法:** `ccg_risk_score <diff_file>` は純粋なルールスコアリング — この層には LLM なし。diff を読んで返す:

```
CCG_RISK_SCORE=72
CCG_RISK_MODE=quality
CCG_RISK_FILES=5
CCG_RISK_LINES=+340-12
CCG_RISK_REASONS=auth+40 sql_interp+30 size>300+15 docs_only-40
```

`ccg.sh:ccg_risk_score` のルール:

| シグナル | 重み | 検出方法 |
|---|---|---|
| パスが `auth\|payment\|migration\|crypto\|security` にマッチ | +25..+40 | パス正規表現 |
| 本文に `exec\|eval\|spawn` または `sql.*interp` | +20..+30 | patch 正規表現 |
| ハードコードされた URL/host 文字列 | +5 | 正規表現 |
| TODO/FIXME/HACK マーカー | +5 | 正規表現 |
| diff > 600 行 | +25 | 行数カウント |
| ファイル > 8 個 | +10 | hunk カウント |
| ドキュメント専用変更（`.md` / `.txt` / `.rst`） | **-40** | パス拡張子 |

**しきい値:** `< 20 → cost`, `< 60 → balanced`, `≥ 60 → quality`。

**なぜ LLM ではないか:** 透明性、ゼロコスト、PR 可能な重み。コミュニティのコントリビューターが `sed -i 's/+40/+50/' ccg.sh` して 1 行 PR を出せる。LLM スコアラーだとすべてのルーティング決定が不透明になる。

**この層を削ると:** ユーザーが毎回 `CCG_MODE` を手動で設定するか、常に `quality` を支払う。

---

### L6 — Review ledger
**問題:** すべての LLM CLI はステートレス。「2 週間前に Codex が `src/auth.ts` について何と言ったか」 — どのツールも答えられない。

**解法:** `ccg_ledger_record <workdir>` が `$XDG_DATA_HOME/ccg/ledger.jsonl` に JSONL 1 行を追記:

```json
{"ts":"2026-05-22T18:35:06Z","repo":"/path","branch":"feat-x","sha":"91c16ec",
 "mode":"quality","risk":72,"files":1,"lines":"+5-0","paths":["auth/login.go"],
 "synthesis":"divergence on constant-time compare; NEEDS HUMAN DECISION..."}
```

`synthesis` フィールドは Claude の結合判定の最初 ~400 文字 — 1000 件を grep するには十分短く、有用には十分長い。

`ccg_ledger_query` の操作:
- `ccg_ledger_query` — 最新 5 レビュー。
- `ccg_ledger_query "src/auth"` — このパスフラグメントに触れたレビュー、カウント + 最近 3 日付付き。

**最初の 50 件はゼロ価値。** 50 件超えるとステートレスツールには複製できない構造的記憶になる — 長期堀がここ。

**この層を削ると:** ccg が 100% ステートレスになる。毎レビューがゼロから始まる。L7 プロダクトストーリーは機能するが、長期差別化が消える。

#### L6 コンシューマー — `ccg_ledger_context`（ループを閉じる）

コンシューマーがなければ、ledger は書き込み専用の日記帳 — 「このファイルで以前何を議論したか」の答えが ledger にあるのに、毎回ゼロから始める。`ccg_ledger_context <diff_file>` が双方向化のもう半分:

1. diff から触れたパスを抽出（`diff --git a/<path>` ヘッダを解析）。
2. ledger を JSON-quoted `"<path>"` で固定文字列マッチ検索（`src/foo.ts` が `src/foobar.ts` と誤マッチしないように）。
3. 重複除去、`CCG_HISTORY_MAX`（既定 3）件まで取得（最新優先）。
4. `<workdir>/history.txt` へ構造化 Markdown として書き出し。

プロトコル層（`ccg.md` ステップ 2.5）が `history.txt` を Codex と Gemini のプロンプトに差し込み、両レビュアーはこう見る:

```
=== PRIOR REVIEWS (last 3 entries touching these paths) ===
- [2026-05-20T12:00:00Z] sha=ghi9abc mode=quality lines=+8-1
  paths: ["auth/login.go","auth/session.go"]
  synthesis: BLINDSPOT: error logging missing. fix-required.
...
```

なぜ重要か:
- **再発パターンが可視化される。**「前回 constant-time compare で揉めた — この PR は同じ話を繰り返してないか?」
- **未解決の `fix-required` が風化しない。**前回 verdict が `fix-required` で、今回の diff が解決していなければ、両レビュアーが指摘できる。
- **追加 LLM コール ゼロ。** `ccg_ledger_context` は純シェル（grep + sed）、ミリ秒オーダー。

**クロスシェル footgun（記録する価値あり）:** `ccg.sh` は Claude Code Bash tool を介してユーザーのデフォルトシェル（bash ユーザは bash、**zsh ユーザは zsh**）に source される。zsh の `local var`（**`=` なし**）は変数の現在値を stdout に出力する。`local` 宣言を while ループ本体に置いていたら、N 回目のイテレーションが N-1 回目の値を `history.txt` に漏らす。修正: ループで変化するローカルはすべて一度だけループ外で宣言。テスト 15.9 がこの回帰をロックする。

ノブ:
- `CCG_NO_HISTORY=1` でコンシューマーを完全に無効化（"単視点ベースライン"レビューが欲しいとき）。
- `CCG_HISTORY_MAX=<n>` で注入件数を制限（既定 3；大きすぎるとプロンプトサイズが膨らむ）。

**このコンパニオンを削ると:** ccg は完全ステートレスに戻る。L6 は書き込み専用日記帳に逆戻り — データ蓄積による堀は残るが、セッション内での複利は失われる。

---

### L7 — 分岐合成（Claude 側）
**問題:** 単一モデルのコードレビュー（Copilot、Cursor `/review`、Aider）は自分の盲点を見られない。賢いモデルでも 1 つの視点しか得られない。

**解法:** L7 のロジックは `ccg.md`（Claude が従う slash-command プロトコル）にあり、`ccg.sh` にはない。Claude は:

1. `ccg.sh` を source、`ccg_init` を呼んで workdir 確保。
2. `ccg_preflight` で Codex + Gemini 利用可能性チェック。
3. `ccg_diff_capture` (L3) で diff をマテリアライズ。
4. `ccg_risk_score` (L5) でモード選択。
5. prompt ファイルを 1 つ書く。同 prompt、別 consumer。
6. `ccg_codex` + `ccg_gemini` を**並列**で呼ぶ（同じ Claude message 内に 2 つの Bash tool 呼び出し）。
7. `ccg_actual` (L4) で実コスト記録。
8. 2 つの `[FINDING]` 形式出力を AGREEMENT / DIVERGENCE / BLINDSPOT セクションに**合成** — 合成は Claude の頭の中で起きる、コードではない。
9. `ccg_ledger_record` (L6) で synthesis 抜粋を書き込み。
10. `ccg_cleanup` (L1) で workdir 削除。

プロトコルは AGREEMENT の可視性を明示的に**ダウングレード**（各 1 行）し、DIVERGENCE を**プロモート**（完全展開 + "NEEDS HUMAN DECISION" タグ）。これはプロダクト意見: 合意 = 低シグナル、分岐 = 価値。

**この層を削ると:** ccg は依然有用 — コストテレメトリ、リスクルーティング、台帳クエリで個別関数を呼べる。しかしユーザー向け `/ccg` ワークフローは消える。

---

## 4. エンドツーエンドデータフロー

1 回の `/ccg` 呼び出しを時系列で、各ステップを担当層と共に:

```
USER が Claude Code で "/ccg" を入力
       │
       ▼
[Claude が ccg.md プロトコルを読む]                          ── protocol
       │
       ▼
ccg_init                                                     ── L1
  └─ mktemp -d -m 700 /tmp/ccg.XXXXXXXX
  └─ CCG_DIR=<path> 出力
       │
       ▼
ccg_preflight                                                ── L1
  └─ command -v codex / gemini, $GEMINI_API_KEY チェック
       │
       ▼
ccg_diff_capture "$CCG_DIR/diff.txt"                         ── L3
  └─ 4-level フォールバック → CCG_DIFF_SOURCE 出力
       │
       ▼
ccg_risk_score "$CCG_DIR/diff.txt"                           ── L5
  └─ ルール → CCG_RISK_SCORE + CCG_RISK_MODE 出力
  └─ Claude が CCG_MODE を適宜 export
       │
       ▼
ccg_ledger_context "$CCG_DIR/diff.txt"                       ── L6 コンシューマー
  └─ 同一パスに触れた過去レビューを ledger から grep
  └─ history.txt を書き出し（≤ CCG_HISTORY_MAX 件）プロンプト埋込用
       │
       ▼
[Claude が codex.prompt + gemini.prompt を書く — 同内容、     ── protocol
 history.txt がある場合は diff の前に付加]
       │
       ▼
ccg_codex   ─ 並列 ─  ccg_gemini                            ── L1 + L2
  │           │             │
  │   L1: timeout + redaction + stdin <&0
  │   L2: キャッシュルックアップ → ヒットなら返す、
  │      でなければ CLI 実行後キャッシュ保存（成功時のみ）
  │
  └─ 両方 *.result を書く
       │
       ▼
ccg_actual <prompt> <result> codex|gemini                    ── L4
  └─ トークン測定、USD 計算、usage.log に追記
       │
       ▼
[Claude が AGREEMENT/DIVERGENCE/BLINDSPOT を合成]            ── L7
  └─ (file, line, category, title) で [FINDING] ブロックを整列
  └─ 調停不能な分岐に "NEEDS HUMAN DECISION" を発行
       │
       ▼
[Claude が synthesis.txt を書く — 最初 400 文字]             ── protocol
       │
       ▼
ccg_ledger_record "$CCG_DIR"                                 ── L6
  └─ synthesis を JSON エンコード + リダクション → ledger.jsonl 追記
       │
       ▼
ccg_cleanup "$CCG_DIR"                                       ── L1
  └─ パストラバーサル安全な rm -rf
       │
       ▼
USER が見るもの: AGREEMENT / DIVERGENCE / BLINDSPOT + コスト行
```

典型的な総レイテンシ: モードにより 5–60 秒。コスト: $0.0007–$0.044、`CCG_MAX_PROMPT_KB` で上限。

---

## 5. 拡張ポイント

コントリビューター・インテグレーターが信頼できる契約。シグネチャ変更 = 破壊的変更。

### 5.1 新しいリスクスコアリングルールを追加 (L5)

`ccg.sh:ccg_risk_score` を編集、`score` を増分させ `reasons` に追記する `if/then` を追加。出力契約:

```
CCG_RISK_SCORE=<int 0..200>
CCG_RISK_MODE=<cost|balanced|quality>
CCG_RISK_FILES=<int>
CCG_RISK_LINES=+<adds>-<dels>
CCG_RISK_REASONS=<signal+weight signal+weight ...>
```

それ以外はこの出力を KEY=VAL 行としてパースする。

### 5.2 新しい LLM プロバイダーを追加 (L1 + L2)

例で言うパターン: `ccg_codex` と `ccg_gemini` は既に契約を実装。`ccg_claude` を追加するには:

1. `CCG_MODE` からモデル id を解決（`_ccg_resolve_codex_model` を模倣）。
2. 新プロバイダー名を含むキャッシュキーを構築。
3. `_ccg_cache_lookup` → ヒットなら result に書いて return。
4. `_ccg_run_with_timeout <timeout> <cli> -i <prompt> > <result> 2> <err>`。
5. 成功時 `_ccg_cache_store`。
6. `CCG_CLAUDE_OK=<size>` または `CCG_CLAUDE_FAIL=<reason>` を出力。

`ccg.md` のプロトコルを更新して新 helper を並列呼び出しに含める必要あり。

### 5.3 ストレージパス変更

すべてのパスは `_ccg_xdg_data_dir` / `_ccg_xdg_cache_dir` / `_ccg_xdg_config_dir` を経由。XDG Base Directory 仕様の `XDG_*_HOME` 環境変数で上書き、または個別ファイルに `CCG_USAGE_LOG` / `CCG_LEDGER_LOG` / `CCG_CACHE_DIR` を設定。

レガシー `~/.ccg/` は初回起動時に `_ccg_migrate_legacy` で移行 — 冪等、非破壊。

### 5.4 価格カスタマイズ

`_ccg_price <provider> <model> <direction>` が百万トークンあたり USD を返す。この表を編集すれば、次の `ccg_actual` 更新で即座に反映。

### 5.5 Synthesis 出力フォーマットカスタマイズ

合成は **Claude の頭の中** で起こり、`ccg.md` のテンプレートに従う。フォーマット変更（例: "SECURITY DIVERGENCE" セクション追加）には `ccg.md` のステップ 4 + 8 の prompt テンプレートを編集。Bash 側は synthesis をパースしない。

---

## 6. テストスイートが検証する不変条件

`tests/test_ccg.sh` が強制 — 最近のカウントで 121 テスト。これらに違反するコードは CI を壊す。

| 不変条件 | なぜ |
|---|---|
| `ccg_init` は常に `/tmp` または `$TMPDIR` 下に workdir を返し、`$HOME` 下には決して | クラッシュ安全性: 古い workdir がユーザーホームを汚さない |
| Workdir basename が `ccg.` で始まる | `ccg_cleanup` の allowlist の安全ガード |
| 失敗した CLI 呼び出しはキャッシュ・使用ログのいずれにも入らない | 一発の 503 がテレメトリ/キャッシュを汚染してはならない |
| stderr の機密はファイル書き込み前にリダクション | 7 パターンテーブル |
| `ccg_diff_capture` は空 diff で成功を返さない | 呼び出し側は非空ペイロードを仮定可能 |
| 空ファイルへのリスクスコア → 0 ではなく `_FAIL=` | 「0 リスク」と「シグナルなし」を区別 |
| Ledger 行は常に有効な JSON で `json.loads` でパース可能 | grep 可能 + パース可能 |
| `_ccg_run_with_timeout` は子プロセス終了コードを正確に保持 | 呼び出し側が 124（タイムアウト）と 1（CLI エラー）を区別できる |
| サブシェルは呼び出し側から `set -u` を継承するが未設定変数で壊れない | strict-mode ホストを有効化 |

---

## 7. 知っておくべき設計判断

最初変に見えるが特定の理由がある選択。将来のコントリビューターが「修正」しないよう記録。

| 判断 | 変に見える理由 | 真の理由 |
|---|---|---|
| Bash 3.2+ 互換（`mapfile`, `${var,,}` なし） | 現代 bash 5.x にはより良い構文 | macOS は GPL3 ボイコットで bash 3.2 を同梱。bash 5 は明示的な `brew install` が必要。ccg は箱出しで動く必要がある |
| キャッシュキーがモデル ID を含む、prompt ハッシュだけでない | 「同 prompt = 同結果」は真に見える | gpt-5-nano 結果としてキャッシュされた prompt は gpt-5 結果として提供できない。違うモデル、違う出力 |
| AGREEMENT セクションは意図的に各 finding 1 行 | より多くの詳細が一般に良い | 両 AI が同じ問題を flag したなら、あなたの単一 Claude もそうする可能性が高い。AGREEMENT に詳細を加えると DIVERGENCE シグナルが薄まる。これは UX 事故でなくプロダクト意見 |
| リスクスコアは純ルール、LLM 不使用 | LLM の方が賢いかも | コスト（ゼロ）、説明可能性（regex grep）、「PR 可能な重み」が限界精度向上を上回る。また、スコアラーの予測が何がレビューされるかに影響するフィードバックループを避ける |
| 失敗呼び出しを短期間でもキャッシュしない | 「ネガティブキャッシュはリトライ嵐を防ぐ」 | 失敗は通常「モデル名間違い」か「レート制限」。両方とも原因解決後すぐリトライしたい。失敗をキャッシュすると復旧が遅れる |
| `~/.ccg/` 移行は非破壊（`cp` でなく `mv`） | 孤児を残しうる | 旧 `~/.ccg/` ユーザーは env 変数で明示的に opt-in した; コピーは複製を残す。初回遭遇時に 1 度移動; ディレクトリは空のときのみ削除 |
| `ccg_cleanup` は `..` だけでなくシンボリックリンクも拒否 | 「パストラバーサル」は通常の脅威 | `mktemp` が既に `..` を防ぐ。シンボリックリンクが実際の攻撃面（クリーンアップ中の symlink swap の TOCTOU レース） |
| Slash command プロトコルは `ccg.md` に住む、コード内ではない | コード即ドキュメントの方が綺麗 | Claude が `ccg.md` をプロトコル仕様として読む。Bash コードは Claude の prompt にはなれない; これが slash command の本質。プロトコル（md）と原語（sh）を分けるのが正しい境界 |
| ループ本体内では `local var=`（`=` 付き）必須 | bash は `local var` と `local var=` を同じに扱う | zsh の `local var`（`=` なし）は変数の現在値を stdout に出力する。`ccg.sh` は zsh ユーザの Claude Code Bash tool が source する — 前回イテレーションの値が prompt や出力ファイルに漏れるのは本物のバグ。Test 15.9 がガード |

---

## 8. 非目標

ccg が意図的に**しない**こと、およびその理由。

- **ストリーミング出力なし。** Claude は合成前に Codex と Gemini の結果が両方完全に必要。ストリーミングは異なるプロトコル設計を要求する（コストも改善しない — 両レビュアーは完走する）。
- **マルチターン会話なし。** 各 `/ccg` 呼び出しは新鮮; `continuation_id` なし。反復したければ洗練した prompt で再度 `/ccg` を実行 — キャッシュで安価。
- **Claude Code 以外の IDE 統合なし。** Cursor / Continue / Cline ユーザーは [zen-mcp-server](https://github.com/BeehiveInnovations/zen-mcp-server) を見るべき。N 個の IDE への port を維持するテスト負担は価値なし。
- **静的解析なし。** 分岐検出 ≠ Semgrep / CodeQL。ccg を併用して、代替ではない。
- **「review bot」なし。** ccg は人間トリガー。全 PR で自動実行するとノイズになる; 「分諦ツール」ポジションを損なう。

---

## 9. 本当の堀がある場所

マーケティングポジション: **分岐検出** (L7)。

エンジニアリングの堀は **L6（台帳 + コンシューマー） + L4（使用量）**:

- L7 は 1 週間で複製可能。`gpt-5-mini` + `gemini-2.5-flash` を知るチームなら同じトリックを実行できる。
- L6 + L4 は**ユーザーごとに蓄積するデータ**を生む。ヘビーユーザーは 6 か月後、競合が複製できない個人的歴史記録を持つ — 競合は review #1 から始めなければならない。
- `ccg_ledger_context` コンシューマー（2026-05 追加）はそのデータをセッション内で**複利化**する: 各レビューは過去のレビューをコンテキストとして使う。これがなければ ledger は書き込み専用の日記帳; これがあれば、同じファイルへの各レビューは前回の肩の上に立つ。

何を先に強化するか優先順位を決めるなら、**L6 + L4 を先に**。

---

## 3a. 4 段階ワークフロー概要

L7 ワークフローは bash 関数と Claude 合成にまたがる 4 段階プロセスを統制し、`ccg.md` に完全に記述されています。

**ステージ 1: ccg_review()** — デュアルモデル分析・合成
- `ccg_codex` + `ccg_gemini` は並列実行（L1 + L2）
- 両者は同一 diff + `ccg_ledger_context`（L6 コンシューマー）から取得した過去コンテキストを受け取る
- Claude は出力を AGREEMENT / DIVERGENCE / BLINDSPOT セクションに合成（L7）

**ステージ 2: ccg_commit()** — ゼロ LLM ハッシュ検証ゲート
- 合成後、ccg は review commit メタデータを検証
- 純粋 bash: 追加 LLM コスト無し、diff 完全性の決定的チェックのみ
- `ccg_precommit_gate` を経由して commit ゲートを許可または拒否（exit 0/1）

**ステージ 3: ccg_merge()** — 競合解決（Bailian 主裁判）
- 複数レビュアーが存在する場合、Bailian を主裁判として使用してそれらの判定をマージ
- L6 台帳履歴を適用して同一コード上の過去の紛争を特定
- 統一マージ判定を生成

**ステージ 4: ccg_push_check()** — グラフィカル品質スコアカード
- 最終品質メトリクスを出力: リスクスコア（L5）、合意/分岐比率、台帳コンテキストヒット
- `ccg_persist_report`（L6 コンパニオン）経由で視覚的サマリーカードをレンダリング
- 検索、共有、PR 添付のため `.ccg/reports/<sha>_<ts>.md` に格納

すべての 4 段階は `ccg.md` slash-command プロトコルを経由して呼び出され、ユーザーは `/ccg` でステージ 1 をトリガーし、タイムアウト内に人間の異議がなければステージ 2–4 は自動進行します。

---

## 10. ファイルマップ

```
ccg/
├── ccg.sh                       → L7 合成下のすべての層（Bash core）
├── ccg.md                       → L7 slash-command プロトコル（Claude が読む、パースされない）
├── ccg-workflow.sh              → 4 段階ワークフロー オーケストレーション: review → commit → merge → push-check
├── bin/ccg.js                   → Node CLI wrapper (install / uninstall / doctor / about)
├── scripts/install.sh           → ローカルクローンインストーラ
├── scripts/curl-install.sh      → リモートワンライナーインストーラ
├── tests/test_ccg.sh            → L1–L6 用 121 回帰 + 敵対的テスト
├── README.md                    → 英語エントリーポイント (zh-CN / ja / ko ミラー)
├── docs/ARCHITECTURE.md         → 英語アーキテクチャドキュメント
├── docs/ARCHITECTURE.ja.md      → 本書
└── package.json                 → npm publish マニフェスト (@mcgrapeng/ccg)
```

疑問があれば: **`bash ccg.sh` が真実、本書は地図**。両者が食い違えば、コードが勝ち本書は間違い。
