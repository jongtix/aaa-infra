# ADR-019: 시계열 테이블 trade_date 단독 인덱스 선택적 추가 전략

- **상태**: 승인
- **일자**: 2026-04-07
- **범위**: aaa-collector

---

## 맥락

Phase 1 시계열 테이블 10개는 모두 `(stock_id, trade_date)` 또는 `(indicator_code, trade_date)` 유니크 키를 가진다. 유니크 키의 선행 컬럼이 `stock_id` 또는 `indicator_code`이므로, 날짜 단독 조건(`WHERE trade_date = ?` 또는 `WHERE trade_date BETWEEN ? AND ?`)으로 조회하는 경우 해당 유니크 키가 커버하지 못해 풀 스캔이 발생한다.

코드 리뷰 중 일부 테이블(예: `macro_indicators`)에는 `trade_date` 단독 인덱스가 존재하고 일부는 없어 일관성 문제가 제기되었다. "모든 시계열 테이블에 동일하게 `trade_date` 인덱스를 추가하여 일관성을 확보해야 하는가"라는 질문이 출발점이다.

---

## 결정

**일관성보다 필요성 우선: 데이터 볼륨 예측 및 쿼리 패턴 분석 기반으로 선택적 추가한다.**

인덱스는 쓰기 오버헤드(INSERT/UPDATE 시 인덱스 갱신)와 메모리 비용(InnoDB 버퍼풀 인덱스 페이지 점유)이 있다. 실제 풀 스캔 비용이 미미한 소규모 테이블에 인덱스를 추가하는 것은 불필요한 비용이다. 또한 소규모 테이블에서는 InnoDB 옵티마이저가 인덱스를 무시하고 풀 스캔을 선택할 가능성도 있어, 인덱스 자체가 사용되지 않는 상황이 발생한다.

인덱스 추가 여부는 두 가지 기준을 동시에 충족해야 한다.

1. **날짜 단독 쿼리 패턴 존재**: 특정 날짜 기준 cross-section 조회, 날짜 범위 운영 모니터링 등 날짜 단독 조건이 실제로 필요한가
2. **데이터 볼륨이 버퍼풀 상주 임계치 초과**: NAS 환경(Intel N100, 8GB RAM) 기준으로 테이블 전체가 버퍼풀에 상시 상주할 수 없는 규모인가

---

## 검토한 대안

### Option A: 모든 시계열 테이블에 일관적으로 trade_date 인덱스 추가

| 항목 | 내용 |
|------|------|
| 장점 | 테이블마다 인덱스 전략을 따로 판단할 필요 없음. 스키마 규칙이 단순 |
| 단점 | 소규모 테이블(관심 종목 ~160건/일)에는 불필요한 쓰기 오버헤드와 메모리 비용 발생. InnoDB 옵티마이저가 소규모 테이블에서 인덱스를 무시할 가능성 |

기각.

### Option B: 필요 없는 테이블에는 추가하지 않고, 실측 후 재평가 — **채택**

| 항목 | 내용 |
|------|------|
| 장점 | 실제 필요한 곳에만 비용 지출. 볼륨 불확실 테이블은 실측 데이터로 판단 가능 |
| 단점 | 테이블마다 인덱스 전략이 달라 일관성 하락. 향후 테이블 추가 시 매번 판단 필요 |

채택.

---

## 테이블별 적용 결과

### 인덱스 추가 완료

| 테이블 | 인덱스 | 근거 |
|--------|--------|------|
| `daily_ohlcv` | `idx_daily_ohlcv_trade_date (trade_date)` | 본 ADR 작성의 출발점이 된 테이블. 특정 날짜의 전체 수집 종목 OHLCV 일괄 조회 패턴이 실제 수집 로직에 존재하여 인덱스 생성 당시 필요에 의해 추가됨 |
| `market_indicators` | `idx_market_indicators_trade_date (trade_date)` | 종목 FK 없는 독립 엔티티. 특정 날짜의 전체 시장 지표 조회는 날짜 단독 조건이 설계에 내재됨 |
| `short_sale_domestic` | `idx_short_sale_domestic_trade_date (trade_date)` | 국내 전체 종목 수집 시 예상 규모 ~2,700종목 × 250일 × 5년 ≈ 3.5M 행. NAS 8GB RAM 환경에서 버퍼풀 상시 상주 불가 |
| `short_sale_overseas` | `idx_short_sale_overseas_trade_date (trade_date)` | FINRA는 미국 전체 상장 종목 데이터 제공. `short_sale_domestic`과 동등 이상의 규모 예상 |
| `macro_indicators` | `idx_macro_indicators_trade_date (trade_date)` | ADR-019 이전부터 존재. 종목 FK 없는 독립 엔티티로 날짜 단독 cross-section 조회가 설계에 내재됨 |

### 인덱스 보류 (실측 후 재평가)

| 테이블 | 현재 판단 | 보류 이유 |
|--------|-----------|-----------|
| `investor_trend` | 관심 종목 한정 시 ~160건/일 소규모 | 실제 수집 종목 범위(관심 종목 수) 미확정 |
| `credit_balance` | 관심 종목 한정 시 ~160건/일 소규모 | 실제 수집 종목 범위(관심 종목 수) 미확정 |
| `analyst_estimates` | 이벤트성 데이터로 볼륨 소규모 예상 | 실제 수집 패턴 확인 필요 |
| `corporate_events` | 이벤트성 데이터로 볼륨 소규모 예상 | 실제 수집 패턴 확인 필요 |
| `futures_daily` | 수집 대상 선물 종목 소수(4개) | 볼륨 소규모 확실, 날짜 단독 쿼리 패턴도 미확인 |

---

## 결과

- `daily_ohlcv`, `market_indicators`, `short_sale_domestic`, `short_sale_overseas`의 Flyway DDL에 `trade_date` 단독 인덱스가 추가되었다. `macro_indicators`는 ADR-019 이전부터 인덱스가 존재하였다.
- 보류 테이블은 실제 데이터 수집 시작 후 날짜 범위 쿼리 실행 계획(`EXPLAIN`)으로 풀 스캔 비용을 측정하여 인덱스 추가 여부를 재평가한다.
- 재평가 기준: `EXPLAIN` 결과 `type = ALL`이고 `rows` 추정치가 수만 건 이상이면 추가 검토.

**트레이드오프**: 테이블마다 인덱스 전략이 달라 스키마 읽는 데 추가 사고가 필요하다. 이는 불필요한 쓰기 오버헤드/메모리 비용 제거를 위해 감수하는 복잡도이며, DDL 주석 또는 TECHSPEC 문서로 판단 근거를 추적 가능하게 유지한다.
