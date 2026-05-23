# ccg — Code Divergence Detector

> Claude Code 슬래시 명령. 한 번 설치하고 diff 위에서 `/ccg`를 입력하세요.

[![Tests](https://img.shields.io/badge/tests-99%20passing-brightgreen.svg)]()
[![npm](https://img.shields.io/npm/v/@mcgrapeng/ccg.svg)](https://www.npmjs.com/package/@mcgrapeng/ccg)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[English](README.md) ｜ [简体中文](README.zh-CN.md) ｜ [日本語](README.ja.md) ｜ **한국어**　·　[아키텍처 →](docs/ARCHITECTURE.md)

---

## ccg란

ccg는 **Codex(OpenAI)** 와 **Gemini(Google)** 가 같은 diff를 병렬로 평가하게 하고, **Claude** 가 둘의 의견이 갈리는 부분을 부각시킵니다 —— 사람이 실제로 판단해야 할 지점이 바로 거기입니다.

대부분의 AI 리뷰 도구는 합의를 추구합니다. ccg는 그 반대. 합의 = 낮은 신호, 분기 = 황금.

## ccg가 할 수 있는 것

단일 모델 리뷰 도구로는 얻을 수 없는 세 가지:

**1. Claude처럼 사고하지 않는 두 번째 의견.**
Codex와 Gemini는 훈련 데이터가 달라서 발견하는 것이 다릅니다. `auth/login.go`의 같은 변경에 대해 의견이 갈리면, 거기가 바로 멈춰야 할 곳입니다.

**2. 내장된 비용 가시성.**
Codex / Gemini CLI는 지출을 알려주지 않습니다. ccg는 모든 호출을 기록하고, 위험에 따라 가장 저렴하고 충분한 모델을 자동 선택(위험 라우팅)하며, 같은 프롬프트는 24시간 캐시로 비용 0이 됩니다.

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

## 사용법

변경이 있는 임의의 git 저장소에서 Claude Code를 열고 입력:

```
/ccg
```

ccg는 자동으로:

1. 활성 diff 캡처 (worktree → staged → upstream → origin-head 4단계 폴백)
2. 위험 점수 → `cost` / `balanced` / `quality` 모델 자동 선택
3. Codex + Gemini가 같은 프롬프트로 병렬 실행
4. 세 섹션으로 합성:

```
═══ AGREEMENT (N)  ═══   양쪽 모두 지적 — 낮은 신호, 각 한 줄
═══ DIVERGENCE (M) ═══   ★ ccg의 핵심 가치
                          - Codex: X라고 함
                          - Gemini: Y라고 함
                          - Claude 판단: ___ 또는 NEEDS HUMAN DECISION
═══ BLINDSPOT (≤2) ═══  둘 다 못 봤지만 Claude 의심 — 신중히 사용
═══ VERDICT ═══         merge / fix-required / discuss
```

그다음 `ccg_ledger_record`가 JSONL 한 줄을 추가. `ccg_cleanup`이 작업 디렉토리를 정리합니다.

## 설정 (기본값으로 보통 충분)

모드와 모델 선택은 자동입니다. 필요할 때만 재정의:

```bash
CCG_MODE=quality /ccg          # 모든 diff에 quality 모델 강제
CCG_CODEX_MODEL=o3 /ccg        # 단일 모델만 재정의
CCG_NO_CACHE=1 /ccg            # 이번 호출만 24h 캐시 우회
```

모든 설정은 [아키텍처 §5 확장 지점](docs/ARCHITECTURE.md#5-extension-points)에 있습니다. 자주 쓰는 것:

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

ccg는 **7개 계층** 으로 구성되며, "분기 검출"은 최상위 1개 계층일 뿐입니다. 아래 6개 계층(캐시, 원장, 사용량, 위험 라우팅, 스마트 diff, 안전한 CLI 스케줄링)은 각각 독립적으로 실제 문제를 해결합니다. `ccg.sh`를 변경하기 전에 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)를 읽어주세요.

테스트:

```bash
bash tests/test_ccg.sh                # 99개 회귀 테스트, ~31s
REAL_CLI=1 bash tests/test_ccg.sh     # +2개 실제 API 테스트 (비용 발생)
```

## 라이선스 및 감사의 말

MIT —— [LICENSE](LICENSE) 참조.

[oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode)의 원래 `/ccg` 컨셉 · Claude Code · OpenAI Codex CLI · Google Gemini CLI 기반.
