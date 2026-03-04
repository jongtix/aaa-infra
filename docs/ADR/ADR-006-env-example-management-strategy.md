# ADR-006: `.env.example` 관리 전략 — 혼합형

- **상태**: 승인
- **일자**: 2026-03-02
- **관련 문서**: [TECHSPEC 3.8절 — KIS API 토큰 관리](../TECHSPEC.md#38-kis-api-토큰-관리)

---

## 맥락

AAA는 5개 독립 git 레포로 구성된 MSA 시스템이다. Phase 0 인프라 구성 중 `aaa-infra/.env.example`에 인프라 공통 변수뿐만 아니라 `.env.collector` 등 서비스별 변수 가이드까지 포함하고 있었다.

인프라 컨테이너(MySQL, Redis)와 앱 서비스는 시크릿 접근 범위를 격리하므로, `aaa-infra/.env.example`은 `.env.mysql`, `.env.redis`, `.env.common` 세 파일의 템플릿을 포함한다. 격리 전략 상세는 [TECHSPEC 3.8절 시크릿 보호](../TECHSPEC.md#38-kis-api-토큰-관리)를 참조한다.

서비스별 변수(KIS API 키, 외부 API 키, 텔레그램 토큰 등)는 해당 서비스의 Phase에서 확정되므로, 인프라 레포에서 이를 관리하면 두 가지 문제가 발생한다:

1. 변수명/구조 변경 시 `aaa-infra`와 해당 서비스 레포 양쪽을 수정해야 한다.
2. 서비스 개발자가 서비스 레포만 클론해도 필요한 환경 변수 정보를 찾을 수 있어야 한다.

---

## 결정

`.env.example` 관리를 **혼합형**으로 분리한다.

| 위치 | 관리 범위 |
|------|-----------|
| `aaa-infra/.env.example` | 인프라 공통 변수만 — `.env`, `.env.mysql`, `.env.redis`, `.env.common` |
| 각 서비스 레포 `.env.example` | 해당 서비스 전용 변수만 — 해당 Phase 착수 시 작성 |

**`aaa-infra/.env.example`에서 제거되는 내용**: `.env.collector`, `.env.analyzer`, `.env.notifier`, `.env.trader` 섹션

**서비스 레포 `.env.example` 작성 시점**: 각 서비스의 Phase 착수 직전

---

## 검토한 대안

### 중앙 집중형 — `aaa-infra`에서 전체 관리

| 장점 | 단점 |
|------|------|
| 환경 변수 전체 목록을 한 곳에서 파악 가능 | 서비스 변수 변경 시 `aaa-infra` 레포도 수정 필요 |
| | 서비스 레포만 클론한 경우 가이드 부재 |
| | Phase 미착수 서비스 변수를 미리 예상해서 작성해야 함 |

### 서비스 분산형 — 각 레포에서만 관리

| 장점 | 단점 |
|------|------|
| 서비스 독립성 최대화 | 인프라 공통 변수 가이드 위치 모호 |
| | `aaa-infra` 레포 단독 세팅 시 참고 문서 없음 |

### 혼합형 (채택)

인프라 공통 변수는 `aaa-infra`에, 서비스 전용 변수는 각 서비스 레포에 둔다. 수정 범위가 자연스럽게 격리되고, 각 레포가 자기 완결적 온보딩 정보를 갖는다.

---

## 결과

- `aaa-infra/.env.example`은 인프라 컨테이너 구성(MySQL, Redis, Docker Compose) 온보딩 용도로만 사용한다.
- 서비스별 `.env.example`은 Phase 1~4 착수 시 해당 서비스 레포에 작성한다.
- TECHSPEC 3.8절의 `.env.example` 관련 문구를 이 결정에 맞게 갱신한다.
- 배포 시 `scripts/init-nas.sh`가 `${AAA_SSD_BASE}/secrets/` 디렉토리를 생성하고 `chmod 700`을 적용한다. `.env.*` 파일은 디렉토리 배치 후 개별 `chmod 600` 적용이 필요하다.
