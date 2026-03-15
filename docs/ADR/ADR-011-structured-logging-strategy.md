# ADR-011: 구조화 로깅 전략 — ECS JSON + SafeMdc 구조적 마스킹

- **상태**: 승인
- **일자**: 2026-03-08
- **범위**: aaa-collector (aaa-notifier, aaa-trader도 동일 전략 적용 예정)

---

## 맥락

aaa-collector의 로그를 프로덕션 환경(UGREEN DXP2800 NAS)에서 수집·분석하기 위해 구조화 로그 도입이 필요하다. 동시에 두 가지 보안 요구사항이 있다.

1. **민감 데이터 보호**: KIS Open API 키, 토큰, 계좌번호가 로그에 평문으로 노출되면 안 된다.
2. **분산 추적**: Redis Streams로 연결되는 서비스 간 요청 흐름을 Trace ID로 추적해야 한다.

추가 제약 조건:

- Spring Boot 3.4+부터 ECS JSON을 네이티브로 지원하므로 추가 의존성 없이 적용 가능하다.
- Virtual Threads 환경에서 MDC는 부모→자식 스레드 간 자동 상속이 되지 않는다.
- 로깅 시스템은 Spring ApplicationContext보다 먼저 초기화되므로 Bean 주입 방식으로 커스터마이저를 등록할 수 없다.

---

## 결정

### 1. 구조화 로그 포맷: ECS JSON (파일 appender 한정)

- 파일 appender에만 ECS JSON을 적용한다 (`logging.structured.format.file: ecs`).
- 콘솔 appender는 개발 편의를 위해 plain text(커스텀 패턴 포함 `trace_id`)를 유지한다.
- 로그 파일 롤링: 최대 1GB / 보존 30일 / 총 용량 cap 50GB, gzip 압축(`.gz` 확장자). 수치 산출 근거: 프로덕션 SSD 2TB 기준, DB 점유 예상치(MySQL 10년 누적 ~1GB + Redis AOF 피크 ~5GB = ~6GB)를 제외하면 로그에 할당 가능한 공간이 충분하다. 서비스당 50GB × 5개 서비스 = 250GB는 SSD 2TB의 약 12.5%로 보수적 설정이다. Phase 1 완료 후 실제 로그 발생량 측정 결과에 따라 cap을 재검토한다.

### 2. 민감 데이터 구조적 방어

단일 방어선에 의존하지 않고, 1차(자동 마스킹) + 2차(빌드타임 차단)를 병행하는 Defense in Depth 원칙을 적용한다.

| 방어 단계 | 구현 | 역할 |
|----------|------|------|
| 1차 (자동 마스킹) | `SafeMdc` | `MDC.put()` 시점에 `MaskingLevel` 등록 키를 자동 마스킹 |
| 2차 (빌드타임 차단) | ArchUnit | `MDC.put()` 직접 호출을 빌드 타임에 차단, `SafeMdc` 경유 강제 |

### 3. 마스킹 포맷

| 레벨 | 포맷 | 적용 대상 | 예시 |
|------|------|----------|------|
| FRONT_ONLY | 앞 4자 노출 + `****` | App Secret, Bot Token | `s3cr****` |
| FRONT_BACK | 앞 4자 + `****` + 뒤 4자 노출 | App Key, Access Token | `PSKd****q1xG` |
| BACK_ONLY | `****` + 뒤 2자 노출 | 계좌번호 | `****01` |

적용 대상은 ADR 작성 시점(2026-03-08) 기준이다. 최신 정보 유형 목록은 TECHSPEC.md 2.3절을 참조한다.

입력값이 각 포맷의 최소 길이 기준(FRONT_ONLY 4자, FRONT_BACK 8자, BACK_ONLY 2자)에 미달하거나 null/empty/blank인 경우, 마스킹 시도 없이 전체 마스킹(`"****"`) 또는 원본 그대로를 반환하는 폴백 동작을 구현에서 보장한다.

### 4. Trace ID

- MDC 키: `trace_id` (snake_case, TECHSPEC 2.3절 기준)
- UUID v4 생성, Redis Streams 헤더를 통해 서비스 간 전파
- Virtual Threads 환경에서 MDC는 부모→자식 스레드 자동 상속이 안 된다. 자식 스레드에서 `TraceIdManager.set()`을 별도 호출해야 한다.

### 5. SafeMdc 설계

`SafeMdc`는 `MDC.put()` 직접 호출을 대체하는 래퍼 클래스다. 동작 방식은 다음과 같다.

