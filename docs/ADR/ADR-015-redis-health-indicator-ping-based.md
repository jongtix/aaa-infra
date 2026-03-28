# ADR-015: Redis HealthIndicator — PING 기반 커스텀 구현 채택

- **상태**: 승인
- **일자**: 2026-03-28
- **범위**: aaa-collector (향후 aaa-notifier, aaa-trader 동일 적용)

---

## 맥락

Spring Boot 기본 `RedisHealthIndicator`는 내부적으로 `INFO` 명령을 사용한다. `INFO`는 Redis ACL의 `@dangerous` 카테고리에 포함된 명령이다.

`appuser` ACL은 `+@all -@dangerous`로 설정되어 있어, 애플리케이션이 `INFO`를 호출하면 NOPERM 에러가 반환된다. 그 결과 `/actuator/health` 엔드포인트에서 Redis 상태가 `DOWN`으로 표시되며, 이를 바라보는 컨테이너 healthcheck도 unhealthy로 판정된다.

`admin` 유저 PING 기반의 Docker healthcheck(`HEALTHCHECK` 지시문)는 정상 동작하므로, 문제는 ACL 권한이 없는 `appuser`가 `INFO`를 호출하는 데 있다.

---

## 결정

### 기본 `RedisHealthIndicator` 비활성화 + 커스텀 `RedisPingHealthIndicator` 구현

```yaml
management:
  health:
    redis:
      enabled: false
```

`RedisHealthIndicator`를 비활성화하고, `PING` 명령만 사용하는 커스텀 `RedisPingHealthIndicator`를 구현한다.

- `PING`은 `@fast` 카테고리에 속하며 `-@dangerous` ACL 규칙에 영향받지 않는다.
- 커스텀 구현체는 `HealthIndicator` 인터페이스를 직접 구현하여 Spring Boot Actuator `/actuator/health`에 자동 등록된다.
- Bean 이름을 `redisHealthIndicator`로 등록하여 기본 구현체를 대체한다.

---

## 검토한 대안

### Option A: ACL에 `+info` 예외 허용 — 기각

| 항목 | 내용 |
|------|------|
| 장점 | 기본 `RedisHealthIndicator` 변경 없이 즉시 해결 |
| 단점 | ACL 보안 정책(`-@dangerous`) 설계 의도 위반. 예외를 허용하는 선례를 남겨 향후 ACL 규칙이 점진적으로 무력화될 위험 |

`-@dangerous` 정책은 `KEYS`, `DEBUG`, `FLUSHALL`, `FLUSHDB`, `CONFIG`, `SHUTDOWN` 등 운영 위험 명령을 일괄 차단하기 위한 설계 결정이다. `INFO` 하나를 위해 예외를 추가하는 것은 이 정책의 의도를 훼손한다. 기각.

### Option B: 커스텀 PING 기반 HealthIndicator — **채택**

| 항목 | 내용 |
|------|------|
| 장점 | ACL 정책 무변경. PING은 `@fast` 카테고리로 `appuser` 권한으로 항상 통과. 구현 단순 |
| 단점 | `INFO` 기반 상세 서버 정보(버전, 메모리 사용량 등)를 health 응답에 포함할 수 없음 |

### Option C: Actuator Redis health check 비활성화 — 기각

| 항목 | 내용 |
|------|------|
| 장점 | 코드 변경 없이 NOPERM 에러 제거 |
| 단점 | TECHSPEC 10.3절 healthcheck 요구사항(애플리케이션 레벨 Redis 감시) 위반. Redis 장애를 `/actuator/health`에서 감지할 수 없어 컨테이너 자가 회복 메커니즘이 작동하지 않음 |

기각.

---

## 결과

- ACL 정책(`appuser: +@all -@dangerous`) 변경 없음.
- `/actuator/health`에서 Redis 연결 상태를 정상 감지한다.
- `PING` 응답 성공/실패로 UP/DOWN을 판단하며, `INFO` 기반 상세 메타데이터는 health 응답에 포함되지 않는다.
- **트레이드오프**: health 응답에서 Redis 서버 버전·메모리 사용량 등 상세 정보가 제거된다. 이 정보는 운영 모니터링 목적이며, health 엔드포인트의 본래 역할(연결 가능 여부 판단)과 구분된다.
- **향후 적용**: aaa-notifier, aaa-trader에도 동일한 커스텀 `RedisPingHealthIndicator` 패턴을 적용한다.
