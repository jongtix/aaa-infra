# ADR-034: 백필 종료 판정 원칙 — 검증된 소진(Verified Exhaustion) 3분류

## Status

Accepted (2026-07-10)

## Context

백필(과거 데이터 수집)의 "이 status는 완료됐는가?" 판정은 세 번의 프로덕션 사고를 겪었고, 셋 다 **"원본 응답 행수가 소진의 증거"라는 잘못된 전제**에서 발생했다.

- **BACKFILL-006**: 액면분할 거래정지로 `volume=0` 행이 검증 거부되자 저장 행수가 100 미만이 되어 조기 완료. → 종료 입력을 저장 행수에서 원본 행수(`rawRowCount`)로 전환해 봉합.
- **BACKFILL-010**: 2026-06-28 재구축 사고에서 오염된 완료가 스스로를 신뢰 기준선으로 축복하는 순환 신뢰. → `verified_at` 검증 마커 + 종료 확인 프로브(daily_ohlcv) 도입.
- **aaa-infra#82**: `corporate_events`(해외 SPLIT)에서 KIS `PDNO` 접두어 매칭으로 무관 종목 노이즈가 섞여(`V`=108건 중 정확일치 1건, `U`=102건 중 0건) `rawRowCount≥100`이 되자 영구 미완료/무한 재시도. `rawRowCount`(BACKFILL-006이 도입한 그 값)조차 "단일콜 소스"에는 소진 신호가 아니었다.

세 사고의 공통 교훈: **행수는 소진의 힌트일 뿐 단독 결정자가 아니다.** 종료는 데이터소스의 조회 구조에 맞는 "검증된 소진"으로만 판정해야 한다.

## Decision

### 원칙: 종료 = 검증된 소진(Verified Exhaustion)

백필 종료는 항상 데이터소스별 **소진 증거**로 판정한다. 원본 행수는 힌트이며, 그 자체로 종료를 결정하지 않는다. 소진이 구조적으로 검증된 완료에만 `verified_at`을 스탬프한다("검증 없는 완료엔 verified_at 금지", BACKFILL-010).

### 3분류와 소진 증거표

| 그룹 | 성격 | 소진 증거 | 대상 data_table | 종료 규칙 |
|------|------|-----------|-----------------|-----------|
| **GROUP_A** | 윈도우 워크형 | 고정 플로어 도달 또는 확인 프로브로 검증된 최과거 | `daily_ohlcv`, `corporate_events_dividend` | anchor를 최소 거래일 −1로 전진하며 반복. 원본 `<100` + (신뢰 플로어 도달 또는 프로브 확인) → COMPLETED+verified_at |
| **GROUP_B** | 무순서 반복형 | 연속 N회 무전진 수렴 | `short_sale_domestic`, `investor_trend`, `credit_balance` | 0건 즉시 또는 연속 N회(기본 3) 무전진 → COMPLETED. 전진 시 카운터 리셋 |
| **GROUP_C** | 커서완주·단일콜형 | fetch 성공 자체가 전 범위 커버 증명 | `corporate_events`(해외 SPLIT + 국내 액면교체) | 무조건 COMPLETED+verified_at. 행수 미참조 |

**GROUP_C의 소진 증거 상세**:
- 해외 SPLIT(`CTRGT011R`): `OverseasSplitPrefetcher`가 `tr_cont`/`ctx_area_nk50`/`ctx_area_fk50` 커서를 끝까지 순회(SUCCESS)해야만 fetch가 정상 반환된다. 미완주(TRUNCATED/FAILED)면 예외 전파 → 재시도. 2026-07-10 실측: 전체조회 강제 시 12페이지 1,102건 완주(마지막 페이지 100 미만+커서 공백 자연종료). → fetch SUCCESS = 커버 증명.
- 국내 액면교체(`HHKDB669105C0`): 연속조회가 구조적으로 불가능(CTS 커서 미반환·재호출 무진행, 2026-06-17 실측). 단일콜이 곧 전체. 종목당 이벤트 극소수(삼성전자 26년 1건)라 100행 캡 사실상 도달 불가 — 캡 포화 시 terminal FAILED 안전밸브(신규 전용 카운터 `aaa_collector_backfill_cap_saturated_total`로 관측).

