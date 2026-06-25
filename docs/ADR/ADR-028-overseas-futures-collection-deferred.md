# ADR-028: 해외선물(ES/NQ/CL/VX) 수집 보류 — API 유료시세 비용 대비 효용 부족

- **상태**: 승인
- **일자**: 2026-06-24

---

## 맥락

[TECHSPEC §3.3](../TECHSPEC.md#33-kis-api-해외-수집-상세)과 `futures_daily` 테이블 설계(§4)는 해외선물 4종(ES, NQ, CL/WTI, VX(VIX 선물))을 KIS REST(`daily-ccnl`, TR `HHDFC55020100`)로 수집하는 것을 Phase 1 범위로 정의했다. `aaa/TODO.md` 보류 항목의 "해외선물 수집" 중 하나다.

SPEC 작성에 앞서 KIS API 명세와 비용 구조를 실측·확인한 결과, 해외선물 데이터는 **API 유료시세 신청이 전제**되어야 수집 가능함이 확인되었다.

### 확인된 사실 (KIS 공식)

1. **실측(2026-06-15, `api-specs/kis/15-해외선물체결추이일간.md`)**: isa 계좌로 `daily-ccnl`(일봉) 호출 시 `EGW00550 "CME SUB거래소 신청 계좌가 아닙니다."` 오류. 일봉(과거) 데이터도 유료시세 신청 없이는 수신 불가.

2. **KIS 공식 안내**("해외선물옵션 API 유료시세 신청방법(CME, SGX 거래소)", KIS Developers 커뮤니티):
   - **CME·SGX 거래소 시세는 API로 받을 때 유료**. HTS/MTS 조회는 무료이나 **API 수신만 별도 과금**.
   - **"CME·SGX 외 거래소는 신청 불필요, API 무료 수신 가능"**(FAQ Q4).
   - 신청은 **HTS eFriend Plus `[7936]`** → `API(유료)` 탭에서만 가능(MTS 불가). 신청 후 접근토큰발급 API 호출로 동기화, 최대 2시간 후 수신.
   - REST는 `EGW00550`, WebSocket은 데이터 미수신.

3. **비용**(KIS 공지 TF04ga000002): 거래소별 월 221.10 USD(2025-01-01, 부가세 포함), 2026-01-01 추가 인상. CME/CBOT/NYMEX/COMEX 각각 과금.

### 대상별 거래소 귀속

| 선물 | 거래소 | API 유료 여부 |
|------|--------|---------------|
| ES (S&P500) | CME | 유료 |
| NQ (나스닥100) | CME | 유료 |
| CL/WTI (원유) | NYMEX (CME Group) | 유료 |
| VX (VIX 선물) | CFE/CBOE (CME·SGX 외) | 무료 가능성(미실측) |

ES/NQ/CL 수집 시 최소 CME + NYMEX 2개 거래소 구독 = 월 약 442 USD(부가세·2026 인상 별도).

---

## 결정

**해외선물 4종 수집을 Phase 1에서 보류한다.** `futures_daily` 테이블 스키마([V13](../../../aaa-collector/src/main/resources/db/migration))는 유지하되, 수집 코드는 구현하지 않는다.

근거:

1. **유료**: ES/NQ/CL은 API 유료시세 확정. 1인 개인 프로젝트에서 ML 보조지표 하나에 월 수십만 원은 비용 대비 효용 부족.
2. **무료 대체 존재**: 해외선물의 본래 목적(미국 증시 방향성·변동성 심리)은 이미 무료로 수집 중인 데이터로 대부분 대체된다.
   - ES/NQ → SPX/NDX 지수 일봉(`daily_ohlcv` `asset_type=INDEX`)
   - VX → VIX 지수 일봉(CBOE/FRED/Yahoo Fallback, [SPEC-COLLECTOR-MARKETIND-001](../../../.moai/specs/SPEC-COLLECTOR-MARKETIND-001))
   - CL → FRED 거시지표([SPEC-COLLECTOR-MACRO-EXT-001](../../../.moai/specs/SPEC-COLLECTOR-MACRO-EXT-001))
3. **VIX 선물 중복**: VX는 무료 가능성이 있으나, 이미 VIX *지수*를 수집 중이라 선물의 추가 가치는 만기 구조(콘탱고/백워데이션)뿐이며 ML 초기 모델에 필수가 아니다.

---

## 검토한 대안

### 대안 1: ES/NQ/CL까지 API 유료시세 신청 — 기각

| 항목 | 내용 |
|------|------|
| 장점 | 선물 만기 구조·미결제약정 등 지수에 없는 피처 확보 |
| 단점 | 월 약 442 USD(CME+NYMEX) 상시 비용. HTS 설치·공동인증서 신청 필요. ML 초기 모델에 필수 아님 |

기각. 무료 지수로 대체 가능한 효용에 비해 상시 비용·운영 부담이 과도하다.

### 대안 2: VIX 선물(VX)만 무료 수집 — 보류

| 항목 | 내용 |
|------|------|
| 장점 | CFE 무료 가능성. 만기 구조 피처 확보 가능 |
| 단점 | VIX 지수와 중복. 무료 여부 미실측(isa 계좌 실호출 필요). 단일 선물 위해 롤오버 스티칭 로직 도입은 과설계 |

보류. VIX 지수로 충분하며, 선물 만기 구조가 필요해지는 시점에 재검토.

### 대안 3: 해외선물 전체 보류 (채택)

| 항목 | 내용 |
|------|------|
| 장점 | 비용 0. 무료 지수로 본래 목적 대체. 롤오버 스티칭 등 복잡도 회피 |
| 단점 | 선물 고유 피처(만기 구조, 미결제약정) 미확보 |

채택.

---

## 결과

- 해외선물 수집 코드는 구현하지 않는다. `futures_daily` 스키마는 향후 재개를 위해 유지한다.
- `aaa/TODO.md` 보류 항목에 해외선물 수집을 ADR-028 참조로 기재한다.
- "해외 배치 잔여 3종" 중 배당/권리·뉴스 2종(무료)만 SPEC 작성·구현을 진행한다.
- 미국 증시 방향성·변동성·원자재 신호는 SPX/NDX 지수, VIX 지수, FRED 거시지표로 대체한다.

**재검토 트리거**: 다음 중 먼저 오는 시점에 이 결정을 재검토한다.

1. analyzer(Phase 2) 모델이 선물 만기 구조(콘탱고/백워데이션)·미결제약정을 필요로 함이 실증되는 시점
2. VIX 선물(CFE) 무료 수신이 실측으로 확인되고, VIX 지수 대비 추가 예측력이 입증되는 시점
3. 프로젝트가 파생상품을 직접 거래 대상으로 확장하는 시점([PRD](../PRD.md) 스코프 변경)

---

## 참조

- [TECHSPEC §3.3](../TECHSPEC.md#33-kis-api-해외-수집-상세) — 해외 수집 상세(해외선물 ES/NQ/CL/VX)
- [TECHSPEC §4 `futures_daily`](../TECHSPEC.md) — 선물 테이블 설계(스키마 유지)
- `api-specs/kis/15-해외선물체결추이일간.md` — `daily-ccnl` 실측(EGW00550)
- KIS 공지 TF04ga000002 — CME API 시세비용(2025 월 221.10 USD, 2026 인상)
- [SPEC-COLLECTOR-MARKETIND-001](../../../.moai/specs/SPEC-COLLECTOR-MARKETIND-001) — VIX 지수 무료 수집
- [SPEC-COLLECTOR-MACRO-EXT-001](../../../.moai/specs/SPEC-COLLECTOR-MACRO-EXT-001) — FRED 거시지표
