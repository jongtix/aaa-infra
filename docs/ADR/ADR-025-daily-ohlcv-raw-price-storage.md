# ADR-025: 일봉 시세 원주가 저장 및 분석 시점 조정 전략

- **상태**: 승인
- **일자**: 2026-06-13

---

## 맥락

`daily_ohlcv` 수집 중 `collector` DB 사용자에게 SQL 1142 오류(`UPDATE command denied ... for table 'daily_ohlcv'`)가 발생해 수집이 중단됐다. 원인 분석 과정에서 두 가지 사실이 드러났다.

1. **권한 충돌**: 멱등 삽입 쿼리가 `INSERT ... ON DUPLICATE KEY UPDATE id = id` (no-op upsert)를 사용한다. MySQL은 중복 키 충돌이 실제 발생하면 결과가 no-op이더라도 UPDATE 경로를 밟으며 SET 대상 컬럼의 UPDATE 권한을 검사한다. `collector`는 최소 권한 원칙([ADR-001](ADR-001-single-mysql-instance.md))에 따라 `daily_ohlcv`에 UPDATE 권한이 없으므로(TECHSPEC §4), 첫 중복 충돌 시점에 1142가 발생한다. 즉 "아무것도 바꾸지 않기 위해" UPDATE 권한을 요구하는 모순이다.

2. **수정주가 가변성**: 수집 쿼리는 `FID_ORG_ADJ_PRC=0`(수정주가, adjusted price)을 사용한다(`api-specs/kis/01-국내주식기간별시세.md`). 수정주가는 액면분할·배당락·증자 등 기업 이벤트 발생 시 과거 전체가 소급 재계산되는 **가변 데이터**다. 그러나 TECHSPEC §4의 시계열 테이블 원칙("`INSERT IGNORE`로 중복 방지하며 UPDATE를 사용하지 않는다")은 데이터 **불변성**을 전제한다. 두 설계 선택이 정면충돌한다.

구체적 결함: 종목이 액면분할(예: 50:1)하면 KIS는 과거 수정주가를 소급 조정하지만, 현재 쿼리(및 단순 `INSERT IGNORE` 전환)는 기존 행을 갱신하지 않는다. 일일 수집은 최근 14일 윈도우를 재조회하나 중복 행은 no-op 처리되어, 분할 전 저장값과 분할 후 신규값 사이에 시계열 불연속(가짜 폭락)이 생긴다. ML 피처가 이를 실제 가격 변동으로 오인한다.

조정 종가 사용 여부는 TECHSPEC §9에서 "Phase 2 착수 시 결정 [TBD]"로 보류된 사항이었다([MILESTONE](../../MILESTONE.md) 참조). 본 ADR이 이를 확정한다.

---

## 결정

### 결정 1 — daily_ohlcv는 원주가(unadjusted)를 저장한다

국내 일봉 수집 파라미터를 `FID_ORG_ADJ_PRC=1`(원주가)로 변경한다. 원주가는 기업 이벤트로 소급 변경되지 않는 **불변 데이터**이므로 시계열 테이블의 불변성 원칙(TECHSPEC §4)과 일치한다. 향후 구현할 해외 일봉 수집도 동일하게 원주가 저장 원칙을 따른다.

### 결정 2 — 멱등 삽입은 INSERT IGNORE를 사용한다

`INSERT ... ON DUPLICATE KEY UPDATE id = id`를 `INSERT IGNORE`로 대체한다. 두 패턴은 "중복 시 변경 없음" 결과가 동일하나, `INSERT IGNORE`는 UPDATE 권한을 요구하지 않아 SQL 1142를 해소하고 `collector` 최소 권한을 유지한다. TECHSPEC §4의 명시 원칙과도 일치한다.

원주가 저장(결정 1)으로 행이 불변이 되므로 "갱신 불가"는 결함이 아니라 의도된 속성이 된다.

### 결정 3 — 배당·분할 조정은 분석 시점에 계산한다

배당락·액면분할 등으로 인한 가격 조정은 저장 시점이 아니라 분석 시점(analyzer, Phase 2)에 `corporate_events` 테이블의 이벤트를 기반으로 조정계수를 계산해 적용한다. 원본(원주가)은 불변으로 보존하고, 조정은 읽기 시점에 파생한다(store raw, adjust on read).

### 결정 4 — 데이터 오류 정정은 탐지 + out-of-band 경로로 분리한다

원주가가 기업 이벤트로 소급 변경되지 않는다는 것이 "원천 데이터가 항상 옳다"는 뜻은 아니다. KIS 일시적 오류(미확정 데이터, 부분 응답), 수집 시점 버그, KIS 자체 데이터 정정 등으로 잘못된 값이 `isValid()`(범위 검증)를 통과해 저장될 수 있으며, `INSERT IGNORE`는 이를 영구 고착시킨다.

이를 다음 두 계층으로 분리해 처리한다.

