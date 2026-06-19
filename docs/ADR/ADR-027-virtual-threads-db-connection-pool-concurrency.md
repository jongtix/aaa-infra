# ADR-027: Virtual Threads + 단일 MySQL 환경의 DB 커넥션 풀 동시성 정책

- **상태**: 승인·확정 (SPEC-COLLECTOR-DBPOOL-001 구현·머지 완료 — collector `1e9cf0b`/`a66a9fb`, 2026-06-19)
- **일자**: 2026-06-19
- **범위**: aaa-collector (및 향후 단일 MySQL을 공유하는 Virtual Threads 활성 서비스 전체)
- **관련**: ADR-001(단일 MySQL 인스턴스), ADR-008(Virtual Threads @Scheduled), ADR-024(KIS REST per-key 멀티키 분산), SPEC-COLLECTOR-DBPOOL-001

---

## 맥락

세 개의 기존 결정이 교차하면서, 어느 ADR에도 없던 새로운 제약이 드러났다.

- **ADR-008**: collector는 `spring.threads.virtual.enabled: true`로 Virtual Threads(VT)를 전역 활성화한다. 배치 수집 서비스는 종목 단위 작업을 `Executors.newVirtualThreadPerTaskExecutor()`로 수백 개 동시에 제출한다.
- **ADR-024**: 고용량 배치 REST는 앱키별(per-key) rate limiter로 5개 앱키에 분산한다. KIS in-flight 동시성 한도(`kis.rate-limit.max-concurrency`)가 **키마다 독립**이므로, 키당 10 × ~5키 = 최대 ~50 동시 in-flight가 가능하다.
- **ADR-001**: 모든 서비스는 단일 MySQL 인스턴스를 공유한다. collector의 DB 쓰기는 **전역 단일 HikariPool**로 수렴한다(`maximum-pool-size: 5`).

즉 **상류(KIS) 동시성 예산은 키 수만큼 증폭되는데, 하류(DB) 동시성은 단일 풀로 수렴**한다. 두 예산이 정합되지 않는다.

### 발현된 장애 (2026-06-18 16:00 KST, 프로덕션 NAS)

미장 배치 시각(16:00)에 ohlcv·short-sale·investor-trend·credit-balance 배치가 동시에 가동하면서:

```
HikariPool-1 - Connection is not available, request timed out after 5079ms
(total=5, active=5, idle=0, waiting=106)
```

- ERROR 80건이 16:00 단 1분에 집중. 대기 큐 106.
- short-sale 배치 `attempted=206, succeeded=193` — 풀 고갈 타임아웃으로 일부 종목 DB 저장 실패(데이터 유실).

근본 원인은 두 가지다.

1. **상류 동시성 예산 ≫ 하류 DB 풀**: KIS를 통과한 수십 개 VT가 5개 슬롯에 몰린다. KIS rate limiter는 KIS HTTP 호출만 보호하며 DB 저장 경로에는 동시성 게이트가 없다.
2. **`connection-timeout: 5000`(5초)이 정상 큐잉을 실패로 전환**: VT가 풀 슬롯을 기다리면 결국 처리될 것을, 5초 컷오프가 타임아웃→ERROR→작업 skip(데이터 유실)으로 만든다.

---

## 결정

VT + 단일 MySQL 환경에서 DB 동시성을 제어하는 정책을 다음과 같이 확정한다.

1. **추가 Semaphore/throttle를 두지 않는다 — HikariPool 자체가 세마포어다.**
   Virtual Threads는 희소 자원이 아니므로 풀링하지 않으며(Inside.java SIP094: *"Don't pool virtual threads"*), 이미 커넥션 풀이 있는 경로에 별도 Semaphore를 얹지 않는다(SIP094: *"If you already use a connection pool ... avoid using a `Semaphore`"*). 한정 자원(DB) 앞에서 VT가 풀 슬롯을 **기다리는 것이 정상 동작**이다.

2. **풀 크기는 CPU 코어 기반으로 산정한다.**
   HikariCP 공식 `connections = (core_count × 2) + effective_spindle_count`를 따른다. 운영 서버 Intel N100(4코어, HT 없음) + SSD 1 → `(4×2)+1 = 9`, 실사례 권장 ~10. 풀을 100+로 키워 상류 동시성을 흡수하려는 접근은 금지한다 — 코어 수를 크게 초과하는 동시 쿼리는 컨텍스트 스위칭 오버헤드로 오히려 처리량을 떨어뜨린다(HikariCP About Pool Sizing).

3. **`connection-timeout`은 "빠른 실패"가 아니라 "큐잉 흡수"로 설정한다.**
   VT는 대기 비용이 싸므로, 풀이 일시적으로 가득 차도 슬롯을 기다렸다가 처리되도록 timeout을 충분히 둔다(HikariCP: *"소규모 풀에서 많은 스레드가 커넥션을 기다리는 상태가 이상적"*). 단, DB 다운 등 진짜 장애를 은폐하지 않도록 무한정이 아닌 합리적 상한을 유지한다.

