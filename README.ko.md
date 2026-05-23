# `/ccg` — Code Divergence Detector

[![Tests](https://img.shields.io/badge/tests-99%20passing-brightgreen.svg)]()
[![npm](https://img.shields.io/npm/v/@mcgrapeng/ccg.svg)](https://www.npmjs.com/package/@mcgrapeng/ccg)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[English](README.md) ｜ [简体中文](README.zh-CN.md) ｜ [日本語](README.ja.md) ｜ **한국어**

> **"더 나은 코드 리뷰 도구"가 아닙니다. 코드 분기 검출기입니다.**
> 대부분의 AI 리뷰 도구는 합의를 추구합니다. `/ccg`는 그 반대입니다—Codex(OpenAI)와 Gemini(Google)에 같은 diff를 병렬로 실행시키고, Claude가 **둘의 의견이 갈리는 지점** 을 부각시킵니다—여기가 바로 사람이 판단해야 할 곳입니다. 합의 = 낮은 신호, 분기 = 황금.

---

## 핵심 명제

| 기존 AI 리뷰 도구 | `/ccg` |
|---|---|
| 단일 모델, 단일 관점 | 두 개의 독립적인 모델 패밀리(훈련 데이터 상이) |
| 출력은 긴 리뷰 보고서 | 출력은 **분기 지도** |
| "다 괜찮아 보인다"고 훑어봄 | "Codex는 X를 지적했고 Gemini는 동의하지 않음, 사람의 판단 필요"가 보임 |
| pre-commit 훅 스타일(승인 / 차단) | 트리아지 도구("실제로 고민할 가치가 있는 2가지는 이것") |

이 포지셔닝은 유일무이합니다. 우리는 **AI 간 의견 불일치를 부각하는 것을 제품 목표로 명시**한 다른 OSS 도구를 알지 못합니다.

---

## 세 가지 기둥

### Pillar 1 — 분기 엔진
같은 프롬프트를 Codex와 Gemini 모두에 보내고 구조화된 `[FINDING]` 형식을 요구합니다. Claude의 합성기가 세 섹션을 출력:

```
AGREEMENT (N)    — 양쪽 모두 지적 → 낮은 신호, 각 한 줄로
DIVERGENCE (M)   — 판단이 다름 → 확장, ★ 사람의 결정 필요
BLINDSPOT (≤2)  — 둘 다 못 봤지만 Claude가 의심 → 신중히 사용
```

AGREEMENT 섹션은 **의도적으로** 짧게 유지됩니다. 제품 관점: 두 AI 리뷰어가 동의한 사항이라면 단일 소스 Claude도 같은 것을 발견할 가능성이 높습니다—새로운 정보량이 낮습니다. DIVERGENCE가 진정한 가치입니다.

### Pillar 2 — 위험 인식 자동 라우팅
`cost` / `balanced` / `quality`를 수동으로 선택할 필요가 없어야 합니다. `ccg_risk_score`가 diff를 살펴보고 결정론적으로 점수를 매깁니다(이 계층에 LLM 없음):

| 시그널 | 가중치 |
|---|---|
| 경로가 `auth/payment/migration/crypto/security`와 일치 | +25..+40 |
| 본문에 `exec/eval/spawn` 또는 SQL+보간 | +20..+30 |
| diff > 600 줄 | +25 |
| 파일 > 8개 | +10 |
| 문서 전용 변경 | **-40** |

점수 < 20 → cost. < 60 → balanced. ≥ 60 → quality. 수동 지정이 항상 우선.

점수 규칙은 **투명하고, 비용이 0이며, PR 가능** ——누구나 가중치를 조정할 수 있습니다.

### Pillar 3 — 리뷰 원장
각 리뷰는 `$XDG_DATA_HOME/ccg/ledger.jsonl`(fallback `~/.local/share/ccg/ledger.jsonl`; 레거시 `~/.ccg/` 자동 마이그레이션)에 JSONL 한 줄을 추가:

```json
{"ts":"2026-05-22T18:35:06Z","repo":"/path","branch":"feat-x","sha":"91c16ec",
 "mode":"quality","risk":60,"files":1,"lines":"+5-0","paths":["auth/login.go"],
 "synthesis":"divergence on constant-time compare; NEEDS HUMAN DECISION..."}
```

사용법:

```bash
ccg_ledger_query                    # 최근 5개 리뷰
ccg_ledger_query "src/auth"         # 이 경로는 몇 번 리뷰되었나
```

처음 50회는 가치가 보이지 않지만, 장기적으로 무상태 도구가 복제할 수 없는 구조적 기억이 됩니다.

---

## 설치

둘 중 선택. 둘 다 `/ccg` 슬래시 명령을 `~/.claude/commands/`에 설치합니다.

### Option 1 — npm (권장)

```bash
npx @mcgrapeng/ccg install        # 일회성, 전역 오염 없음
# 또는
npm i -g @mcgrapeng/ccg && ccg install
```

### Option 2 — curl 한 줄 설치 (Node 불필요)

```bash
curl -fsSL https://raw.githubusercontent.com/mcgrapeng/ccg/main/scripts/curl-install.sh | bash
```

### 그다음 AI CLI 설치

```bash
npm i -g @openai/codex @google/gemini-cli
echo 'export GEMINI_API_KEY="<your-key>"' >> ~/.zshenv
```

검증:

```bash
npx @mcgrapeng/ccg doctor         # 또는: ccg doctor
```

새 Claude Code 세션을 열고 `/ccg`를 시도해 보세요.

## 사용법

```bash
# 자동 모드: git diff 캡처 → 위험 점수 → 실행 → 합성 → 원장 기록
/ccg

# 명시적 작업 (위험 점수 건너뛰기, CCG_MODE 설정된 경우 사용)
/ccg evaluate the lock-free queue implementation in src/queue.ts

# 모드 강제
CCG_MODE=quality /ccg

# 특정 모델 강제
CCG_CODEX_MODEL=o3 /ccg

# 이력 조회
source ~/.claude/commands/ccg.sh
ccg_usage --this-month
ccg_ledger_query "src/payment"
```

## 설정

| 변수 | 기본값 | 용도 |
|---|---|---|
| `CCG_MODE` | `auto` | `auto` / `cost` / `balanced` / `quality`. `auto`는 위험 점수 사용 |
| `CCG_CODEX_MODEL` | (모드 기본값) | codex 모델 재정의 |
| `CCG_GEMINI_MODEL` | (모드 기본값) | gemini 모델 재정의 |
| `CCG_CODEX_TIMEOUT` | `240` | Codex 하드 타임아웃 (초) |
| `CCG_GEMINI_TIMEOUT` | `120` | Gemini 하드 타임아웃 (초) |
| `CCG_NO_CACHE` | `0` | `1` = 프롬프트 캐시 우회 |
| `CCG_CACHE_TTL_HOURS` | `24` | 캐시 TTL |
| `CCG_CACHE_DIR` | `$XDG_CACHE_HOME/ccg/cache` | 캐시 디렉토리 |
| `CCG_MAX_PROMPT_KB` | `100` | 프롬프트 크기 하드 리밋 |
| `CCG_USAGE_LOG` | `$XDG_DATA_HOME/ccg/usage.log` | 사용량 로그 경로 |
| `CCG_LEDGER_LOG` | `$XDG_DATA_HOME/ccg/ledger.jsonl` | 원장 경로 |
| `CCG_KEEP_ARTIFACTS` | `0` | `1` = 디버깅용 작업 디렉토리 보존 |

## `/ccg`가 빛나는 순간

- **위험한 변경**: auth / 결제 / 마이그레이션 / 암호화 —— 정확히 "다른 모델이 내가 놓친 것을 봤을까?"를 알고 싶은 경우
- **머지 전 PR 리뷰**: 브랜치가 업스트림보다 앞서면 `/ccg`가 브랜치 델타를 자동으로 리뷰
- **솔로 개발자 안전망**: 사람 리뷰어가 없나요? `/ccg`는 "두 번째 눈"에 가장 가깝습니다

## `/ccg`가 과한 경우

- 변수 이름 변경
- 한 줄 오타 수정
- README 편집
- 강력한 테스트 커버리지가 있는 일상적인 리팩토링

위험 라우터는 이런 변경을 자동으로 `cost` 모드(~$0.0007)로 낮추지만, 솔직히: 그냥 commit하고 진행하세요. `/ccg`는 진짜 중요한 5–10% 변경에서 본전을 뽑습니다.

## 라이선스

MIT —— [LICENSE](LICENSE) 참조.

## 감사의 말

- [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) 원래의 `/ccg` 컨셉
- Anthropic Claude Code, OpenAI Codex CLI, Google Gemini CLI