- **탐지 (collector, 최소 권한 유지)**: 14일 윈도우 재조회 시 이미 저장된 행에 대해 재조회값과 저장값을 비교하고, 불일치 시 경고 로그로 발산한다. collector는 행을 수정하지 않는다(`INSERT IGNORE` 유지). 원주가는 결정론적이므로 정상 재조회는 항상 일치하며, "재조회값 ≠ 저장값"은 곧 데이터 오류 신호다.
- **정정 (out-of-band, 별도 권한)**: 실제 행 수정은 collector 서비스 계정이 아니라 관리자 도구 또는 마이그레이션 등 통제·감사되는 별도 권한 경로로 수행한다.

상시 실행되는 자동화 서비스에 드물고 예외적인 정정을 위해 UPDATE 권한을 부여하지 않는다 — 권한 경계를 흐리고 1142 경로를 재허용하기 때문이다.

---

## 검토한 대안

### 대안 — 수정주가 유지 + 재적재 전략 (B안)

| 항목 | 내용 |
|------|------|
| 장점 | 분석 레이어가 조정계수를 계산할 필요 없음. 저장된 값을 그대로 사용 |
| 단점 | 기업 이벤트 감지 시 해당 종목 과거 행을 재기록(UPDATE 또는 DELETE+INSERT)해야 함 → `collector`에 `daily_ohlcv` UPDATE 권한 부여 필요 → 최소 권한 원칙([ADR-001](ADR-001-single-mysql-instance.md)) 및 시계열 불변성 원칙(TECHSPEC §4) 동시 위배. 소급 재적재 로직이 복잡하고 부분 실패 시 시계열 일관성 훼손 위험 |

기각. 권한 모델과 시계열 불변성 두 원칙을 모두 깨뜨리며, 재적재 실패 시 데이터 일관성 리스크가 크다. "store raw, adjust on read"는 퀀트 시스템의 정석이며 시스템에 이미 `corporate_events` 인프라(TECHSPEC §4)가 존재한다.

### 결정 4 대안 1 — 정정 없음 (탐지 미도입)

| 항목 | 내용 |
|------|------|
| 장점 | 가장 단순. 추가 read 비교 없음 |
| 단점 | 잘못된 값이 침묵 속에 영구 고착. 오류 발생 사실조차 드러나지 않음 |

기각. 데이터를 맹목적으로 신뢰하게 되어 오류가 침묵한다.

### 결정 4 대안 2 — 자가 치유 UPSERT (값 컬럼 UPDATE 권한 부여)

| 항목 | 내용 |
|------|------|
| 장점 | 14일 윈도우 내 오류·정정이 재조회 시 자동 치유됨 (원주가는 결정론적이라 정상 재조회는 사실상 no-op) |
| 단점 | collector에 `daily_ohlcv` UPDATE 권한 부여 → 최소 권한 원칙([ADR-001](ADR-001-single-mysql-instance.md)) 약화, 1142 경로 의도적 재허용. 윈도우 밖 구간은 여전히 미치유 |

기각. 1년에 몇 번 있을 예외적 정정을 위해 상시 자동화 서비스에 UPDATE 권한을 상시 부여하는 것은 권한 경계를 흐린다. 탐지(결정 4)로 오류를 드러내고 정정은 별도 권한 경로로 분리하는 것이 권한 경계상 더 깨끗하다.

---

## 결과

국내 일봉 수집을 원주가(`FID_ORG_ADJ_PRC=1`)로 전환하고, 멱등 삽입을 `INSERT IGNORE`로 변경한다. 배당·분할 조정은 analyzer가 `corporate_events` 기반으로 분석 시점에 계산한다. 데이터 오류는 collector가 재조회값/저장값 불일치를 탐지·로깅하고, 실제 정정은 별도 권한 경로로 수행한다. 이로써 SQL 1142가 해소되고, `collector` 최소 권한과 시계열 불변성 원칙이 모두 유지되며, TECHSPEC §9의 [TBD] 조정 종가 결정이 확정된다.

### 선행/병행 조건

- **`corporate_events` SPLIT 수집 확장**: 현재 `corporate_events`는 DIVIDEND만 수집한다(TECHSPEC §4). 분석 시점 조정(결정 3)이 작동하려면 SPLIT(액면분할) 이벤트 수집이 선행 또는 병행되어야 한다. SPLIT 미수집 상태에서는 분할 조정을 계산할 데이터가 없다.

### 한계