4. **적용 (collector, 구체값은 SPEC-COLLECTOR-DBPOOL-001):**
   `maximum-pool-size: 5 → 10`, `minimum-idle: 2 → 4`, `connection-timeout: 5000 → 20000`.
   향후 단일 MySQL을 공유할 analyzer·notifier·trader도 동일 원칙(코어 기반 풀 + 큐잉 흡수 + 세마포어 배제)을 따르며, **전 서비스 풀 합산이 MySQL `max_connections`를 넘지 않도록** 관리한다.

---

## 검토한 대안

### 대안 A — 배치별 또는 중앙화된 Semaphore로 DB 동시성 제한

각 배치 서비스(또는 공통 실행 템플릿)에서 DB 쓰기 직전 Semaphore로 동시 접근을 제한한다.

| 항목 | 내용 |
|------|------|
| 장점 | 풀과 무관하게 DB 도달 동시성을 직접 상한 |
| 단점 (결정적) | Inside.java SIP094가 명시적으로 "avoid"라고 지목한 안티패턴 — 이미 풀이 세마포어 역할을 한다. 풀 위에 세마포어를 중복으로 얹는 셈 |
| 단점 | `release()` 누락 시 슬롯 고갈 위험(collector `KisRateLimiter.release()`에 이미 `@MX:WARN` 선례) |

기각. VT 베스트 프랙티스에 역행하며, 풀이 이미 제공하는 보호를 중복 구현한다.

### 대안 B — 풀을 대폭 상향(100+)해 상류 동시성을 흡수

| 항목 | 내용 |
|------|------|
| 장점 | 대기 없이 모든 VT가 즉시 커넥션 확보 |
| 단점 (결정적) | N100 4코어에서 동시 활성 쿼리가 코어를 크게 초과 → 컨텍스트 스위칭으로 응답 시간↑·처리량↓(HikariCP). DB가 느려져 장애가 악화 |
| 단점 | `max_connections`는 151로 여유가 있으나, 병목은 커넥션 수가 아니라 CPU 처리력 |

기각. 풀 크기의 상한은 커넥션 수가 아니라 CPU 코어가 결정한다.

### 대안 C — 상류 KIS `max-concurrency`를 DB 풀에 맞춰 하향

| 항목 | 내용 |
|------|------|
| 장점 | DB로 가는 흐름을 상류에서 미리 제한 — 가장 우아한 정합 |
| 단점 | 지속 throughput은 `refill-per-second`가 결정하므로 영향은 작으나, 배치 latency·in-flight 버퍼에 트레이드오프 존재. ADR-024 운영 목표와 재조율 필요 |

부분 채택 보류. 본 ADR(하류 풀 정합) 범위 밖이며, 필요 시 별도 검토한다. 하류 정합만으로 현 장애가 해소되는지 우선 검증한다.

### 대안 D — `connection-timeout` 유지(5초, 빠른 실패)

| 항목 | 내용 |
|------|------|
| 장점 | 풀 고갈 시 빠르게 실패해 자원을 점유하지 않음 |
| 단점 (결정적) | 정상적으로 큐잉되어야 할 VT를 실패로 전환 → 데이터 유실. 현 장애의 직접 원인 |

기각. "빠른 실패"는 사용자 요청 처리 경로에는 타당하나, 완전성이 필요한 배치 수집(ADR-024: "EGW00201에 드롭 금지")에는 부적합하다.

---

## 결과

- `aaa-collector/src/main/resources/application.yml`의 HikariCP 설정을 갱신한다(SPEC-COLLECTOR-DBPOOL-001). 동일 파일의 `4서비스×5=20` 주석은 ADR에 근거가 없는 부정확한 인용이므로 실제 정책에 맞게 정정한다.
- 검증: Testcontainers MySQL(`mysql:8.4`) 통합 테스트 + 프로덕션 16:00 라이브 재현 관측. CI 게이트는 `./gradlew check`.
- 운영 수용성(실측, 2026-06-19): `max_connections=151`, `Max_used_connections=6`. collector 풀 10, 미래 4서비스 합산 ~30은 `max_connections`의 ~20%로 안전하다.
- **배치 cron 시차 분산은 본 결정 범위에서 제외**한다(ADR-008의 cron 전용 정책은 유지하되, 16:00 스케줄 자체는 변경하지 않음). 부하 피크 완화가 추가로 필요하면 별도 검토한다.
- **추가 Semaphore 배제 원칙**은 collector를 넘어 단일 MySQL을 공유하는 모든 VT 서비스에 횡단 적용한다.
