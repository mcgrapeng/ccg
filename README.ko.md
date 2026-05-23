# ccg — Code Divergence Detector

> Claude Code 슬래시 명령. 한 번 설치하고 diff 위에서 `/ccg`를 입력하세요.

[![Tests](https://img.shields.io/badge/tests-99%20passing-brightgreen.svg)]()
[![npm](https://img.shields.io/npm/v/@mcgrapeng/ccg.svg)](https://www.npmjs.com/package/@mcgrapeng/ccg)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[English](README.md) ｜ [简体中文](README.zh-CN.md) ｜ [日本語](README.ja.md) ｜ **한국어**　·　[아키텍처 →](docs/ARCHITECTURE.ko.md)

---

## ccg란

`auth/login.go` 변경 후 머지하려고 합니다. 안전 점검을 하고 싶습니다. 오늘 선택지는 세 가지뿐이고, 모두 결함이 있습니다:

- **단일 모델 리뷰**(Copilot, Cursor `/review`, Aider)는 **한 가지 관점**만 제공합니다. Claude가 timing attack을 놓치면 당신도 함께 놓칩니다.
- **다중 모델 게이트웨이**(zen-mcp-server 등)는 의견을 **평균화**하여, 똑똑한 모델들이 의견을 달리한 곳 — 인간이 정말로 도움이 필요한 유일한 곳 — 을 정확히 가립니다.
- **수동 교차 검증**은 시간이 무한하다면 할 일. 당신에겐 없습니다.

ccg는 Claude Code용 `/ccg` 슬래시 명령으로, 이 세 가지 모두를 진짜로 해결합니다. 임의의 diff에 대해:

1. 같은 prompt를 **Codex(OpenAI)** 와 **Gemini(Google)** 에 병렬 전송
2. **Claude** 가 두 보고서를 읽고 **그들이 의견을 달리하는 곳을 부각** —— 인간 판단이 필요한 곳
3. 비용 추적, 위험 수준에 적합한 가장 저렴한 모델 자동 선택, 과거 리뷰 기억

**비유**: 다른 팀의 시니어 엔지니어 두 명에게 같은 PR을 리뷰시키고, 테크 리드가 종합: "이건 둘 다 동의, 이건 의견이 갈렸음 — 당신이 결정, 내 견해는 다음".

## 언제 ccg를 사용할까

트리거는 **도메인**이 아니라 **느낌**입니다. 방금 작성한 diff를 보면서 마음속으로 다음과 같이 생각하고 있다면 — ccg의 순간입니다:

| 마음속 독백 | ccg 사용? |
|---|---|
| "이걸 잘못하면 새벽 3시에 호출됨." | ✅ 예 |
| "이건 판단의 문제 — 명백히 정답이 있는 게 아님." | ✅ 예 |
| "누가 먼저 봐줬으면 좋겠다." | ✅ 예 |
| "변수 이름만 바꿨다." | ❌ 아니요 |
| "문서만 편집." | ❌ 아니요 |
| "단일 모델과 스트리밍 대화하고 싶음." | ❌ 아니요 (CLI 직접 사용) |

**도메인 횡단 실제 예시** — 모두 auth/암호화가 아니지만, 모두 "시니어 엔지니어 두 명이 의견이 갈릴" 순간입니다:

- **소셜 플랫폼** — 새 참여 신호로 피드 재정렬 · 댓글 트리 fan-out 전략 · A/B 테스트 버킷팅 로직 · 어뷰즈 방지 레이트 리밋 정책 · 팔로우 관계의 그래프 DB 스키마
- **데이터 / AI 인프라** — embedding 모델 교체(재인덱싱?) · 청킹 전략 변경 · RAG 검색 점수 · 프롬프트 인젝션 방어 레이어링
- **프론트엔드** — 새 페이지에 SSR vs ISR vs RSC · 캐시 무효화 전략 · 상태 관리 리팩토링 · 접근성 트레이드오프
- **API 설계** — 페이지네이션 cursor vs offset · 에러 응답 모델 · 버전 관리 방식 · 멱등성 키 처리
- **분산 시스템** — 타임아웃 / 재시도 정책 · cache TTL vs 이벤트 기반 무효화 · 분할 내성 트레이드오프 · 리더 선출 의미론
- **데이터베이스** — 다단계 마이그레이션 순서 · 핫 패스 인덱스 선택 · 트랜잭션 격리 수준 · 소프트 삭제 vs 하드 삭제
- **보안** — 네, auth / 암호화 / 결제도 여기 — 하지만 많은 도메인 중 하나일 뿐

**패턴**: 합리적인 엔지니어 한 명은 A를 선택하고 다른 합리적인 엔지니어는 B를 선택할 수 있는 모든 변경 — 그게 분기 검출이 $0.04를 회수하는 순간.

## 왜 ccg인가 (다른 도구와의 비교)

**1. 의견 불일치가 신호, 잡음이 아님.**
Codex가 "`subtle.ConstantTimeCompare`를 사용하라"고 하고 Gemini가 "bcrypt는 이미 constant-time, 그건 cargo-cult"라고 할 때, *그곳이* 당신이 생각해야 할 곳입니다. 다른 도구는 이런 충돌을 모호한 "timing attack 주의"로 섞어버립니다. ccg는 양쪽의 말을 그대로 보여줍니다.

**2. 내장 비용 텔레메트리.**
Codex / Gemini CLI는 지출을 알려주지 않습니다. ccg는 모든 호출을 기록하고, 위험에 따라 가장 저렴하고 충분한 모델을 자동 선택(위험 라우팅)하며, 같은 prompt는 24h 캐시로 비용 0. `ccg_usage --this-month`가 "지금까지 얼마 썼지?"에 답합니다.

**3. 세션 간에 살아남는 리뷰 이력.**
"2주 전에 모델이 `src/auth.ts`에 대해 뭐라고 했지?" —— ccg의 추가 전용 원장이 답합니다. 어떤 무상태 도구도 못 합니다.

## 설치

둘 중 선택:

```bash
# npm (권장)
npx @mcgrapeng/ccg install

# 또는 curl 한 줄 설치, Node 불필요
curl -fsSL https://raw.githubusercontent.com/mcgrapeng/ccg/main/scripts/curl-install.sh | bash
```

그다음 AI CLI를 한 번 설치:

```bash
npm i -g @openai/codex @google/gemini-cli
echo 'export GEMINI_API_KEY="<your-key>"' >> ~/.zshenv
```

확인:

```bash
npx @mcgrapeng/ccg doctor      # Codex / Gemini / API key 점검
npx @mcgrapeng/ccg about       # 7개 계층의 기능과 현재 환경 상태 확인
```

## 사용법 — 완전한 예제

`auth/login.go`를 막 편집했다고 해봅시다:

```go
// before                                            // after
func Login(user, pw string) bool {                   func Login(user, pw string) bool {
    u := lookupUser(user)                                u := lookupUser(user)
-   return u.Hash == sha256.Sum256([]byte(pw))           hashed, err := bcrypt.GenerateFromPassword([]byte(pw), 12)
+                                                        if err != nil { return false }
+                                                        return subtle.ConstantTimeCompare(u.Hash, hashed) == 1
}
```

Claude Code를 열고 입력:

```
/ccg
```

약 30초 후 다음과 같은 출력 —— **실제 출력**, 플레이스홀더 아님:

```
📍 범위: worktree · 1 파일 · +4 -1 줄
🎯 모드: quality  (risk=65 · auth+35 size>0+5 crypto-mention+25)
🩺 두 리뷰어 정상: Codex ✓ · Gemini ✓
💰 비용: $0.041

═══ AGREEMENT (2) — 양쪽 모두 지적, 낮은 신호 ═══
• auth/login.go:3 — sha256은 비밀번호 해시 아님; bcrypt가 맞음
• auth/login.go:5 — bcrypt 에러 명시적 처리 (당신이 했음)

═══ DIVERGENCE (1) — 두 모델이 의견 불일치 ★ 당신이 결정 ═══

▸ auth/login.go:6 — bcrypt 해시 비교 방법
  🔵 Codex:  "bcrypt를 사용해도 timing attack 방지를 위해
              subtle.ConstantTimeCompare로 감싸라."
  🟢 Gemini: "bcrypt.CompareHashAndPassword는 이미 constant-time.
              감싸는 것은 cargo-cult이고 길이 불일치 panic을 유발할 수 있다."
  ⚖️ Claude: Gemini가 맞다. bcrypt.CompareHashAndPassword가 표준 비교
              방법; 그 원시 출력에 ConstantTimeCompare는 카테고리 오류 ——
              "막 해시한 pw"와 "저장된 해시"를 비교하지만 bcrypt는
              매번 새 솔트를 쓰므로 직접 비교는 항상 false 반환.
  ➡️ 액션:   ConstantTimeCompare 줄을 다음으로 교체:
              `err := bcrypt.CompareHashAndPassword(u.Hash, []byte(pw))`
              `return err == nil`

═══ BLINDSPOT (1) — 둘 다 못 봤지만 Claude 의심 ═══
• 에러 경로: bcrypt 오류 시 false 반환은 호출자에겐 맞지만,
  인프라 오류(bcrypt OOM 등)를 조용히 삼킴. 로그를 추가하라.

═══ VERDICT: fix-required ═══
현재 비교 로직은 유효한 비밀번호도 항상 거부한다. DIVERGENCE 액션
적용 + 오류 로깅 추가 후 머지 가능.
```

### 이 출력을 어떻게 읽는가

| 섹션 | 의미 | 무엇을 할까 |
|---|---|---|
| **AGREEMENT** | Codex와 Gemini 둘 다 같은 것을 지적. 단일 소스 Claude도 잡을 가능성 높음 —— **새로운 정보량 낮음**. | 훑어보고, 미수정 시 수정. |
| **DIVERGENCE** ★ | 두 모델이 의견 불일치. **ccg가 존재하는 진짜 이유**. Claude의 "액션" 줄이 추천을 주지만 최종 결정자는 당신. | 주의 깊게 읽고, Claude 판단 수용 또는 재정의. |
| **BLINDSPOT** | 어떤 모델도 제기하지 않았지만 Claude가 합성하면서 의심. **신중히 사용** —— 호출당 최대 2건. | 힌트로 다루고, 절대 진리 아님. |
| **VERDICT** | `merge` / `fix-required` / `discuss`. 한 줄 요약. | 머지 게이트로 사용. |

리뷰 후 `ccg_ledger_record`가 원장에 JSONL 한 줄 기록. 2주 후:

```bash
source ~/.claude/commands/ccg.sh
ccg_ledger_query "auth/login.go"
# → "auth/login.go: 3 리뷰 · 최신 2026-05-23 (fix-required) · 2026-05-09 (merge) · 2026-04-28 (discuss)"
```

## 설정 (기본값으로 보통 충분)

모드와 모델 선택은 자동입니다. 필요할 때만 재정의:

```bash
CCG_MODE=quality /ccg          # 모든 diff에 quality 모델 강제
CCG_CODEX_MODEL=o3 /ccg        # 단일 모델만 재정의
CCG_NO_CACHE=1 /ccg            # 이번 호출만 24h 캐시 우회
```

자주 쓰는 것 (전체는 [아키텍처 §5](docs/ARCHITECTURE.ko.md#5-확장-지점)):

| 변수 | 기본값 | 용도 |
|---|---|---|
| `CCG_MODE` | `auto` | `auto` / `cost` / `balanced` / `quality` |
| `CCG_CACHE_TTL_HOURS` | `24` | 캐시 TTL |
| `CCG_MAX_PROMPT_KB` | `100` | 호출당 프롬프트 크기 상한 |

비용 참고 (USD / 호출, 캐시 적중 후):

| 모드 | Codex | Gemini | 표준 비용 |
|---|---|---|---|
| `cost`     | gpt-5-nano  | gemini-2.5-flash-lite | ~$0.0007 |
| `balanced` | gpt-5-mini  | gemini-2.5-flash      | ~$0.0046 |
| `quality`  | gpt-5       | gemini-2.5-pro        | ~$0.0440 |

누적 지출은 언제든:

```bash
source ~/.claude/commands/ccg.sh
ccg_usage --this-month
```

## 적합하지 않은 경우

- Claude Code 이외의 IDE ([zen-mcp-server](https://github.com/BeehiveInnovations/zen-mcp-server) 시도)
- 정적 분석 대체 (Semgrep / CodeQL과 함께 사용)
- 모든 PR에 자동 실행 (ccg는 트리아지 도구, 봇이 아닙니다)
- 스트리밍 출력 또는 멀티턴 대화

## 아키텍처 및 기여

ccg는 **7개 계층**으로 구성되며, "분기 검출"은 최상위 1개 계층일 뿐입니다. 아래 6개 계층(캐시, 원장, 사용량, 위험 라우팅, 스마트 diff, 안전한 CLI 스케줄링)은 각각 독립적으로 실제 문제를 해결합니다. `ccg.sh`를 변경하기 전에 [docs/ARCHITECTURE.ko.md](docs/ARCHITECTURE.ko.md)를 읽어주세요.

테스트:

```bash
bash tests/test_ccg.sh                # 99개 회귀 테스트, ~31s
REAL_CLI=1 bash tests/test_ccg.sh     # +2개 실제 API 테스트 (비용 발생)
```

## 라이선스 및 감사의 말

MIT —— [LICENSE](LICENSE) 참조.

[oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode)의 원래 `/ccg` 컨셉 · Claude Code · OpenAI Codex CLI · Google Gemini CLI 기반.