- `MaskingLevel`에 등록된 키: `MDC.put()` 호출 시점에 `LogMaskingUtils`로 자동 마스킹하여 저장
- `MaskingLevel`에 미등록된 키: 원본 값 그대로 저장

ArchUnit 규칙으로 `MDC.put()` 직접 호출을 빌드 타임에 금지한다. `SafeMdc` 클래스 내부만 예외로 허용한다.

**구현 파일**:

| 클래스 | 패키지 | 역할 |
|--------|--------|------|
| `MaskingLevel` | `common.logging` | 마스킹 레벨 enum (FRONT_ONLY, FRONT_BACK, BACK_ONLY) |
| `LogMaskingUtils` | `common.logging` | 마스킹 유틸리티 |
| `TraceIdManager` | `common.logging` | Trace ID MDC 관리 |
| `SafeMdc` | `common.logging` | MDC 마스킹 래퍼 — `MDC.put()` 대신 사용 |

---

## 검토한 대안

### 단순 plain text 로그 (기각)

구조화 쿼리 및 자동 파싱이 불가능하다. 로그 양이 늘어날수록 분석 비용이 급증한다.

### Logstash JSON 포맷 (기각)

Spring Boot 3.4+는 ECS JSON을 네이티브로 지원한다. Logstash 포맷은 추가 의존성(`logstash-logback-encoder`)이 필요한 반면, ECS는 의존성 없이 적용 가능하다.

### 콘솔도 ECS JSON 적용 (기각)

개발 중 IDE에서 JSON 형태의 로그를 읽으면 가독성이 크게 저하된다. 파일 appender에만 ECS JSON을 적용하고 콘솔은 plain text를 유지하는 것이 개발 생산성에 유리하다.

### TurboFilter로 MDC 마스킹 (기각)

Logback 내부 확장점인 TurboFilter는 모든 MDC 쓰기를 인터셉트할 수 있다. 그러나 SafeMdc + ArchUnit 조합이 Spring 코드 수준에서 더 명시적이고, 마스킹 책임이 호출 지점에 가까이 위치하여 유지보수에 유리하다. TurboFilter는 Logback 설정 파일에서 관리해야 하므로 코드 가시성이 낮다.

---

## 결과

- ECS JSON 포맷 덕분에 로그 파일을 Elasticsearch, Loki 등의 로그 수집 시스템과 연동할 때 별도 파싱 설정이 최소화된다.
- `SafeMdc`가 `MDC.put()` 시점에 마스킹을 보장하고, ArchUnit이 `MDC.put()` 직접 호출을 빌드 타임에 차단한다. "put 시점에 이미 마스킹 완료" 불변식이 구조적으로 성립하므로 MDC 경유 민감 데이터 노출 경로가 차단된다.
- **주의사항**: Virtual Threads 환경에서 자식 스레드가 `TraceIdManager.set()`을 호출하지 않으면 해당 스레드의 로그에 `trace_id`가 누락된다. 자식 스레드를 생성하는 코드는 반드시 Trace ID 전파를 처리해야 한다.
- **트레이드오프**: ArchUnit 규칙은 `./gradlew test` 실행 시 적용되므로, 빌드 없이 IDE에서만 작업할 경우 `MDC.put()` 직접 호출 위반이 즉시 감지되지 않는다. pre-push hook의 `test` 태스크를 통해 푸시 시점에 자동 차단된다.
- **이 전략이 커버하지 않는 경로**: SafeMdc + ArchUnit은 MDC 경유 경로만 방어한다. 다음 경로는 코딩 컨벤션으로 관리한다.
  - 로그 메시지 인자에 민감값 직접 전달 금지: `log.info("token={}", accessToken)` 형태 사용 금지
  - 예외 메시지에 민감값 포함 금지: `throw new XxxException("Auth failed for: " + token)` 형태 사용 금지
  - HTTP 클라이언트 및 외부 라이브러리 로그: 보안 관련 라이브러리의 로그 레벨을 WARN 이상으로 설정하여 노출 최소화
  - 1인 프로젝트 규모에서 이 경로들에 대한 정적 분석 도구나 런타임 필터 도입은 비용 대비 실익이 낮다. SafeMdc가 가장 빈도 높은 경로(MDC)를 구조적으로 차단하고, 나머지는 코딩 컨벤션으로 관리하는 것이 현실적이다.
- aaa-notifier, aaa-trader도 동일한 구조화 로깅 전략을 적용한다.
- aaa-analyzer(Python)의 구조화 로깅 및 trace_id 전파 전략은 Phase 2에서 별도 ADR로 결정한다.