- **기존 데이터 재적재 필요**: 기존 `daily_ohlcv` 행은 수정주가(`FID_ORG_ADJ_PRC=0`)로 적재됐다. 원주가 전환 후 신규 행과 혼재되면 시계열이 오염되므로, 기존 데이터를 원주가로 일회성 재적재해야 한다. 재적재 완료 전까지 분할/배당 이력이 있는 종목의 과거 구간은 신뢰할 수 없다.
- **분석 레이어 책임 증가**: 조정계수 계산 부담이 analyzer로 이전된다. 조정 로직의 정확성은 `corporate_events` 데이터 완전성에 의존한다.
- **자동 정정 불가**: collector는 오류를 탐지·로깅할 뿐 수정하지 않는다. 14일 윈도우 내든 밖이든 실제 정정은 out-of-band 수동 작업이며, 정정 도구·절차는 별도 수립이 필요하다.
- **탐지 비용**: 윈도우 내 기존 행에 대해 재조회값과 저장값을 비교하려면 추가 read/비교가 발생한다. 종목당 14일 규모로 비용은 미미하나 0은 아니다.

### 후속 작업

- `DomesticDailyOhlcvCollectionService`: `FID_ORG_ADJ_PRC` `0` → `1` 변경
- `DailyOhlcvRepository`: `ON DUPLICATE KEY UPDATE id = id` → `INSERT IGNORE` 변경 + Javadoc 정정(MySQL 권한 검사 동작 반영)
- MySQL Testcontainer 통합 테스트: 정상 INSERT / 중복 시 멱등(UPDATE 권한 없이) / 동작 검증
- 재조회값 ≠ 저장값 불일치 탐지·경고 로깅 구현 (collector, 수정 없음)
- out-of-band 데이터 정정 도구·절차 수립
- TECHSPEC §9 [TBD] 항목 갱신 및 본 ADR 링크 추가
- 기존 `daily_ohlcv` 원주가 재적재 절차 수립
- `corporate_events` SPLIT 수집 확장 (Phase 2 분석 선행 조건)

---

## 개정 — 2026-07-04: 조정 범위 확정 (분할+배당, Total Return 방향) + as-of 원칙 명시

결정 3("배당·분할 조정은 분석 시점에 계산한다")은 조정 **범위**를 명시하지 않았다. analyzer Phase 2 설계 논의([D-5], 2026-07-03~04)에서 이를 확정한다.

### 조정 범위 — 분할 + 배당 (Total Return 방향)

- **분할(SPLIT)**: `corporate_events.stock_rate` 배율로 조정한다(예: 5.0=5:1 분할, 0.4=병합). 병합(rate<1)도 양방향 처리한다. 일반 ML/퀀트 관행상 미조정 시 -50~-80% 인위 갭이 발생하므로(2026-07-03 실측: AAPL 2020-08-31 4:1 분할 갭 499→129, 삼성전자 2018-05-04 50:1 분할 갭 2,650,000→51,900) 분할 조정은 논쟁 없이 필수다.
- **배당(DIVIDEND)**: `ex_dividend_date`/`cash_amount` 기반 디플레이터로 조정한다(Total Return 방향 — 배당 재투자를 가정한 수익률). 일반 관행은 Raw/Split-adjusted(배당 미조정)/Total Return 3모드로 갈리는데, 본 프로젝트는 Total Return을 채택한다.
- **데이터 전제(Phase 2 학습 착수 블로커)**: 배당·분할 조정이 실제로 동작하려면 이벤트 데이터가 필요하다. 2026-07-03 실측 시점 기준 국내 배당 이력 부재(과거분 미백필, [aaa-infra#44](https://github.com/jongtix/aaa-infra/issues/44)), 국내 배당락일 전행 NULL([#71](https://github.com/jongtix/aaa-infra/issues/71)), 해외 분할 이벤트 미수집([#70](https://github.com/jongtix/aaa-infra/issues/70))이 확인되어 각각 이슈로 등록했다. 이 세 이슈(+#62 배포 후 해외 배당 유입 확인)의 해소가 analyzer 학습 착수의 전제조건이다.

### as-of(point-in-time) 조정 원칙

결정 3의 "store raw, adjust on read" 설계는 조정가를 저장하지 않고 읽기 시점에 계산하므로, **조정 시점까지 발생한 이벤트만 반영**하는 as-of(point-in-time) 방식이 된다. 이는 일반 퀀트 관행에서 알려진 "backward-adjusted 가격의 look-ahead 편향" 함정(예: Yahoo Finance의 adjusted close처럼 최근일을 anchor로 과거 전체를 역산하면, 과거 특정 시점의 조정가가 그 이후 발생한 미래 이벤트에 의존하게 되는 문제)을 구조적으로 회피한다. 결정 1(원주가 불변 저장)과 결정 3(분석 시점 계산)의 조합이 본질적으로 as-of 조정이었음을, 조정 범위 확정과 함께 여기서 명시적으로 기록한다.

조사 출처: [Adjusted Prices Without Look-Ahead Bias — Portfolio Optimizer](https://portfoliooptimizer.io/blog/adjusted-prices-without-look-ahead-bias/), [Dividends, Splits and Custom Price Normalization — QuantConnect 포럼](https://www.quantconnect.com/forum/discussion/508/update-dividends-splits-and-custom-price-normalization/p1).

상세 논의는 analyzer Phase 2 설계 문서(`docs/analyzer-phase2-design-draft.md` [D-5])를 참조한다.
