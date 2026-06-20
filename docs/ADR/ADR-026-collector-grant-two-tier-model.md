# ADR-026: collector DB 권한 2-tier 모델 및 GRANT 버전관리

- **상태**: 승인
- **일자**: 2026-06-13

---

## 맥락

[ADR-025](ADR-025-daily-ohlcv-raw-price-storage.md)의 `daily_ohlcv` SQL 1142 조사 중, 더 큰 문제가 드러났다.

- 라이브 DB의 `collector` 권한은 `SELECT, INSERT ON aaa.*` 뿐이다(`SHOW GRANTS` 검증). UPDATE가 전혀 없다.
- 그러나 TECHSPEC §4(`:575`)는 "collector: SELECT, INSERT + UPDATE(stocks, stock_grades, backfill_status, short_sale_overseas만)"라고 명시한다 — **문서가 정의한 의도와 라이브 GRANT가 표류(drift)** 했다.
- init 스크립트(`config/mysql/initdb.d/01-init-collector.sh`)에도 collector UPDATE GRANT가 누락돼 있고, 이 스크립트는 **NAS에만 존재하며 레포에서 버전 관리되지 않는다**. 또한 initdb.d는 데이터 디렉토리 최초 초기화 시에만 실행되므로 사후 수정이 라이브 DB에 반영되지 않는다.

결과적으로 `stocks`(종목명 변경·관심목록 이탈), `stock_grades`(재등급), `etf_metadata`(메타 갱신), `short_sale_overseas`(이중 소스 병합) 등 **마스터/상태 테이블의 UPDATE가 모두 SQL 1142로 실패하는 잠재 버그**가 존재한다. 이들은 특정 조건(이름 변경, 이탈, 등급 변동, 두 번째 소스 수집)에서만 발화하여 그동안 드러나지 않았고, 일일 수집의 중복 충돌이 필연적인 `daily_ohlcv`가 먼저 표면화됐다.

권한 모델 설계 방향으로 세 가지가 검토됐다: (1) 테이블·컬럼별 세분화, (2) 전면 UPDATE 허용, (3) 테이블 단위 2-tier. 본 ADR이 이를 확정하고 누락 GRANT 복원을 정의한다.

---

## 결정

### 결정 1 — 테이블 단위 2-tier 권한 모델 (컬럼별 GRANT 불채택)

collector 권한은 **테이블 단위**로 두 부류로 나눈다. 컬럼 레벨 GRANT는 사용하지 않는다.

- **Tier 1 (INSERT 전용)**: 한 번 쓰면 변하지 않는 테이블. 시계열·이벤트·이력·로그. → `SELECT, INSERT`. UPDATE/DELETE 없음. DB 레벨에서 불변성을 강제한다.
- **Tier 2 (UPDATE 허용)**: 제자리 변경이 본질인 테이블. 마스터·상태·다중소스 병합. → `SELECT, INSERT, UPDATE`. DELETE는 없음(소프트 삭제 — [ADR-022](ADR-022-watchlist-sync-stocks-update-strategy.md) 결정 5).

분류는 "이 테이블의 행이 쓰여진 뒤 제자리에서 갱신되어야 하는가"라는 단일 규칙으로 결정한다. 신규 테이블은 이 규칙으로 자동 분류되므로 테이블당 개별 판단이 아니라 규칙 적용이다.

ADR-022가 명시한 "nameKo/nameEn만 갱신"은 **애플리케이션 코드 로직**이며 DB 컬럼 GRANT가 아니다. DB 권한은 테이블 단위로만 관리한다.

### 결정 2 — collector Tier-2 GRANT 복원 + TECHSPEC §4 정정

현재 누락된 collector UPDATE 권한을 복원한다. 코드 검증으로 확정한 Tier-2 집합은 다음과 같다.

| 테이블 | 근거 |
|--------|------|
| `stocks` | 마스터 — 종목명·active·watchlist_removed_at 갱신 (`StockRepository`, ADR-022) |
| `stock_grades` | 상태 — 재등급 시 갱신 (`StockGradePersistService`) |
| `short_sale_overseas` | FINRA Daily/Short Interest 이중 소스 UPSERT 병합 ([ADR-017](ADR-017-short-sale-table-split.md), TECHSPEC §4) |
| `etf_metadata` | 메타 upsert — `EtfMetadataWriter.upsert()`의 `existing.updateFrom()` |
| `backfill_status` | 상태 — 백필 진행점 전진(`last_collected_date`/`attempt_count`/`status` UPDATE). 시딩=INSERT IGNORE(Tier-1), 진행점 전진=UPDATE(Tier-2) (SPEC-COLLECTOR-BACKFILL-001, 아래 개정 참고) |

