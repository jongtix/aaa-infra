# ADR-023: KIS API Rate Limiting 구현 방법 선택

- **상태**: 승인
- **일자**: 2026-04-16

---

## 맥락

`aaa-collector`의 `WatchlistSyncService.fetchStockInfos`는 `Executors.newVirtualThreadPerTaskExecutor()`로 Virtual Thread를 생성하여 `KisStockInfoClient.fetchStockInfo`를 병렬 호출한다. KIS Open API는 TPS 20 제한을 명시하고 있어, 병렬 호출이 이 제한을 초과하지 않도록 rate limiting을 적용해야 한다.

`KisStockInfoClient.fetchStockInfo`에는 `@Retryable`이 적용되어 있어, rate limiter와의 AOP 병용 시 실행 순서 설정이 필요하다.

---

## 결정

**Bucket4j 프로그래매틱 방식**을 채택한다.

`LocalBucket`을 직접 호출 지점에서 `tryConsume()` 또는 `asBlocking().consume()`으로 사용하며, AOP를 경유하지 않는다.

---

## 검토한 대안

### 대안 1 — `java.util.concurrent.Semaphore`

| 항목 | 내용 |
|------|------|
| 제어 방식 | 동시 연결 수 상한 |
| KIS TPS 20 매핑 | 불일치 — 동시 연결 수를 제한할 뿐 시간 축 제어 불가 |
| 추가 의존성 | 없음 |

기각. KIS TPS 20은 시간 기반 제약이므로 Semaphore로는 정확히 표현할 수 없다.

### 대안 2 — Resilience4j RateLimiter

| 항목 | 내용 |
|------|------|
| 제어 방식 | 시간 기반 (초당 N회) |
| KIS TPS 20 매핑 | 일치 |
| VT pinning | `AtomicRateLimiter` 사용 시 없음 |
| AOP 순서 리스크 | `@Retryable`과 병용 시 aspect-order 설정 오류 유발 가능 — Resilience4j는 숫자가 클수록 먼저 실행되어 Spring `@Order` 관례와 반대 |
| 테스트 가능성 | `System.nanoTime()` 하드코딩 — 시간 기반 단위 테스트 어려움 |
| 실패 모드 | `RequestNotPermitted` 예외 — 호출 스택 외부에서 처리 |
| 분산 확장 | 불가 |
| 추가 의존성 | 무거움 (Resilience4j 전체 모듈) |

기각. `@Retryable`과의 AOP aspect-order 설정 오류 리스크가 있으며, 시간 기반 단위 테스트가 어렵다.

### 대안 3 — Bucket4j (채택)

| 항목 | 내용 |
|------|------|
| 제어 방식 | 토큰 버킷 (시간 기반) |
| KIS TPS 20 매핑 | 일치 |
| VT pinning | 없음 (CAS lock-free) |
| AOP 순서 리스크 | 프로그래매틱 방식으로 원천 회피 — 호출 지점에서 순서가 명시적으로 강제됨 |
| 테스트 가능성 | `TimeMeter` 주입으로 가상 시간 단위 테스트 가능 |
| 실패 모드 | `tryConsume()` boolean 반환 — 호출 지점에서 명시적 처리 |
| 분산 확장 | `LocalBucket` → `ProxyManager` 교체만으로 Redis 분산 rate limiting 전환 가능 (기존 Redis 8.6 재사용) |
| 추가 의존성 | 가벼움 (`bucket4j-core`) |

채택.

---

## 결과

`KisStockInfoClient`의 병렬 호출 지점에서 `LocalBucket`으로 TPS 20 제한을 적용한다. `@Retryable`과의 AOP 충돌 없이 명시적 순서가 보장되며, `TimeMeter` 주입으로 단위 테스트에서 시간 제어가 가능하다.

**향후 전환 경로**: 멀티 인스턴스 배포 시 `LocalBucket`을 `ProxyManager` 기반 Redis Bucket으로 교체하면 기존 Redis 8.6 인프라를 재사용하여 분산 rate limiting을 적용할 수 있다.

**미해결 사항**: KIS WebSocket API의 rate limit 제약 조건은 미확인 상태다. WebSocket 구현 단계에서 별도 확인이 필요하다.