### 왜 SPLIT은 GROUP_C인데 배당은 GROUP_A인가 (같은 corporate_events 계열)

핵심 축은 **"단일(또는 커서완주) fetch가 전 범위 커버를 보장하는가?"**이다.

- SPLIT: 종목당 이벤트 극소(면액변경/분할은 생애 수 건). 해외는 커서가 노이즈 포함 전 범위를 완주, 국내는 단일콜이 전부. → 뒤로 걷는 anchor 워크 불필요 → **GROUP_C**.
- 배당: 종목지정이지만 월배당 ETF가 수십 년이면 100행 초과 가능 → 단일 `[플로어, anchor]` 콜이 전 범위를 못 담을 수 있음(100 캡) → 뒤로 걷는 anchor 워크 필요 → **GROUP_A**. 절대 플로어(1950)에 대한 원본 `<100`이 소진 자기증명 — daily_ohlcv처럼 확인 프로브를 신설하지 않는다(플로어가 불확실한 daily_ohlcv의 `listed_date`와 달리, 배당의 플로어는 절대·고정값이라 별도 검증이 불필요하다).

### 신규 data_table 백필 편입 분류 체크리스트

1. 해당 KIS API가 `tr_cont`/커서 연속조회를 지원하는가? **실측으로 커서가 실제 진행하는지 확인**(지원 표기만 믿지 말 것 — `HHKDB669105C0`은 헤더는 있으나 커서 미진행).
   - 지원 + 실제 진행 → 커서 완주가 전 범위 커버를 증명 → **GROUP_C 후보**.
2. 커서 미지원이면, **단일 fetch가 전 범위를 담는가?**
   - 담음(종목당 데이터 극소, 100 캡 미도달 상시) → 단일콜 완주 → **GROUP_C**(캡 포화 terminal 안전밸브 필수).
   - 못 담음(100 캡으로 절단, 더 과거 데이터 존재) → 뒤로 걷는 윈도우 워크 필요 → **GROUP_A**. 종료는 고정(가능하면 절대) 플로어 도달 또는 확인 프로브로 검증.
3. 조회에 단조 진행(최과거로의 전진) 개념이 없고 같은 범위를 반복 조회하는가? → **GROUP_B**(연속 무전진 수렴으로 종료).

## Consequences

- **긍정**: #82류(접두어 노이즈로 인한 행수 오판) 재발 불가 — GROUP_C는 행수를 보지 않는다. 신규 소스 편입 시 분류 오류 예방(체크리스트). `verified_at`이 세 그룹 모두에서 "검증된 소진"만 표시.
- **부정/비용**: 그룹이 셋으로 늘어 `BackfillTerminationPolicy.decide`·`BackfillWindowExecutor.buildOutcome`가 3-way 분기. 국내 액면교체 캡 포화 안전밸브는 실무상 도달 불가라 데드코드에 가깝지만 절단 은폐 방지를 위해 유지.
- **구현 주의(코드 경로 신설 필요)**: corporate_events(GROUP_C)·corporate_events_dividend의 `verified_at`은 현재 코드에 스탬프 경로가 없다 — `markVerified`는 daily_ohlcv 전용 `persistGatedCompletion`에서만 호출되고, corporate_events*는 `persistLegacy`로만 라우팅되기 때문이다(BACKFILL-010 "D4 제외", `BackfillWindowExecutor.java:94`). 본 3분류를 실제로 구현하려면 `persistLegacy`에 `markVerified` 호출을 신설해 이 제외를 override해야 한다. 상세는 SPEC-COLLECTOR-BACKFILL-GROUPC-001 REQ-GC-007/010/021.
- **후속**: 배당 GROUP_A의 verified_at 스탬프 방식은 확인 프로브 확장이 아니라 절대 플로어 자기증명으로 확정됐다(SPEC-COLLECTOR-BACKFILL-GROUPC-001 REQ-GC-021). 캡 포화 관측은 신규 전용 카운터로 확정됐다(REQ-GC-013).

## References

- SPEC-COLLECTOR-BACKFILL-GROUPC-001 (본 원칙의 구현 SPEC), aaa-infra#82
- SPEC-COLLECTOR-BACKFILL-006 (rawRowCount 종료 입력), -010 (verified_at + 확인 프로브)
- `api-specs/kis/28`·`11`·`21` (2026-07-10 실측 절)
