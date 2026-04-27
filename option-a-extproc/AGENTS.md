# AGENTS.md

## 프로젝트 요약

이 저장소는 Envoy AI Gateway v0.5 기반 LLM 대화 메모리 PoC다.

클라이언트는 `x-session-id`를 보내고, custom `memory-extproc`가 Redis에서 이전 대화를 읽어 요청 `messages`에 병합한 뒤 assistant 응답을 다시 Redis에 저장한다.

핵심 경로:

- 디버그 경로: `Host: debug.local` 기반 `test-route`
- 공식 경로: `AIGatewayRoute` + `AIServiceBackend` + `BackendSecurityPolicy`

---

## 현재 작업 상태 확인 규칙

- 현재 활성 PR, 브랜치, 상태는 항상 아래 명령으로 확인한다:
  - `git status --short`
  - `git branch --show-current`
  - `gh pr view`
- AGENTS.md에 적힌 과거 상태를 그대로 신뢰하지 않는다.
- “source of truth PR”은 항상 최신 open PR 기준으로 판단한다.

---

## 세션 시작 루틴

새 세션 시작 시 반드시 아래 순서로 진행한다:

1. `git status --short`
2. `git branch --show-current`
3. `gh pr view`
4. 관련 문서만 선택적으로 읽기 (`docs/handoff-*`, 필요한 README 섹션 등)
5. 현재 작업 목표를 5줄 이하로 요약

주의:
- 바로 코드 수정하지 않는다.
- 전체 repo를 읽지 않는다.

---

## 작업 규칙

- `main`을 직접 수정하지 않는다.
- force push를 하지 않는다.
- README는 사용자가 명시적으로 지시하지 않으면 수정하지 않는다.
- 이미 merge된 PR은 특별한 지시 없이 수정하거나 닫지 않는다.
- 작업 전 반드시 현재 PR 상태를 확인한다.

---

## 변경 작업 규칙

- 코드/문서 수정 전 반드시:
  - 변경 계획을 5줄 이하로 먼저 제시한다.
- 사용자 승인 없이 대규모 수정 금지
- 한 번에 하나의 변경만 수행
- 불필요한 파일 수정 금지

---

## PR 범위 규칙

- 하나의 PR은 하나의 목적만 가진다.
- 이미 merge된 PR의 내용을 다시 포함하지 않는다.
- 후속 작업은 기존 PR에 추가하지 않고 새로운 PR로 분리한다.
- PR description은 “이 PR에서 새로 추가된 내용” 중심으로 작성한다.

---

## PR/코멘트 규칙

- 모든 PR description, PR comment, commit message는 한국어로 작성한다.
- 영어와 한국어를 혼용하지 않는다.
- 영어로 자동 생성된 문장은 반드시 한국어로 수정한다.

PR 본문 기본 구조:

- 목적
- 변경
- 검증
- 제한
- 후속 작업

---

## 검증 규칙

- 변경 후 반드시:
  - 관련 검증 명령 최소 1개 실행
  - 결과를 PASS/FAIL로 요약
- 전체 테스트 대신 최소 범위 검증부터 수행한다.

예:
```bash
VERIFY_EXTERNAL_OPENROUTER=1 bash scripts/verify-step5.sh
```

---

## 토큰 절약 규칙

- 전체 repo를 무작정 읽지 않는다.
- 작업과 직접 관련된 파일만 읽는다.
- 출력은 짧게 유지한다.
- 긴 로그를 붙여넣지 않고 핵심만 요약한다.
- 동일한 설명 반복 금지
