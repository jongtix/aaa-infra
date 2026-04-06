# ADR-017: 공매도 테이블 국내/미국 분리 설계

- **상태**: 승인
- **일자**: 2026-04-04
- **범위**: aaa-collector

---

## 맥락

Phase 1 DB 스키마 설계에서 공매도(`short_sale`) 테이블을 단일 테이블(A안) vs 분리 테이블(B안)로 구성할지 논의가 발생했다.

`daily_ohlcv` 테이블은 국내/해외가 동일한 OHLCV 컬럼 구조를 공유하므로 `asset_type` ENUM으로 시장을 구분하는 단일 테이블을 채택했다. 공매도에도 동일한 패턴을 적용할 수 있는지 검토가 필요했다.

공매도 데이터의 소스 구조는 다음과 같다.

- **국내 (KIS API)**: 공매도 수량, 금액, 비율 — 일별 단일 레코드
- **미국 FINRA Daily Short Sale Volume**: ShortVolume, TotalVolume — T+1 일별 제공
- **미국 FINRA Short Interest**: 공매도 잔고, 유동주식 대비 비율 — 반월(월 2회) 발표, LOCF(Last Observation Carried Forward) 방식으로 일별 확장

세 소스가 서로 다른 컬럼 구조, 수집 주기, 업데이트 패턴을 갖는다. `daily_ohlcv`와 달리 소스 간 컬럼 구조 자체가 상이하다.

---

## 결정

**B-2안 채택: `short_sale_domestic` + `short_sale_overseas` 2테이블 분리**

- `short_sale_domestic`: KIS API 국내 공매도 데이터 전용
- `short_sale_overseas`: FINRA Daily + FINRA Short Interest 두 소스를 단일 레코드로 병합

인덱스는 두 테이블 모두 `(stock_id, trade_date)` UNIQUE KEY로 구성하며, 국내/미국이 분리된 테이블이므로 `asset_type` 또는 `market` 구분 컬럼이 불필요하다.

`short_sale_overseas` 특수 컬럼 설계:
- `daily_collected_at`: FINRA Daily 수집 시점 — 두 소스의 수집 상태를 독립적으로 추적
- `interest_collected_at`: FINRA Short Interest 수집 시점
- `short_interest_date`: FINRA Short Interest 실제 발표일 — LOCF 기준점으로, 행의 `trade_date`와 다를 수 있음

구현 파일:
- `V6__collector_create_short_sale_domestic.sql`
- `V7__collector_create_short_sale_overseas.sql`
- `domain/stock/ShortSaleDomestic.java`
- `domain/stock/ShortSaleOverseas.java`

---

## 검토한 대안

### Option A: 단일 테이블 (`short_sale`) — 기각

| 항목 | 내용 |
|------|------|
| 장점 | 테이블 수 최소화. `daily_ohlcv`와 일관된 패턴 |
| 단점 | 소스별 컬럼 구조가 달라 50% 이상 NULL인 sparse 구조 발생. NULL 의미 모호성(미수집 NULL vs 해당 시장 없음 NULL 구분 불가). 미국 2소스 병합 시 UPDATE가 필요하여 기존 `INSERT IGNORE` 패턴이 파괴됨 |

`daily_ohlcv`는 국내/해외가 동일한 컬럼 구조를 공유하므로 단일 테이블이 자연스럽다. 공매도는 소스별 컬럼 구조 자체가 다르므로 동일 논리를 적용할 수 없다. 기각.

### Option B-1: 3테이블 분리 (`short_sale_domestic` + `short_sale_overseas_daily` + `short_sale_overseas_interest`) — 기각

| 항목 | 내용 |
|------|------|
| 장점 | 소스별 완전한 스키마 독립. 각 소스의 수집 상태를 테이블 존재 여부로 명확히 구분 |
| 단점 | ML 파이프라인마다 overseas 두 테이블을 JOIN해야 함. Repository, Service, 스케줄러 구현 비용이 2테이블 대비 2배. `daily_collected_at` + `interest_collected_at` 이중 타임스탬프로 소스별 독립 추적이 이미 가능하므로 분리의 핵심 우려가 해소됨 |

기각.

### Option B-2: 2테이블 분리 (`short_sale_domestic` + `short_sale_overseas`) — **채택**

| 항목 | 내용 |
|------|------|
| 장점 | 국내/미국 컬럼 구조 차이를 테이블 분리로 명확히 반영. `short_sale_domestic`은 `INSERT IGNORE` 패턴 유지. `short_sale_overseas`는 FINRA 두 소스를 단일 레코드로 관리하여 ML 파이프라인 JOIN 불필요. 소스별 수집 타임스탬프로 독립 추적 가능 |
| 단점 | 테이블이 2개로 늘어남 (Option A 대비). 미국 테이블은 UPSERT(`INSERT ON DUPLICATE KEY UPDATE`) 패턴이 필요하여 국내와 패턴이 다름 |

채택.

---

## 결과

- `short_sale_domestic`은 KIS API 단독 소스로 단순하며, `INSERT IGNORE` 기반의 멱등 수집 패턴을 유지한다.
- `short_sale_overseas`는 FINRA Daily와 FINRA Short Interest 두 소스를 동일 레코드에 병합하여 ML 파이프라인에서 JOIN 없이 공매도 피처(SVR, SI 계열 — TECHSPEC 7.3절 참조)를 조회할 수 있다.
- 미국 테이블은 두 소스가 독립적으로 수집되므로 UPSERT 패턴이 필요하다. UPSERT 적용 범위는 `short_sale_overseas`로 한정되며, 전체 수집 패턴에는 영향을 주지 않는다.
- 스키마 진화 시 국내/미국 컬럼 추가가 각자 테이블의 ALTER로 독립 처리된다.

**트레이드오프**: 국내는 `INSERT IGNORE`, 미국은 UPSERT로 수집 패턴이 서로 다르다. 패턴 불일치는 두 시장의 데이터 소스 구조 차이에서 비롯된 것이며, 단일 패턴 강제 적용(Option A)보다 소스 특성을 그대로 반영하는 것이 유지보수에 유리하다고 판단했다.
