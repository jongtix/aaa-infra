# ADR-002: Redis AOF 전용 영속성 (RDB 비활성화)

- **상태**: 승인
- **일자**: 2026-02-28
- **관련 문서**: [TECHSPEC 5절 — Redis 설계](../TECHSPEC.md#5-redis-설계)

---

## 맥락

Redis는 서비스 간 이벤트 버스(Streams), 캐싱, 카운터, 주문 멱등성 키 등 다양한 용도로 사용된다. 이 중 Redis Streams의 Consumer Group은 PEL(Pending Entries List)을 통해 미확인 메시지를 추적한다. PEL이 유실되면 메시지 재처리 보장이 깨진다.

Redis 공식 권장 영속성 설정은 AOF + RDB 혼합이다. 두 방식을 함께 써서 복구 옵션을 극대화하는 전략이다.

운영 환경은 NAS (Intel N100, 8GB RAM), Redis `maxmemory 128MB`다.

---

## 결정

**AOF(Append-Only File)만 활성화**하고 RDB 스냅샷을 비활성화한다.

설정값 ([TECHSPEC 5절](../TECHSPEC.md#5-redis-설계) 영속성 참조):
```
appendonly yes
appendfsync everysec
save ""
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
```

---

## 검토한 대안

### 대안 1: AOF + RDB 혼합 (Redis 공식 권장)

두 영속성 메커니즘을 동시에 활성화한다.

| 항목 | 내용 |
|------|------|
| 장점 | 복구 옵션 최대화. RDB로 빠른 초기 로딩, AOF로 최신 데이터 보완 |
| 장점 | Redis 공식 권장 설정 |
| 단점 (결정적) | RDB `fork()` 실행 시 Copy-on-Write로 메모리 일시 2배 소모. maxmemory 128MB 기준 최대 256MB 추가 — NAS 메모리 예산에 부담 |
| 단점 | RDB 스냅샷 주기 사이에 Redis가 재시작되면 PEL 유실 가능 |
| 단점 | 설정·관리 복잡도 증가 (1인 운영) |

**탈락 이유**: PEL 유실 위험 + NAS 메모리 부담 + 관리 복잡도

### 대안 2: RDB 단독

주기적 스냅샷만 사용하고 AOF를 비활성화한다.

| 항목 | 내용 |
|------|------|
| 장점 | 재시작 시 RDB 바이너리 로딩이 AOF replay보다 빠름 |
| 단점 (결정적) | 스냅샷 간격 사이의 Consumer Group PEL 데이터 유실. Streams 메시지 재처리 보장 불가 |
| 단점 | `appendfsync everysec` 기준 최대 1초 데이터만 유실하는 AOF 대비 유실 범위가 훨씬 큼 |

**탈락 이유**: Consumer Group PEL 보존 요건 미충족 (결정적 부적합)

### 대안 3: AOF 단독 (현재 선택)

AOF만 활성화하고 RDB를 비활성화(`save ""`).

| 항목 | 내용 |
|------|------|
| 장점 | Consumer Group PEL 완전 보존 — `appendfsync everysec` 기준 최대 1초 유실 |
| 장점 | RDB `fork()` 미실행 → 메모리 순간 2배 문제 없음 |
| 장점 | 설정 단순화 (1인 운영에 적합) |
| 단점 | RDB 대비 AOF replay 복구 속도 느림 |
| 단점 (수용 가능) | 틱 스트림(`stream:tick:*`)처럼 폐기해도 무방한 데이터도 AOF에 기록됨 |

틱 스트림 AOF 부담은 MAXLEN 설정으로 스트림 크기를 상한 제어하여 최소화한다. maxmemory 128MB 규모에서 AOF replay는 수 초 이내로 완료된다.

---

## 결과

- Redis 영속성은 AOF 단독으로 운영한다.
- Consumer Group PEL이 보존되므로 서비스 재시작 후 미확인 메시지를 `XPENDING`으로 복구할 수 있다.
- `auto-aof-rewrite-percentage 100` + `auto-aof-rewrite-min-size 64mb` 설정으로 AOF 파일 크기를 자동 관리한다.
- 틱 스트림의 AOF 기록 부담은 `MAXLEN` 상한으로 허용 범위 내 통제한다 ([TECHSPEC 5.1절](../TECHSPEC.md#51-redis-streams-서비스-간-이벤트-버스) 참조).
