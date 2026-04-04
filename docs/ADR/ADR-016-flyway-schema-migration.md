# ADR-016: Flyway 기반 스키마 마이그레이션 전략 채택

- **상태**: 승인
- **일자**: 2026-03-29
- **범위**: aaa-collector (스키마 소유자 — notifier·trader·analyzer 포함 전체 DB 마이그레이션 책임)

---

## 맥락

Watchtower 자동 배포 환경에서 새 이미지가 기동되면 애플리케이션이 DB 스키마 일치를 보장해야 한다. 수동 DDL 실행이나 `ddl-auto=update`에 의존하면 다음 문제가 발생한다.

- **수동 DDL**: Watchtower가 자동으로 컨테이너를 교체하는 환경에서 배포마다 수동 개입이 필요하다. 1인 개발 환경에서 이를 빠짐없이 실행하는 것은 현실적으로 불가능하다.
- **`ddl-auto=update`**: Hibernate가 컬럼·인덱스를 자동 추가하지만 컬럼 삭제·타입 변경·인덱스 삭제는 수행하지 않는다. 스키마 이력 추적이 없어 현재 DB 상태를 코드로 재현할 수 없다.

aaa-collector는 이미 GitHub Actions → GHCR → Watchtower CI/CD 파이프라인을 보유한다. aaa-infra는 별도 CI/CD가 없어 독립 마이그레이션 도구 실행이 불가능하다. 따라서 collector 기동 시 마이그레이션을 자동 실행하는 것이 유일한 자동화 경로다.

마이그레이션 소유권과 관련하여, `notification_log`(notifier)와 `order_log`(trader) 테이블도 동일 MySQL 인스턴스([ADR-001](ADR-001-single-mysql-instance.md))에 위치한다. 각 서비스가 자체 마이그레이션을 소유하면 `flyway_schema_history` 충돌, 외래키·순서 의존성 관리 문제가 발생한다.

---

## 결정

### 결정 1: Flyway 채택 + `ddl-auto=validate` 이중 검증

aaa-collector에 Flyway 의존성을 추가하고 `spring.jpa.hibernate.ddl-auto=validate`를 설정한다.

- Flyway가 먼저 마이그레이션 스크립트를 실행하여 스키마를 원하는 상태로 만든다.
- 이후 Hibernate `validate`가 엔티티와 실제 스키마의 일치 여부를 검증하여, 마이그레이션 누락이나 엔티티-DDL 불일치를 기동 시점에 즉시 감지한다.

### 결정 2: aaa-collector가 전체 DB 스키마 마이그레이션 소유

aaa-collector가 notifier·trader 테이블(`notification_log`, `order_log` 포함)의 마이그레이션 스크립트까지 보유한다.

- **파일 위치**: `aaa-collector/src/main/resources/db/migration/`
- **파일 네이밍**: `V{번호}__{서비스접두사}_{설명}.sql` (예: `V1__collector_create_stocks.sql`, `V10__notifier_create_notification_log.sql`)
- **번호 체계**: 전역 순차 번호. 서비스별 대역 예약 금지 (Flyway 선형 버전 모델과 충돌)

notifier·trader는 `spring.flyway.enabled=false`로 Flyway를 비활성화한다.

### 결정 3: collector startup에서 마이그레이션 실행

Spring Boot 기동 시 Flyway가 자동으로 pending 마이그레이션을 실행한다.

배포 파이프라인:
```
git push → GitHub Actions → GHCR 이미지 빌드 → Watchtower 감지 → 컨테이너 재기동 → Flyway(flyway 계정) migrate → Hibernate validate → 서비스 기동 완료
```

DB 사용자 권한 — Flyway 전용 계정과 서비스 런타임 계정을 분리한다:
- `flyway`: SELECT, INSERT, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES (Flyway 마이그레이션 전용. `spring.flyway.user`로 지정)
- `collector`: SELECT, INSERT + UPDATE(stocks, stock_grades, backfill_status만). DELETE/DDL 없음
- `notifier`: SELECT, INSERT + 필요 테이블 UPDATE. `notification_log`는 SELECT/INSERT만 (INSERT-ONLY)
- `trader`: SELECT, INSERT + 필요 테이블 UPDATE. `order_log`는 SELECT/INSERT만 (INSERT-ONLY)
- `analyzer`: SELECT, INSERT (trading_signals에 INSERT, 나머지는 SELECT)

서비스 런타임 계정에 DELETE/DDL 권한을 부여하지 않는다. DELETE가 필요한 경우 별도 ADR로 명시적 결정 후 추가한다.
시계열 데이터 테이블은 `INSERT IGNORE`로 중복 방지하며 UPDATE를 사용하지 않는다. collector의 UPDATE 권한은 상태 변경이 필요한 마스터/메타데이터 테이블에만 화이트리스트로 부여한다.

---

## 검토한 대안

### Option A: 수동 DDL — 기각

| 항목 | 내용 |
|------|------|
| 장점 | 스키마 변경에 대한 완전한 수동 통제 |
| 단점 | Watchtower 자동 배포 환경에서 배포마다 수동 개입 필요. 1인 환경에서 누락 가능성 높음. 스키마 이력 코드 관리 불가 |

기각.

### Option B: `ddl-auto=update` — 기각

| 항목 | 내용 |
|------|------|
| 장점 | 별도 마이그레이션 도구 불필요 |
| 단점 | 컬럼 삭제·타입 변경 미수행. 스키마 이력 없음. 현재 DB 상태를 코드로 재현 불가 |

기각.

### Option C: aaa-infra에 마이그레이션 스크립트 보관 + CI/CD 실행 — 기각

