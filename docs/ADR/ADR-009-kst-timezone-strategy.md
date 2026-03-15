# ADR-009: KST 이중 보장 전략 — JVM + Jackson 동시 설정

- **상태**: 승인
- **일자**: 2026-03-07
- **범위**: aaa-collector, aaa-notifier, aaa-trader (전체 Java 서비스)

---

## 맥락

aaa-collector는 KIS(한국투자증권) Open API를 통해 주식 데이터를 수집한다. KIS API는 응답 시각을 KST(Asia/Seoul, UTC+9) 기준으로 반환한다. 수신한 시각 데이터를 MySQL에 저장하고 Redis Streams에 발행할 때, 시간대 불일치가 발생하면 데이터 정합성 문제로 이어진다.

Spring Boot 애플리케이션의 시간대는 여러 레이어에서 독립적으로 결정된다:

| 레이어 | 적용 범위 |
|--------|----------|
| JVM 기본 시간대 | `new Date()`, `Calendar`, `LocalDateTime` → `ZonedDateTime` 변환, JPA `@CreatedDate` 등 |
| Jackson ObjectMapper | HTTP 응답/요청 JSON의 날짜 직렬화·역직렬화 |
| JDBC/JPA | DB 저장 시 `Timestamp` 변환 (JVM 시간대를 따름) |

이 레이어들이 서로 다른 시간대를 사용하면, 동일한 시각이 레이어를 거치면서 다른 값으로 변환되는 버그가 발생한다.

---

## 결정

JVM 레벨과 Jackson 레벨 **두 곳 모두**에서 KST를 명시적으로 설정하는 이중 보장 전략을 채택한다.

**JVM 레벨** — `AaaCollectorApplication.main()`:
```java
TimeZone.setDefault(TimeZone.getTimeZone("Asia/Seoul"));
SpringApplication.run(AaaCollectorApplication.class, args);
```

**Jackson 레벨** — `application.yml`:
```yaml
spring:
  jackson:
    time-zone: Asia/Seoul
```

---

## 검토한 대안

### UTC 사용

| 장점 | 단점 |
|------|------|
| 국제 표준, 다국어 서비스에 적합 | KIS API 응답이 KST 기준이므로 변환 로직 필요 |
| 서머타임 없음 | 변환 과정에서 버그 유입 가능성 증가 |
| | 1인 개발 + 한국 시장 전용 서비스에서 실익 없음 |

이 서비스는 한국/미국 시장을 다루지만, 원천 데이터(KIS API)가 KST로 제공된다. 수신 즉시 UTC로 변환하는 것보다 KST를 그대로 유지하는 것이 변환 오류 가능성을 낮춘다.

### Jackson 설정만 적용

Jackson `time-zone` 설정은 `ObjectMapper`를 통한 JSON 직렬화·역직렬화에만 영향을 준다. 다음 케이스는 커버하지 못한다:

- JPA `@CreatedDate`, `@LastModifiedDate` — Spring Data의 `AuditingEntityListener`는 `LocalDateTime.now()`를 사용하며 JVM 시간대를 따른다.
- `LocalDateTime` 연산 — `LocalDateTime.now()`는 JVM 기본 시간대를 따른다.
- Jackson 설정을 사용하지 않는 서드파티 라이브러리의 날짜 처리.
- `java.sql.Timestamp` JDBC 변환 — JVM 시간대 기준으로 동작한다.

Jackson만 설정하면 JSON 레이어와 DB 저장 레이어 사이에 시간대 불일치가 발생한다.

### JVM 인자(-Duser.timezone) 사용

`-Duser.timezone=Asia/Seoul`을 JVM 시작 인자로 전달하는 방식이다.

| 항목 | -Duser.timezone | main()에서 setDefault |
|------|-----------------|----------------------|
| 적용 시점 | JVM 기동 직전 | SpringApplication.run() 직전 |
| 설정 위치 | 배포 스크립트 / Docker CMD | 소스코드 |
| 누락 위험 | 배포 환경마다 인자를 추가해야 함 | 소스에 포함되므로 누락 불가 |
| 코드 리뷰 가시성 | 낮음 | 높음 |

배포 스크립트나 Docker 설정에서 JVM 인자를 누락하면 시간대 버그가 프로덕션에서만 발생한다. 소스코드에 설정을 포함시키면 리뷰 가시성이 높아지고 누락 위험이 사라진다.

---

## 결과

- `AaaCollectorApplication.main()`의 `TimeZone.setDefault`는 제거하면 안 된다. 해당 라인을 삭제하면 JPA, JDBC, `LocalDateTime.now()` 등이 JVM 기본 시간대(대부분 UTC)를 따르게 된다.
- `application.yml`의 `spring.jackson.time-zone` 역시 제거하면 안 된다. Jackson이 JVM 시간대를 자동으로 따르지 않는 버전/설정이 존재하므로 명시적으로 선언한다.
- **트레이드오프**: `TimeZone.setDefault`는 JVM 전역 상태를 변경하므로 테스트 실행 순서에 따라 영향을 받는 테스트가 생길 수 있다. 시간대에 민감한 테스트는 `Clock`을 주입받는 방식으로 작성한다(전역 상태 변경 없이 테스트 격리 가능). 불가피하게 `TimeZone.setDefault`가 필요한 경우 테스트 픽스처에서 명시적으로 설정한다.
- aaa-notifier, aaa-trader도 동일한 이중 보장 전략을 적용한다.