TECHSPEC §4(`:575`)는 두 가지를 정정한다:
- **`backfill_status` 제거** — (본 ADR 제정 시점 2026-06-13) 해당 테이블은 존재하지 않았다(마이그레이션 부재). 미구현 테이블을 권한 목록에 두지 않았다. → **2026-06-20 재추가**: SPEC-COLLECTOR-BACKFILL-001이 `backfill_status` 테이블(V24)을 생성하면서 Tier-2로 재등재한다(아래 개정 절 참고).
- **`etf_metadata` 추가** — 실제 갱신되나 목록에서 누락돼 있었다.

나머지 12개 테이블(`daily_ohlcv`, `market_indicators`, `investor_trend`, `credit_balance`, `short_sale_domestic`, `macro_indicators`, `news_headlines`, `analyst_estimates`, `corporate_events`, `futures_daily`, `financials`, `etf_representative_history`)은 Tier 1(INSERT 전용)로 둔다. `financials`/`analyst_estimates`/`news_headlines`는 현재 증거상 INSERT 전용이며, 갱신 필요가 확인되면 결정 3의 검증이 포착한다.

### 결정 3 — GRANT 버전관리 및 검증

표류 재발을 막기 위해 GRANT를 코드로 관리하고 검증한다.

- init 스크립트(`01-init-collector.sh`)를 **aaa-infra 레포로 버전 관리**한다(현재 NAS에만 존재).
- 라이브 DB의 실제 GRANT가 선언된 Tier 모델과 일치하는지 **검증**한다(통합 테스트 또는 배포 후 헬스체크). 불일치 시 경고·실패시킨다.
- GRANT 변경은 항상 버전 관리되는 스크립트를 통해서만 한다.

### 결정 4 — collector DELETE 미부여 유지

collector는 어떤 테이블에도 DELETE 권한을 갖지 않는다. 물리 삭제 대신 `active`/`watchlist_removed_at` 등 소프트 삭제를 사용한다(ADR-022 결정 5). 물리 삭제가 필요하면 별도 권한 경로로 처리한다(ADR-025 결정 4의 out-of-band 원칙과 일관).

---

## 검토한 대안

### 대안 1 — 전면 UPDATE 허용 (`GRANT SELECT, INSERT, UPDATE ON aaa.*`)

| 항목 | 내용 |
|------|------|
| 장점 | 관리 부담 0. GRANT 표류 불가능 |
| 단점 | 시계열·로그 테이블의 DB 강제 불변성 상실 |

기각. 이번 `daily_ohlcv` 버그가 **잡힌 이유 자체가** collector에 해당 UPDATE 권한이 없었기 때문이다. 전면 UPDATE였다면 코드의 `ON DUPLICATE KEY UPDATE`가 조용히 시계열 행을 덮어쓰며 데이터를 오염시켰을 것이다. `order_log`/`notification_log`(Phase 3/4)의 INSERT-ONLY 강제(TECHSPEC §4)도 감사 무결성에 필수다. 테이블별 권한은 실증된 무결성 안전망이다.

### 대안 2 — 테이블·컬럼별 세분화 GRANT

| 항목 | 내용 |
|------|------|
| 장점 | 최소 권한 극대화 |
| 단점 | 컬럼 레벨 GRANT는 스키마 변경마다 깨지고 관리 부담이 크다 |

기각. 컬럼 단위 통제는 애플리케이션 코드(ADR-022)가 담당하면 충분하며, DB 컬럼 GRANT의 유지 비용이 이득을 초과한다.

---

## 결과

collector 권한을 테이블 단위 2-tier로 확정하고, 누락된 Tier-2 UPDATE GRANT(`stocks`, `stock_grades`, `short_sale_overseas`, `etf_metadata`, 그리고 2026-06-20 개정으로 `backfill_status`)를 복원한다. TECHSPEC §4를 정정(`backfill_status` 제거, `etf_metadata` 추가)하고, init 스크립트를 레포로 버전 관리하며 라이브 GRANT 일치를 검증한다. 이로써 마스터/상태 테이블의 UPDATE 실패(잠재 1142)가 해소되고, 시계열·로그 테이블의 DB 강제 불변성은 유지된다.

### 긴급도

collector의 Tier-2 UPDATE 누락은 **현재 production에서 watchlist sync(이름 변경·이탈), 재등급, ETF 메타 갱신, FINRA 해외 공매도 병합을 조건부로 깨뜨리는 라이브 결함**이다. 라이브 DB GRANT 복원은 우선순위 높음으로 처리한다. (`daily_ohlcv`는 본 ADR 대상이 아니며 ADR-025/SPEC-COLLECTOR-OHLCV-001의 INSERT IGNORE로 별도 해결 — collector에 daily_ohlcv UPDATE를 부여하지 않는다.)