| 항목 | 내용 |
|------|------|
| 장점 | 스키마를 인프라 레이어에서 독립 관리. DDL 전용 사용자 분리 가능 |
| 단점 | aaa-infra에 CI/CD 없음. 별도 실행 트리거가 없어 자동화 불가. 현재 없는 인프라 구축 비용 발생 |

기각.

### Option D: 각 서비스가 자체 마이그레이션 소유 — 기각

| 항목 | 내용 |
|------|------|
| 장점 | 서비스 자율성 보장 |
| 단점 | 단일 MySQL 인스턴스([ADR-001](ADR-001-single-mysql-instance.md))에서 여러 Flyway 인스턴스 동시 실행 시 `flyway_schema_history` 충돌. 테이블 생성 순서 의존성 관리 복잡 |

기각.

---

## 결과

- aaa-collector 기동 시 Flyway가 자동으로 스키마를 최신 상태로 마이그레이션한다.
- Hibernate `validate`가 엔티티-스키마 불일치를 기동 시점에 감지한다.
- notifier·trader 테이블은 collector 마이그레이션 스크립트에서 관리되므로 Phase 3·4 서비스 기동 전에도 테이블이 존재한다.
- 적용된 마이그레이션 스크립트는 수정하지 않는다. 변경이 필요한 경우 새 버전 스크립트를 추가한다.

**트레이드오프**: DDL은 `flyway` 전용 계정으로 분리되어 런타임 코드에서 DDL 실행이 원천 차단된다. 서비스 런타임 계정의 DDL 권한 문제는 해소된다.

**위험 범위**: 잘못된 마이그레이션 스크립트는 `flyway` 계정의 DDL 권한 범위 내에서 영향을 미친다. collector 런타임 코드가 오염될 경우 영향 범위는 SELECT/INSERT + UPDATE(3개 테이블)로 제한된다.

**완화 수단** (Flyway 마이그레이션 스크립트에 대하여):
- Flyway 체크섬 검증으로 기존 스크립트 변조를 자동 감지한다.
- 마이그레이션 스크립트는 코드 리뷰 대상이며 git 이력으로 추적된다.
- 프로덕션 배포 전 로컬 환경에서 마이그레이션 검증을 선행한다.
- MySQL 정기 백업으로 복구 경로를 확보한다.

**수용 기준**: `flyway` 계정의 DDL 권한은 마이그레이션 실행 시점에만 사용되며, 런타임에서 DROP/ALTER 위험이 원천 차단된다. 1인 개발 환경에서 자동화 이익(배포마다 수동 개입 제거)과 런타임 권한 최소화를 동시에 달성한다.

**배포 순서 제약**: 스키마 변경이 동반된 다중 서비스 배포 시 collector가 먼저 마이그레이션을 완료해야 notifier·trader가 정상 기동된다. 두 배포 경로에 대한 대응 방식이 다르다.

- **`docker compose up` 경로**: collector에 `/actuator/health` health check를 설정하고, notifier·trader는 `depends_on: condition: service_healthy`로 collector가 healthy 상태가 될 때까지 기동을 대기한다.
- **Watchtower 경로**: Watchtower의 `com.centurylinklabs.watchtower.depends-on` 라벨은 start 순서만 보장하며 healthy 대기 로직이 없다(소스코드 `internal/actions/update.go` 확인). 또한 Watchtower는 2025-12-17 아카이브(read-only)로 향후 개선이 없다. 따라서 notifier·trader가 collector의 Flyway 마이그레이션 완료 전에 기동을 시도하면 DB 스키마 불일치로 일시적으로 크래시가 발생할 수 있다. `restart: unless-stopped` 정책으로 자동 재기동되며, Flyway 마이그레이션 완료 후 재기동 시 정상 기동된다. 이 일시적 크래시는 **버그가 아닌 정상 동작**이다. 로그에서 확인되더라도 별도 조치가 필요하지 않다.

**장애 판별 수단 (Phase 3 착수 전 구현)**: 일시적 크래시(정상 동작)와 Flyway 스크립트 오류로 인한 collector 비정상 종료(실제 장애)는 증상이 동일하여 구분이 어렵다. Phase 3 notifier 구현 시 기동 실패 연속 N회 시 시스템봇 알림을 추가한다. N 임계치는 Phase 3 착수 후 실제 마이그레이션 소요 시간 및 재기동 간격 데이터를 확인하여 결정한다.

**Flyway 배포 패턴 검토**: 단일 인스턴스 Docker 환경에서 Flyway를 독립 컨테이너로 분리하는 패턴은 Kubernetes 멀티 Pod(동일 앱 여러 인스턴스 동시 기동) 환경에서 의미를 가진다. 단일 인스턴스에서는 앱 내장(임베드) 방식이 표준이며, 현 환경에 완전히 적합하다. 독립 컨테이너 방식은 aaa-infra에 CI/CD가 없어 SQL 파일을 자동 배포할 수 없고, 볼륨 마운트 방식은 Watchtower 자동화와 충돌하므로 현시점 채택 불가(Option C 기각 사유와 동일). 향후 aaa-infra에 CI/CD가 추가되는 시점에 독립 컨테이너 방식을 재검토할 수 있다.

**향후 적용**: aaa-analyzer(Python, Phase 2)의 `trading_signals` 테이블도 collector Flyway가 소유하는 것을 기본 방침으로 한다. analyzer는 SQLAlchemy로 SELECT, INSERT만 수행하며(trading_signals에 예측 결과 INSERT, 나머지 테이블은 SELECT 전용) DDL은 보유하지 않는다. Phase 2에서 Python 전용 마이그레이션이 필요한 근거가 생기는 경우에만 별도 ADR로 재검토한다.
