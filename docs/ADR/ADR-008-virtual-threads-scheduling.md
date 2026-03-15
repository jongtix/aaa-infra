# ADR-008: Virtual Threads 환경에서의 @Scheduled 전략 — cron 전용 사용

- **상태**: 승인
- **일자**: 2026-03-07
- **범위**: aaa-collector (Java 21 + Virtual Threads 활성화 서비스)

---

## 맥락

aaa-collector는 `spring.threads.virtual.enabled: true`로 Virtual Threads를 전역 활성화한다. Spring Boot는 이 설정이 켜지면 `@Scheduled` 작업을 포함한 태스크 실행 스레드를 Virtual Threads로 교체한다.

Spring Boot + Virtual Threads 환경에서 `@Scheduled(fixedDelay = ...)` 사용 시 다음 버그가 보고되어 있다 (Spring Framework [#31900](https://github.com/spring-projects/spring-framework/issues/31900), [#31749](https://github.com/spring-projects/spring-framework/issues/31749)):

- `fixedDelay`는 이전 실행 완료 후 다음 실행까지의 대기를 스레드 park/unpark로 구현한다.
- Virtual Threads 위에서 이 메커니즘이 플랫폼 스레드를 블록하거나, 대기 시간 계산이 예상과 다르게 동작하는 케이스가 존재한다.
- 결과적으로 작업이 의도한 간격보다 훨씬 짧거나 길게 실행되거나, 누적 지연이 발생할 수 있다.

반면 `cron` 표현식은 외부 시계(시스템 시간)를 기준으로 다음 실행 시각을 계산하므로 스레드 내부 타이밍에 의존하지 않는다. Virtual Threads 환경에서도 동작이 안정적이다.

---

## 결정

aaa-collector의 `@Scheduled` 작업에서 **`cron` 표현식만 허용**한다.

```java
// 허용
@Scheduled(cron = "0 0 9 * * MON-FRI")

// 금지
@Scheduled(fixedDelay = 60_000)
@Scheduled(fixedDelayString = "${interval}")
```

---

## 검토한 대안

### fixedDelay 유지

| 장점 | 단점 |
|------|------|
| 이전 실행 완료 직후 다음 실행을 보장하는 의미론적 명확성 | Virtual Threads 환경에서 타이밍 버그 발생 |
| 설정이 직관적 | 재현이 어려운 간헐적 지연 발생 가능 |

fixedDelay의 "이전 실행 완료 후 N ms 대기" 의미론이 필요한 경우, 현재 aaa-collector의 수집 작업에는 해당 요건이 없다. 모든 작업은 시장 시간(장 시작/종료) 또는 특정 시각에 연동하므로 cron이 더 적합하다.

### fixedRate 허용 여부

`fixedRate`는 이전 실행 완료와 무관하게 고정 주기로 실행을 시도한다. Spring Framework #31900 이슈에서 "cron and fixedRate tasks are not limited like this and run on separate threads"라고 명시되어 있으며, fixedRate는 fixedDelay와 달리 Virtual Threads 타이밍 버그 대상이 아니다. **현재는 fixedRate도 사용하지 않는다.** 이는 기술적 제약이 아니라, 모든 수집 작업이 시장 시간에 연동되어 cron이 더 적합하기 때문이다. 향후 fixedRate가 필요한 케이스가 생기면 별도 검토 후 이 ADR을 업데이트한다.

### Virtual Threads 비활성화

| 장점 | 단점 |
|------|------|
| fixedDelay/fixedRate 버그 회피 | Virtual Threads의 I/O 처리량 이점 포기 |
| | KIS WebSocket 수신 및 REST 배치 호출의 블로킹 I/O가 많아 Virtual Threads 적합도가 높음 |
| | 플랫폼 스레드 풀 튜닝 부담 재발생 |

Virtual Threads를 비활성화하는 것은 근본 원인이 아닌 증상 회피다. 스케줄링 방식을 바꾸는 것이 올바른 해결 방향이다.

---

## 결과

- `@Scheduled` 작업에서 `fixedDelay`, `fixedDelayString` 사용을 금지한다.
- `fixedRate`, `fixedRateString`은 Virtual Threads 타이밍 이슈 대상이 아니나, 현재는 사용하지 않는다. 필요 시 이 ADR을 업데이트한다.
- 모든 스케줄 작업은 `cron` 표현식으로 작성한다. 시간대는 KST 기준이다.
- 이 규칙은 CLAUDE.md에 명시되어 신규 작업 작성 시 자동으로 적용된다.
- aaa-notifier, aaa-trader도 Virtual Threads를 활성화할 경우 동일 규칙을 적용한다.