### 한계

- `financials`/`analyst_estimates`/`news_headlines`의 Tier 1 분류는 현재 코드 증거 기반이다. 향후 갱신 요구가 생기면 결정 3의 검증이 포착하고 재분류한다.
- init 스크립트는 데이터 디렉토리 최초 초기화 시에만 실행되므로, 기존 라이브 DB에는 GRANT를 별도로 적용(`GRANT ... ON aaa.<table> TO 'collector'@'%'`)해야 한다. 스크립트 수정만으로는 기존 DB에 반영되지 않는다.

### 후속 작업

- 라이브 NAS DB에 Tier-2 UPDATE GRANT 적용(우선순위 높음)
- `01-init-collector.sh`를 aaa-infra 레포로 이관 + Tier 모델 반영
- GRANT 일치 검증 메커니즘 구현(통합 테스트 또는 배포 헬스체크)
- TECHSPEC §4 정정(`:575` — `backfill_status` 제거, `etf_metadata` 추가, 본 ADR 링크)

---

## 개정 — 2026-06-20: `backfill_status` Tier-2 재등재 (SPEC-COLLECTOR-BACKFILL-001)

본 ADR 제정 시점(2026-06-13)에는 `backfill_status` 테이블이 존재하지 않아 Tier-2 목록에서 제거됐다(결정 2). SPEC-COLLECTOR-BACKFILL-001이 KIS 과거 데이터 백필을 도입하며 `backfill_status` 테이블(마이그레이션 V24, aaa-collector)을 생성했고, 이에 따라 Tier-2로 재등재한다.

### 권한 구분 — 시딩(INSERT)과 진행점 전진(UPDATE)

`backfill_status`는 두 가지 쓰기 경로가 권한 티어를 가른다.

- **시딩 = INSERT IGNORE (Tier-1로 충분)**: cron 진입부에서 활성 관심종목 × 시장별 data_table 누락 행을 `INSERT IGNORE`로 생성한다. UPDATE 권한이 필요 없다.
- **진행점 전진 = UPDATE (Tier-2 필요)**: 윈도우 1구간 커밋 시 `last_collected_date`/`attempt_count`/`status`를 제자리 갱신한다. 이 경로가 Tier-2 UPDATE 권한을 요구하므로 `backfill_status`를 Tier-2 허용목록에 둔다. (이는 결정 1의 분류 규칙 "행이 쓰인 뒤 제자리 갱신되는가? → Yes" 그대로다.)

`ON DUPLICATE KEY UPDATE`는 사용하지 않는다(시딩은 INSERT IGNORE, 진행점은 평이한 UPDATE). 따라서 Tier-1 INSERT IGNORE 회귀 가드(`Tier1InsertIgnoreGuardTest`)의 허용목록에는 `backfill_status`를 추가하지 않는다 — 해당 가드는 비-허용목록 테이블의 `ON DUPLICATE KEY UPDATE` 사용만 차단하며, `backfill_status`는 그 패턴을 쓰지 않으므로 가드 대상이 아니다.

### 적용 순서 (스키마 생성 후 root 수동 1회)

GRANT는 결정 3의 버전관리 원칙대로 코드(`config/mysql/grants/collector-tier2-grants.sql`)로 관리하며, 테이블 생성 이후 root로 적용한다.

1. **initdb.d** (`01-init-collector.sh`) — DB 단위 `SELECT, INSERT ON aaa.*` (MySQL 최초 init, 스키마 생성 전).
2. **collector Flyway** — `backfill_status` 테이블 생성(V24). aaa-collector 부팅 시 자동.
3. **`collector-tier2-grants.sql`** — 테이블 단위 `GRANT UPDATE ON aaa.backfill_status` (스키마 생성 후 root 수동 1회). MySQL 8.4는 미존재 테이블에 테이블 단위 GRANT를 거부(ERROR 1146)하므로 Flyway 이후여야 한다.

### 기동 self-check 연동 (CR-01)

aaa-collector `DbGrantVerifier.TIER2_TABLES`에 `backfill_status`를 추가했다(별도 레포 커밋). 이 root 수동 GRANT가 누락된 채 부팅하면 기동 self-check가 fail-fast(부팅 실패)한다 — 정상 부팅 후 진행점 UPDATE만 SQL 1142로 침묵 실패하는 무한루프를 기동 시점에 차단한다(REQ-BACKFILL-035a).
