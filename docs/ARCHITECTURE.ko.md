# 아키텍처

> 대상 독자: 기여자 및 통합자. `ccg`를 그냥 사용하고 싶다면 [README.ko.md](../README.ko.md)를 읽으세요. `ccg`를 **변경**하고 싶다면 본 문서를 읽으세요.
>
> 본 문서는 `ccg.sh` 및 `bin/ccg.js`의 코드가 실제로 하는 것을 기술합니다. 불일치가 있으면 `grep -n '^ccg_\|^_ccg_' ccg.sh`로 함수명을 대조하세요.
>
> 번역 동기화 안내: 본 번역은 영어 원문 [docs/ARCHITECTURE.md](ARCHITECTURE.md)를 따라갑니다; 지연이 있으면 영문판이 우선입니다.

[English](ARCHITECTURE.md) ｜ [简体中文](ARCHITECTURE.zh-CN.md) ｜ [日本語](ARCHITECTURE.ja.md) ｜ **한국어**

---

## 1. ccg란

ccg는 **Claude Code 내부에서 Codex + Gemini CLI를 호출하기 위한 production-grade 오케스트레이터** 입니다.

"Code Change Guardian"는 여섯 개의 하위 계층 위에 얹힌 [L7 제품 훅](#l7--분기-합성claude-측)일 뿐입니다 — 각 하위 계층은 slash command에서 LLM CLI로 shell-out할 때 부딪히는 독립적인 실제 엔지니어링 문제를 해결합니다.

> L7을 제거해도 ccg는 여전히 유용합니다 (캐시, 원장, 사용량, 위험 라우팅).
> L1을 제거하면 ccg는 안전하지 않습니다.
> 제품 스토리가 파는 것은 L7입니다. 엔지니어링 실체는 L1–L6입니다.

---

## 2. 7 계층 아키텍처

```
┌─────────────────────────────────────────────────────────────────────────┐
│  L7  Divergence synthesis  (ccg.md prompt 내 존재, Claude가 실행)        │
│      AGREEMENT / DIVERGENCE / BLINDSPOT 3 섹션 출력                     │
├─────────────────────────────────────────────────────────────────────────┤
│  L6  Review ledger          ccg_ledger_record / ccg_ledger_query        │
│      JSONL append-only, grep 가능, 비밀 리덕션됨                         │
│      + ccg_persist_report → <repo>/.ccg/reports/<sha>_<ts>.md            │
│      + ccg_ledger_context → history.txt를 다음 prompt에 주입             │
├─────────────────────────────────────────────────────────────────────────┤
│  L5  Risk-aware routing     ccg_risk_score                              │
│      diff에 대한 순수 규칙 채점 → cost / balanced / quality              │
├─────────────────────────────────────────────────────────────────────────┤
│  L4  Usage telemetry        ccg_actual / ccg_usage / _ccg_log_usage     │
│      USD-aware, model-aware, month-aware                                │
├─────────────────────────────────────────────────────────────────────────┤
│  L3  Smart diff capture     ccg_diff_capture                            │
│      4 단계 폴백: worktree → staged → upstream → origin-head            │
├─────────────────────────────────────────────────────────────────────────┤
│  L2  Content-addressed cache _ccg_cache_lookup / _ccg_cache_store       │
│      SHA-256 prompt+model key · 24h TTL · 실패 호출은 캐시 안 됨         │
├─────────────────────────────────────────────────────────────────────────┤
│  L1  Safe CLI scheduling    _ccg_run_with_timeout / _ccg_redact /       │
│      ccg_cleanup / _ccg_check_prompt_size / mktemp 700 isolation        │
└─────────────────────────────────────────────────────────────────────────┘

       ↑                                       ↑
   bin/ccg.js                            ~/.claude/commands/ccg.sh
   (Node CLI: install/about/doctor)      (Claude가 source하는 Bash 코어)
```

각 계층은 단독으로 호출할 수 있습니다. `bash -c 'source ccg.sh; ccg_risk_score diff.txt'`는 L7을 건드리지 않고 동작합니다.

---

## 3. 각 계층 상세

### L1 — Safe CLI scheduling
**문제:** shell-out에서 `codex < prompt.txt`를 단순 실행하는 것은 5가지 면에서 안전하지 않습니다: 타임아웃 없음, 백그라운드 자식의 stdin이 `/dev/null`로 리다이렉트, API 키가 로그로 새어나감, prompt 크기 무제한, temp 디렉토리가 충돌 시 잔존.

**해법:**
- `_ccg_run_with_timeout` — bash 3.2+ 휴대 가능한 타임아웃. `timeout` / `gtimeout` 우선; 순수 bash 폴링 + 벽시계 데드라인으로 폴백. 결정적: 백그라운드 자식에 명시적인 `<&0`으로 stdin 보존 (bash의 기본 async-stdin-to-devnull은 잘 알려진 함정).
- `_ccg_redact` — 7개 정규식 패턴: `sk-*`, `AIza*`, `Bearer *`, JWT 형식, `ghp_*`, `AKIA*`, Slack `xox[bpoas]-*`. 더해서 URL 쿼리 문자열. 모든 stderr 캡처 + ledger synthesis 쓰기에 적용.
- `ccg_cleanup` — `rm -rf` 전에 상대 경로, `..`, 심볼릭 링크, `ccg.`가 아닌 basename을 거부. UID 범위의 고아 디렉토리 스캔(보수적 24h 임계값)도 수행.
- `_ccg_check_prompt_size` — 호출당 100KB 기본 상한. "실수로 5MB diff를 흘려서 $5 청구됨" 함정 방지.
- `ccg_init` — `mktemp -d` 모드 0700; 동시 호출에서 절대 충돌하지 않음.

**이 계층을 제거하면:** ccg는 비밀을 누설하고 `/tmp`를 어지럽히는 `echo prompt | codex` 래퍼로 전락. 배포 불가능.

---

### L2 — Content-addressed cache
**문제:** 같은 diff를 반복해서 디버깅할 때(특히 ccg 자체를 반복할 때) 같은 prompt에 두 번 지불합니다. codex CLI도 gemini CLI도 "이건 지난 호출과 동일하다"는 개념이 없습니다.

**해법:**
- Key = `sha256(prompt_contents) + model_id`. 동일 prompt + 동일 모델 = 보장된 히트.
- Value = LLM의 전체 출력 블롭.
- TTL = 24h (`CCG_CACHE_TTL_HOURS`로 설정 가능).
- **실패 격리:** 호출이 `_FAIL=`을 반환하거나 비어있으면 **캐시되지 않음**. 그렇지 않으면 일시적 503이 24h 캐시를 오염시킴.
- `$XDG_CACHE_HOME/ccg/cache/`에 저장. 언제든 `rm -rf` 안전 — 최악의 경우 한 번 재지불.

**이 계층을 제거하면:** 디버그 루프 비용이 약 5배. 안전하지 않은 건 아니고, 비쌀 뿐.

---

### L3 — Smart diff capture
**문제:** `git diff`는 커밋되지 않은 변경만 보여줍니다. `git commit`하는 순간 `cursor /review` 같은 도구는 "리뷰할 것 없음"이라고 말합니다. 그러나 **브랜치가 upstream보다 앞서있을 때야말로 가장 중요한 리뷰 윈도우**입니다 — 곧 머지될 시점.

**해법:** `ccg_diff_capture <out_file>`이 4가지 소스를 순서대로 시도:

| 순서 | Source | 조건 |
|---|---|---|
| 1 | `worktree` | `git diff HEAD` 출력이 비어있지 않음 |
| 2 | `staged` | `git diff --cached` 출력이 비어있지 않음 |
| 3 | `upstream:<branch>` | `git rev-parse @{u}`가 해석됨 AND `git diff @{u}`가 비어있지 않음 |
| 4 | `origin-head` | `git rev-parse origin/HEAD`가 해석됨 AND `git diff origin/HEAD`가 비어있지 않음 |

선택된 소스는 `CCG_DIFF_SOURCE`로 호출자(L7의 Claude)에게 노출되어 리뷰에 레이블을 붙일 수 있습니다. `CCG_DIFF_FAIL=not-a-git-repo` 또는 `=empty-diff`도 명시적 비오류 sentinel로 반환되어 프로토콜이 처리.

**이 계층을 제거하면:** ccg가 "커밋된 미푸시 작업의 리뷰" 능력을 조용히 잃음 — 단독 개발자에게 가장 가치 있는 리뷰 윈도우를.

---

### L4 — Usage telemetry
**문제:** 어떤 LLM CLI도 "이번 달에 $X 썼다"고 말해주지 않습니다. `gh copilot`도, `codex`도, `gemini`도. 청구서가 올 때까지 비용이 보이지 않습니다.

**해법:**
- `ccg_actual <prompt> <result> <provider>` — 호출 AFTER 측정. prompt + result의 실제 바이트 수를 읽고, `_ccg_tokens_from_chars` (`chars / 3.0` 휴리스틱; 약 ±15%)로 토큰 환산, `_ccg_price(model, direction)`로 곱해서 `$XDG_DATA_HOME/ccg/usage.log`에 한 줄 추가.
- `ccg_usage [--this-month|--all|--since=YYYY-MM]` — 로그 합산.
- **캐시 히트는 $0.00으로 기록**, 누적 정확성을 유지.
- **실패 호출은 아예 기록 안 함** — 아무것도 반환하지 않은 503을 $0.001 지출로 세어선 안 됨.

형식: `<iso_ts> <provider> <model> in=<n> out=<n> usd=<float>`. 의도적으로 평문 — `grep`과 `awk`가 동작.

**이 계층을 제거하면:** 비용이 전설이 됩니다. 매달 $30을 쓰고 어디 썼는지 모름.

---

### L5 — Risk-aware routing
**문제:** `cost` / `balanced` / `quality` 모드의 60배 가격 차(≈$0.0007 vs ≈$0.0440 / 호출). 매번 사용자에게 선택시키는 건 UX 재앙. LLM에게 자기 선택시키면 피드백 루프 생성. 둘 다 옳지 않음.

**해법:** `ccg_risk_score <diff_file>`은 순수 규칙 채점 — 이 계층에 LLM 없음. diff를 읽고 반환:

```
CCG_RISK_SCORE=72
CCG_RISK_MODE=quality
CCG_RISK_FILES=5
CCG_RISK_LINES=+340-12
CCG_RISK_REASONS=auth+40 sql_interp+30 size>300+15 docs_only-40
```

`ccg.sh:ccg_risk_score`의 규칙:

| 시그널 | 가중치 | 검출 |
|---|---|---|
| 경로가 `auth\|payment\|migration\|crypto\|security`와 일치 | +25..+40 | 경로 정규식 |
| 본문에 `exec\|eval\|spawn` 또는 `sql.*interp` | +20..+30 | patch 정규식 |
| 하드코딩된 URL/host 리터럴 | +5 | 정규식 |
| TODO/FIXME/HACK 마커 | +5 | 정규식 |
| diff > 600 줄 | +25 | 줄 수 |
| 파일 > 8개 | +10 | hunk 수 |
| 문서 전용 변경 (`.md` / `.txt` / `.rst`) | **-40** | 경로 확장자 |

**임계값:** `< 20 → cost`, `< 60 → balanced`, `≥ 60 → quality`.

**왜 LLM이 아닌가:** 투명성, 비용 0, PR 가능한 가중치. 커뮤니티 기여자가 `sed -i 's/+40/+50/' ccg.sh`하고 1줄 PR 제출 가능. LLM 스코어러라면 모든 라우팅 결정이 불투명해짐.

**이 계층을 제거하면:** 사용자가 매번 `CCG_MODE`를 수동 설정하거나, 항상 `quality` 비용을 지불.

---

### L6 — Review ledger
**문제:** 모든 LLM CLI가 무상태. "2주 전 Codex가 `src/auth.ts`에 대해 뭐라고 했지?" — 어떤 도구도 답할 수 없음.

**해법:** `ccg_ledger_record <workdir>`가 `$XDG_DATA_HOME/ccg/ledger.jsonl`에 JSONL 한 줄 추가:

```json
{"ts":"2026-05-22T18:35:06Z","repo":"/path","branch":"feat-x","sha":"91c16ec",
 "mode":"quality","risk":72,"files":1,"lines":"+5-0","paths":["auth/login.go"],
 "synthesis":"divergence on constant-time compare; NEEDS HUMAN DECISION..."}
```

`synthesis` 필드는 Claude의 결합 판정의 처음 ~400자 — 1000개 항목을 grep하기 충분히 짧으면서, 유용하기에 충분히 김.

`ccg_ledger_query` 작업:
- `ccg_ledger_query` — 최근 5개 리뷰.
- `ccg_ledger_query "src/auth"` — 이 경로 조각을 건드린 리뷰, 카운트 + 최근 3 날짜 포함.

**처음 50개에선 0 가치.** 50개를 넘기면 무상태 도구가 복제할 수 없는 구조적 기억이 됨 — 장기적 해자가 여기.

**이 계층을 제거하면:** ccg가 100% 무상태가 됨. 매 리뷰가 처음부터 시작. L7 제품 스토리는 여전히 동작하지만, 장기 차별화가 사라짐.

#### L6 컨슈머 — `ccg_ledger_context`（루프를 닫다）

컨슈머가 없으면 ledger는 쓰기 전용 일기장 — 같은 파일에 대해 "지난번에 뭘 논쟁했는지"의 답이 ledger에 있어도 매 리뷰가 처음부터 시작함. `ccg_ledger_context <diff_file>`가 양방향화의 다른 절반:

1. diff에서 건드린 경로 추출 (`diff --git a/<path>` 헤더 파싱).
2. ledger를 JSON-quoted `"<path>"`로 고정 문자열 매칭(`src/foo.ts`가 `src/foobar.ts`와 잘못 매칭되지 않도록).
3. 중복 제거, 최근 `CCG_HISTORY_MAX`(기본 3) 개까지 취득.
4. `<workdir>/history.txt`로 구조화된 Markdown 출력.

프로토콜 레이어(`ccg.md` 단계 2.5)가 `history.txt`를 Codex와 Gemini 프롬프트에 끼워 넣음. 두 리뷰어 모두 이런 걸 봄:

```
=== PRIOR REVIEWS (last 3 entries touching these paths) ===
- [2026-05-20T12:00:00Z] sha=ghi9abc mode=quality lines=+8-1
  paths: ["auth/login.go","auth/session.go"]
  synthesis: BLINDSPOT: error logging missing. fix-required.
...
```

왜 중요한가:
- **재발 패턴이 표면화된다.** "지난번 constant-time compare로 다퉜는데 — 이 PR이 같은 얘기 반복하는 거 아닌가?"
- **미해결 `fix-required`가 풍화되지 않음.** 지난 verdict가 `fix-required`였는데 이번 diff가 해결 안 했으면 두 리뷰어 모두 지적 가능.
- **추가 LLM 호출 0건.** `ccg_ledger_context`는 순수 셸(grep + sed), 밀리초 단위.

**Cross-shell footgun (기록할 가치 있음):** `ccg.sh`는 Claude Code Bash tool을 통해 사용자 기본 셸(bash 사용자는 bash, **zsh 사용자는 zsh**)에 source됨. zsh의 `local var`(`=` 없이)는 변수의 현재 값을 stdout에 출력함. `local` 선언을 while 루프 본체 안에 두면, N번째 반복이 N-1번째 값을 `history.txt`로 흘림. 수정: 루프에서 변경되는 모든 로컬은 루프 밖에서 한 번만 선언. 테스트 15.9가 이 회귀를 잠금.

노브:
- `CCG_NO_HISTORY=1`로 컨슈머 완전 비활성화 ("단일 관점 베이스라인" 리뷰가 필요할 때).
- `CCG_HISTORY_MAX=<n>`으로 주입 건수 제한(기본 3; 클수록 프롬프트 크기 부풀림).

**이 컴패니언을 제거하면:** ccg는 완전 무상태로 회귀. L6는 쓰기 전용 일기장으로 후퇴 — 데이터 축적에 의한 해자는 남지만 세션 내 복리는 사라짐.

---

### L7 — 분기 합성 (Claude 측)
**문제:** 단일 모델 코드 리뷰(Copilot, Cursor `/review`, Aider)는 자신의 사각지대를 볼 수 없음. 똑똑한 모델이라도 한 관점만.

**해법:** L7 로직은 `ccg.md`(Claude가 따르는 slash-command 프로토콜)에 있으며, `ccg.sh`에는 없음. Claude는:

1. `ccg.sh`를 source, `ccg_init` 호출하여 workdir 할당.
2. `ccg_preflight` 호출하여 Codex + Gemini 가용성 확인.
3. `ccg_diff_capture` (L3) 호출하여 diff 구체화.
4. `ccg_risk_score` (L5) 호출하여 모드 선택.
5. prompt 파일 하나 작성. 같은 prompt, 다른 소비자.
6. `ccg_codex` + `ccg_gemini`를 **병렬로** 호출 (같은 Claude 메시지 내의 두 Bash 도구 호출).
7. `ccg_actual` (L4) 호출하여 실제 비용 기록.
8. 두 `[FINDING]` 형식 출력을 AGREEMENT / DIVERGENCE / BLINDSPOT 섹션으로 **합성** — 합성은 Claude의 머릿속에서 일어남, 코드 아님.
9. `ccg_ledger_record` (L6) 호출하여 synthesis 발췌 기록.
10. `ccg_cleanup` (L1) 호출하여 workdir 제거.

프로토콜은 AGREEMENT 가시성을 명시적으로 **다운그레이드** (각 한 줄) 하고 DIVERGENCE를 **승격** (전체 확장 + "NEEDS HUMAN DECISION" 태그) 합니다. 이는 제품 의견: 합의 = 낮은 신호, 분기 = 가치.

**이 계층을 제거하면:** ccg는 여전히 유용 — 개별 함수를 호출하여 비용 텔레메트리, 위험 라우팅, 원장 쿼리 가능. 그러나 사용자 향 `/ccg` 워크플로우는 사라짐.

---

## 4. 종단 간 데이터 흐름

한 번의 `/ccg` 호출, 시간 순서대로, 각 단계의 담당 계층과 함께:

```
USER가 Claude Code에서 "/ccg" 입력
       │
       ▼
[Claude가 ccg.md 프로토콜을 읽음]                            ── protocol
       │
       ▼
ccg_init                                                     ── L1
  └─ mktemp -d -m 700 /tmp/ccg.XXXXXXXX
  └─ CCG_DIR=<path> 출력
       │
       ▼
ccg_preflight                                                ── L1
  └─ command -v codex / gemini, $GEMINI_API_KEY 확인
       │
       ▼
ccg_diff_capture "$CCG_DIR/diff.txt"                         ── L3
  └─ 4 단계 폴백 → CCG_DIFF_SOURCE 출력
       │
       ▼
ccg_risk_score "$CCG_DIR/diff.txt"                           ── L5
  └─ 규칙 → CCG_RISK_SCORE + CCG_RISK_MODE 출력
  └─ Claude가 CCG_MODE를 적절히 export
       │
       ▼
ccg_ledger_context "$CCG_DIR/diff.txt"                       ── L6 컨슈머
  └─ 동일 경로를 건드린 과거 리뷰를 ledger에서 grep
  └─ history.txt 작성 (≤ CCG_HISTORY_MAX 건) prompt 임베딩용
       │
       ▼
[Claude가 codex.prompt + gemini.prompt 작성 — 동일 내용;     ── protocol
 history.txt가 있으면 diff 앞에 붙임]
       │
       ▼
ccg_codex   ─ 병렬 ─  ccg_gemini                            ── L1 + L2
  │           │             │
  │   L1: 타임아웃 + 리덕션 + stdin <&0
  │   L2: 캐시 조회 → 히트하면 반환, 아니면
  │      CLI 실행 후 캐시에 저장 (성공시에만)
  │
  └─ 둘 다 *.result 파일에 기록
       │
       ▼
ccg_actual <prompt> <result> codex|gemini                    ── L4
  └─ 토큰 측정, USD 계산, usage.log에 추가
       │
       ▼
[Claude가 AGREEMENT/DIVERGENCE/BLINDSPOT 합성]               ── L7
  └─ (file, line, category, title)로 [FINDING] 블록 정렬
  └─ 해소 불가능한 분기에 "NEEDS HUMAN DECISION" 발행
       │
       ▼
[Claude가 synthesis.txt 작성 — 처음 400자]                   ── protocol
       │
       ▼
ccg_ledger_record "$CCG_DIR"                                 ── L6
  └─ synthesis를 JSON 인코딩 + 리덕션 → ledger.jsonl 추가
       │
       ▼
ccg_cleanup "$CCG_DIR"                                       ── L1
  └─ 경로 순회 안전한 rm -rf
       │
       ▼
USER가 보는 것: AGREEMENT / DIVERGENCE / BLINDSPOT + 비용 줄
```

전형적인 총 지연: 모드에 따라 5–60초. 비용: $0.0007–$0.044, `CCG_MAX_PROMPT_KB`로 상한.

---

## 5. 확장 지점

기여자와 통합자가 신뢰할 수 있는 계약. 서명 변경 = 파괴적 변경.

### 5.1 새 위험 채점 규칙 추가 (L5)

`ccg.sh:ccg_risk_score`를 편집, `score`를 증가시키고 `reasons`에 추가하는 `if/then`을 추가. 출력 계약:

```
CCG_RISK_SCORE=<int 0..200>
CCG_RISK_MODE=<cost|balanced|quality>
CCG_RISK_FILES=<int>
CCG_RISK_LINES=+<adds>-<dels>
CCG_RISK_REASONS=<signal+weight signal+weight ...>
```

그 외 모든 것은 이 출력을 KEY=VAL 줄로 파싱.

### 5.2 새 LLM 제공자 추가 (L1 + L2)

예시로 보는 패턴: `ccg_codex`와 `ccg_gemini`가 이미 계약을 구현. `ccg_claude`를 추가하려면:

1. `CCG_MODE`에서 모델 id 해석 (`_ccg_resolve_codex_model`을 미러).
2. 새 제공자 이름을 포함하는 캐시 키 구성.
3. `_ccg_cache_lookup` → 히트하면 result 파일에 작성하고 반환.
4. `_ccg_run_with_timeout <timeout> <cli> -i <prompt> > <result> 2> <err>`.
5. 성공시 `_ccg_cache_store`.
6. `CCG_CLAUDE_OK=<size>` 또는 `CCG_CLAUDE_FAIL=<reason>` 출력.

`ccg.md`의 프로토콜이 새 helper를 다른 것과 병렬로 호출하도록 업데이트 필요.

### 5.3 저장 경로 변경

모든 경로는 `_ccg_xdg_data_dir` / `_ccg_xdg_cache_dir` / `_ccg_xdg_config_dir`를 거침. XDG Base Directory 사양에 따라 `XDG_*_HOME` 환경 변수로 재정의, 또는 개별 파일에 `CCG_USAGE_LOG` / `CCG_LEDGER_LOG` / `CCG_CACHE_DIR` 설정.

레거시 `~/.ccg/`는 첫 실행 시 `_ccg_migrate_legacy`로 마이그레이션 — 멱등, 비파괴.

### 5.4 가격 사용자화

`_ccg_price <provider> <model> <direction>`은 100만 토큰당 USD 반환. 이 표를 편집하면 다음 `ccg_actual` 새로 고침에서 즉시 적용.

### 5.5 합성 출력 형식 사용자화

합성은 **Claude의 머릿속**에서 일어나고 `ccg.md`의 템플릿을 따름. 형식 변경(예: "SECURITY DIVERGENCE" 섹션 추가)은 `ccg.md` 단계 4 + 8의 prompt 템플릿을 편집. Bash 측은 합성을 파싱하지 않음.

---

## 6. 테스트 스위트가 검증하는 불변식

`tests/test_ccg.sh`가 강제 — 최근 카운트 기준 121 테스트. 이를 위반하는 코드 추가는 CI를 깨뜨림.

| 불변식 | 왜 |
|---|---|
| `ccg_init`은 항상 `/tmp` 또는 `$TMPDIR` 하의 workdir 반환, 절대 `$HOME` 하 아님 | 충돌 안전: 오래된 workdir가 사용자 홈을 어지럽히지 않음 |
| Workdir basename은 `ccg.`로 시작 | `ccg_cleanup`의 allowlist를 위한 안전 가드 |
| 실패한 CLI 호출은 캐시나 사용 로그에 절대 들어가지 않음 | 일회성 503이 텔레메트리/캐시를 오염시키지 않아야 함 |
| stderr의 비밀은 파일 쓰기 전에 리덕션됨 | 7 패턴 표 |
| `ccg_diff_capture`는 빈 diff로 성공을 반환하지 않음 | 호출자가 비어있지 않은 페이로드를 가정 가능 |
| 빈 파일에 대한 위험 점수 → 0이 아닌 `_FAIL=` | "위험 0"과 "신호 없음"을 구분 |
| 원장 행은 항상 유효한 JSON, `json.loads`로 파싱 가능 | grep 가능 + 파싱 가능 |
| `_ccg_run_with_timeout`은 자식 종료 코드를 정확히 보존 | 호출자가 124(타임아웃)와 1(CLI 에러)를 구분 가능 |
| 서브쉘은 호출자로부터 `set -u`를 상속하지만 설정되지 않은 변수에서 깨지지 않음 | strict-mode 호스트 활성화 |

---

## 7. 알아야 할 설계 결정

처음엔 이상해 보이지만 구체적 이유가 있는 선택. 미래 기여자가 "고치지" 않도록 문서화.

| 결정 | 이상해 보이는 이유 | 진짜 이유 |
|---|---|---|
| Bash 3.2+ 호환 (`mapfile`, `${var,,}` 없음) | 현대 bash 5.x에 더 좋은 구문 | macOS는 GPL3 보이콧으로 bash 3.2 동봉. bash 5는 명시적 `brew install` 필요. ccg는 박스에서 바로 동작해야 함 |
| 캐시 키가 prompt 해시뿐 아니라 모델 ID 포함 | "같은 prompt = 같은 결과"는 참인 것 같음 | gpt-5-nano 결과로 캐시된 prompt는 gpt-5 결과로 제공 불가. 다른 모델, 다른 출력 |
| AGREEMENT 섹션은 의도적으로 각 한 줄 | 더 자세한 게 일반적으로 좋음 | 두 AI 모두 같은 이슈 flag했다면 단일 Claude도 그럴 가능성 높음. AGREEMENT에 디테일 추가는 DIVERGENCE 신호를 희석. UX 사고가 아닌 제품 의견 |
| 위험 점수는 순수 규칙, LLM 아님 | LLM이 더 똑똑할 수도 | 비용(0), 설명 가능성(regex grep), "PR 가능한 가중치"가 한계 정확성 향상을 이김. 또한 스코어러 자신의 예측이 무엇이 리뷰되는지에 영향 미치는 피드백 루프 회피 |
| 실패 호출은 잠시도 캐시되지 않음 | "음의 캐시는 재시도 폭풍 방지" | 실패는 보통 "모델 이름 잘못" 또는 "rate limit". 둘 다 원인 해결 후 즉시 재시도하고 싶음. 실패 캐싱은 복구 지연 |
| `~/.ccg/` 마이그레이션은 비파괴적 (`cp`가 아닌 `mv`) | 고아 남길 수 있음 | 구 `~/.ccg/` 사용자는 env 변수로 명시적 opt-in; 복사는 중복 남김. 첫 만남에 한 번 이동; dir은 비어있을 때만 제거 |
| `ccg_cleanup`이 `..` 뿐 아니라 심볼릭 링크도 거부 | "경로 순회"가 흔한 위협 | `mktemp`가 이미 `..` 방지. 심볼릭 링크가 실제 공격 표면(클린업 중 symlink swap의 TOCTOU 경쟁) |
| Slash 명령 프로토콜이 `ccg.md`에 거주, 코드 내 아님 | 코드를 문서로 가 더 깔끔해 보임 | Claude가 `ccg.md`를 프로토콜 사양으로 읽음. Bash 코드는 Claude의 prompt가 될 수 없음; 이게 slash 명령의 본질. 프로토콜(md)과 원시(sh)를 분리하는 게 올바른 경계 |
| 루프 본체 내 `local var=`(`=` 포함) 필수 | bash는 `local var`와 `local var=`를 동일하게 처리 | zsh의 `local var`(`=` 없이)는 변수의 현재 값을 stdout에 출력. `ccg.sh`는 zsh 사용자의 Claude Code Bash tool이 source — 이전 반복의 값을 prompt나 출력 파일로 흘리는 건 진짜 버그. 테스트 15.9가 가드 |

---

## 8. 비목표

ccg가 의도적으로 **하지 않는** 것, 그리고 그 이유.

- **스트리밍 출력 없음.** Claude는 합성 전에 Codex와 Gemini 결과 모두 완전히 필요. 스트리밍은 다른 프로토콜 설계 필요(비용 개선도 안 됨 — 두 리뷰어 모두 완료까지 실행).
- **다중 턴 대화 없음.** 각 `/ccg` 호출은 새로움; `continuation_id` 없음. 반복하고 싶다면 정제된 prompt로 `/ccg` 다시 실행 — 캐시로 저렴.
- **Claude Code 이외 IDE 통합 없음.** Cursor / Continue / Cline 사용자는 [zen-mcp-server](https://github.com/BeehiveInnovations/zen-mcp-server)를 봐야 함. N개 IDE로의 포트 유지 테스트 부담은 가치 없음.
- **정적 분석 없음.** 분기 검출 ≠ Semgrep / CodeQL. ccg를 함께 사용, 대체가 아님.
- **"리뷰 봇" 없음.** ccg는 사람 트리거. 모든 PR에서 자동 실행은 노이즈 생성; "트리아지 도구" 포지셔닝을 무너뜨림.

---

## 9. 진짜 해자가 있는 곳

마케팅 포지셔닝: **분기 검출** (L7).

엔지니어링 해자는 **L6(원장 + 컨슈머) + L4(사용량)**:

- L7은 일주일이면 복제됨. `gpt-5-mini` + `gemini-2.5-flash`를 아는 팀이라면 같은 트릭을 실행할 수 있음.
- L6 + L4는 **사용자별로 축적되는 데이터**를 생성. 헤비 사용자는 6개월 후 경쟁자가 복제할 수 없는 개인 역사 기록 보유 — 경쟁자는 리뷰 #1부터 시작해야 함.
- `ccg_ledger_context` 컨슈머(2026-05 추가)가 그 데이터를 세션 내에서 **복리화**: 각 리뷰가 과거 리뷰를 컨텍스트로 사용. 이게 없으면 ledger는 쓰기 전용 일기장; 이게 있으면 같은 파일에 대한 각 리뷰가 전번의 어깨 위에 섬.

먼저 강화할 것 우선순위를 정한다면, **L6 + L4 먼저**.

---

## 3a. 4단계 워크플로우 개요

L7 워크플로우는 bash 함수와 Claude 합성에 걸쳐 있는 4단계 프로세스를 조율하며, `ccg.md`에 완전히 기술되어 있습니다.

**단계 1: ccg_review()** — 이중 모델 분석 및 합성
- `ccg_codex` + `ccg_gemini`가 병렬 실행 (L1 + L2)
- 둘 다 동일 diff + `ccg_ledger_context`(L6 컨슈머)에서 취득한 선행 컨텍스트 수신
- Claude가 출력을 AGREEMENT / DIVERGENCE / BLINDSPOT 섹션으로 합성 (L7)

**단계 2: ccg_commit()** — 제로 LLM 해시 검증 게이트
- 합성 후, ccg는 리뷰 커밋 메타데이터 검증
- 순수 bash: 추가 LLM 비용 없음, diff 무결성에 대한 결정론적 검사만
- `ccg_precommit_gate`를 통해 커밋 게이트 허가 또는 거부 (exit 0/1)

**단계 3: ccg_merge()** — 충돌 해결 (Bailian 주재자)
- 여러 리뷰어가 존재하는 경우, Bailian을 주재자로 사용하여 그들의 판정 병합
- L6 원장 기록을 적용하여 동일 코드에 대한 이전 분쟁 식별
- 통합된 병합 판정 생성

**단계 4: ccg_push_check()** — 그래픽 품질 스코어카드
- 최종 품질 메트릭 출력: 위험 점수(L5), 합의/분기 비율, 원장 컨텍스트 히트
- `ccg_persist_report`(L6 컴패니언)를 통해 시각적 요약 카드 렌더링
- 검색, 공유, PR 첨부를 위해 `.ccg/reports/<sha>_<ts>.md` 아래 저장

모든 4단계는 `ccg.md` slash-command 프로토콜을 통해 호출되며, 사용자가 `/ccg`로 단계 1을 트리거하고 타임아웃 내에 인적 이의가 없으면 단계 2–4가 자동 진행됩니다.

---

## 10. 파일 맵

```
ccg/
├── ccg.sh                       → L7 합성 아래 모든 계층 (Bash 코어)
├── ccg.md                       → L7 slash-command 프로토콜 (Claude가 읽음, 파싱되지 않음)
├── ccg-workflow.sh              → 4단계 워크플로우 오케스트레이션: review → commit → merge → push-check
├── bin/ccg.js                   → Node CLI wrapper (install / uninstall / doctor / about)
├── scripts/install.sh           → 로컬 클론 설치기
├── scripts/curl-install.sh      → 원격 한 줄 설치기
├── tests/test_ccg.sh            → L1–L6용 121개 회귀 + 적대 테스트
├── README.md                    → 영어 진입점 (zh-CN / ja / ko 미러)
├── docs/ARCHITECTURE.md         → 영어 아키텍처 문서
├── docs/ARCHITECTURE.ko.md      → 본 문서
└── package.json                 → npm publish 매니페스트 (@mcgrapeng/ccg)
```

의문이 있을 때: **`bash ccg.sh`가 진실, 본 문서는 지도**. 둘이 모순되면 코드가 이기고 본 문서는 틀림.
