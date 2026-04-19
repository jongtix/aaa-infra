# ADR-022: 관심목록 동기화 stocks 마스터 갱신 전략

- **상태**: 승인
- **일자**: 2026-04-16

---

## 맥락

관심목록 동기화 시 `stocks` 테이블에 대한 INSERT/UPDATE 전략을 결정해야 했다. 기존 종목에 대해 어떤 필드를 갱신할지, 관심목록에서 제거된 종목을 어떻게 처리할지, 종목 정보 조회 실패 시 어떻게 처리할지 등 복수의 결정이 필요했다.

---

## 결정

### 결정 1 — 기존 종목 UPDATE 갱신 대상 필드

기존 종목 UPDATE 시 `nameKo`, `nameEn`만 갱신한다. `assetType`, `listedDate`는 갱신하지 않는다.

`assetType`과 `listedDate`는 최초 INSERT 시 KIS 기본정보 API로 정확히 채워지므로 이후 덮어쓰기가 불필요하다. `nameEn`은 기업 사명 변경 등으로 변경될 수 있으므로 갱신 대상에 포함한다.

### 결정 2 — active 복구 조건

관심목록 API 응답에 나타난 종목은 `active=true`로 복구한다.

관심목록 API 응답에 나타난 종목은 현재 수집 대상이므로 `active=true`여야 한다.

### 결정 3 — 실패 시 직전 상태 유지 (best-effort)

동기화 실패한 종목은 DB를 건드리지 않는다.

잘못된 데이터 저장보다 누락이 안전하다. 다음 동기화 주기에 재시도한다.

### 결정 4 — StockInfo 조회 실패 시 기본값 INSERT

StockInfo(`assetType`, `nameEn`, `listedDate`) 조회 실패 시 `assetType=STOCK` 기본값으로 INSERT한다.

종목 자체의 수집 누락보다 `assetType` 미확정 상태로 보존하는 것이 가치 있다. `assetType`은 향후 별도 업데이트로 정정 가능하다.

### 결정 5 — 관심목록 제거된 종목 처리: watchlist_removed_at 컬럼 추가

관심목록 API 응답에 나타나지 않은 기존 종목은 `watchlist_removed_at`을 현재 시각으로 설정한다. 재추가 시 `watchlist_removed_at=NULL`로 리셋한다.

---

## 검토한 대안 (결정 4, 5)

### 결정 4 대안 — skip (assetType 미확정 시 INSERT 안 함)

| 항목 | 내용 |
|------|------|
| 장점 | assetType 미확정 종목이 DB에 저장되지 않음 |
| 단점 | 종목 자체가 수집 대상에서 누락됨 |

기각. StockInfo 조회 실패는 일시적 오류일 수 있으며, 종목 누락보다 `assetType` 미확정 상태 보존이 낫다.

### 결정 5 대안 1 — active=false 활용

| 항목 | 내용 |
|------|------|
| 장점 | 추가 컬럼 없이 기존 필드 재사용 |
| 단점 | `active`는 상장폐지·거래정지 용도로 설계됨 — 관심목록 이탈과 혼용 시 의미 오염 |

기각. 필드의 의미가 오염된다.

### 결정 5 대안 2 — 물리 삭제

| 항목 | 내용 |
|------|------|
| 장점 | 단순함 |
| 단점 | 제거 시각 정보 소실. 이력 조회 불가 |

기각. Phase 2 시계열 분석에서 gap 판단에 제거 시각 정보가 필요하다.

### 결정 5 대안 3 — watchlist_removed_at DATETIME NULL 컬럼 추가 (채택)

| 항목 | 내용 |
|------|------|
| 장점 | `active`의 의미 오염 없음. 제거 시각 정보가 Phase 2 시계열 분석에서 gap 판단에 유용 |
| 단점 | 재추가 시 `watchlist_removed_at=NULL`로 리셋 — 이전 제거 이력 보존 안 됨 |

채택. 이전 제거 이력 미보존은 현재 단계에서 허용한다.

---

## 결과

`stocks` 테이블 갱신 시 `nameKo`, `nameEn`만 업데이트하고 `assetType`, `listedDate`는 유지한다. StockInfo 조회 실패 시 `assetType=STOCK` 기본값으로 INSERT하며, 동기화 실패 종목은 DB를 건드리지 않는다. 관심목록에서 제거된 종목은 `watchlist_removed_at` 컬럼으로 추적한다.

**한계**: 재추가 시 `watchlist_removed_at=NULL`로 리셋되어 이전 제거 이력이 보존되지 않는다. 현재 단계에서는 허용한다.
