# ADR-005: 의존성 자동 업데이트 및 자동 버저닝 전략

- **상태**: 승인
- **일자**: 2026-03-02
- **관련 문서**: [TECHSPEC 10.2절 — CI/CD 파이프라인](../TECHSPEC.md#102-cicd-파이프라인)

---

## 맥락

Phase 0 CI/CD 파이프라인에서 의존성 업데이트와 버전 관리 자동화가 필요하다.

AAA는 5개 독립 레포로 구성된 MSA 시스템이며, 각 레포가 서로 다른 에코시스템(Gradle, uv, Docker Compose)의 의존성을 갖는다. 1인 프로젝트에서 이를 수동으로 관리하면 업데이트 누락과 보안 취약점 방치 위험이 있다.

또한 릴리스 버전 결정과 Docker 이미지 태깅을 수동으로 처리하면 버전 불일치와 배포 오류가 발생할 수 있다.

---

## 결정

### 1. Dependabot — 의존성 자동 업데이트

레포별 `.github/dependabot.yml` 개별 설정으로 의존성 업데이트 PR을 자동 생성한다.

- 에코시스템: `docker-compose`(aaa-infra), `gradle`(Java 서비스), `uv`(aaa-analyzer), `github-actions`(전체)
- 스케줄: `weekly`, 레포별 요일 분산으로 PR 집중 방지
- Security Updates: 즉시 활성화 (CVE 감지 시 자동 PR)

### 2. semantic-release — 커밋 기반 자동 버저닝

커밋 메시지에서 SemVer를 자동 결정한다: `feat` → minor, `fix` → patch, `!` → major.

- Gitmoji + Conventional Commits 하이브리드 형식 지원: `@semantic-release/commit-analyzer`의 커스텀 `headerPattern`으로 `✨ feat(scope): ...` 파싱
- Java 서비스: semantic-release + `gradle-semantic-release-plugin` (`gradle.properties` 버전 자동 업데이트)
- Python 서비스: python-semantic-release + 커스텀 파서 (`pyproject.toml` 버전 자동 업데이트)

### 3. Docker 이미지 태그 — 3중 태그 동시 push

릴리스 시 GHCR에 3가지 태그를 동시 push한다:

- `:v1.2.3` — 불변 태그, 롤백 및 감사 기준점
- `:latest` — Watchtower 폴링 대상
- `:sha-<commit>` — 트레이서빌리티, 디버깅

배포 흐름: main 머지 → semantic-release → Git 태그(v1.2.3) → `on: push: tags` → Docker Buildx → GHCR push → Watchtower 감지

---

## 검토한 대안

### Dependabot vs Renovate

| 항목 | Dependabot | Renovate |
|------|-----------|----------|
| 장점 | GitHub 내장, 설정 간단, Security Updates 자동 | 멀티 레포 중앙 관리, 세밀한 그룹화, 자동 병합 규칙 |
| 단점 | 레포별 개별 설정 필요 | 초기 설정 복잡, 별도 앱 설치 필요 |

**결정**: GitHub 내장 Dependabot으로 시작한다. 5개 레포 규모에서는 개별 설정 부담이 크지 않다. 레포 수 증가 또는 고급 그룹화가 필요해지면 Renovate로 마이그레이션한다.

### semantic-release vs release-please

| 항목 | semantic-release | release-please |
|------|-----------------|----------------|
| 장점 | Gitmoji 커스텀 파서 지원, main 머지 시 즉시 릴리스, 플러그인 생태계 풍부 | Google 유지보수, Manifest 모노레포 지원 |
| 단점 | Node.js 런타임 필요 | Gitmoji 미지원(Issue #2385 미해결), Release PR 수동 머지 필요, FF-only 정책 충돌 |

**결정**: semantic-release를 채택한다. release-please는 Gitmoji를 지원하지 않으며(Issue #2385), Release PR 기반 워크플로우가 FF-only 병합 정책과 충돌한다.

### `semantic-release-gitmoji` 플러그인 vs 커스텀 `headerPattern`

| 항목 | semantic-release-gitmoji | 커스텀 headerPattern |
|------|------------------------|---------------------|
| 장점 | 이모지 기반 버전 결정 자동화 | 기본 commit-analyzer 사용, Conventional Commits type/scope 유지 |
| 단점 | Conventional Commits type/scope 무시, 별도 플러그인 의존 | 정규식 직접 작성 필요 |

**결정**: 커스텀 `headerPattern`을 사용한다. 기본 `@semantic-release/commit-analyzer`에서 정규식만 변경하면 `✨ feat(scope): ...` 형식을 파싱할 수 있으며, Conventional Commits의 type/scope 체계를 그대로 활용할 수 있다.

---

## 결과

- Dependabot Security Updates를 즉시 활성화한다.
- Dependabot Version Updates는 Phase별 서비스 개발 착수 시 점진적으로 설정한다.
- semantic-release 설정은 첫 번째 서비스(aaa-collector) CI/CD 구축 시 함께 구현한다.
