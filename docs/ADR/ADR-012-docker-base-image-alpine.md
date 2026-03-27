# ADR-012: Docker 베이스 이미지 — eclipse-temurin:21-jre-alpine 채택

- **상태**: 승인
- **일자**: 2026-03-15
- **범위**: aaa-collector (aaa-notifier, aaa-trader 동일 전략 적용 예정)

---

## 맥락

aaa-collector의 컨테이너 베이스 이미지를 선택해야 한다. 다음 조건이 선택 기준이 된다.

- **런타임**: Java 21 (JRE만 필요, JDK 불필요)
- **HEALTHCHECK**: Spring Actuator `/actuator/health` 엔드포인트를 `wget` 또는 `curl`로 폴링
- **프로덕션 환경**: UGREEN DXP2800 NAS (Intel N100, 8GB RAM) — 인터넷 직접 노출 없음, 내부 전용 배포
- **빌드 대상**: GitHub Actions에서 빌드하여 GHCR에 push, Watchtower가 NAS에서 자동 갱신
- **프로젝트 규모**: 1인 프로젝트 — 유지보수 복잡도 최소화가 중요한 제약

---

## 결정

### 1. 베이스 이미지: eclipse-temurin:21-jre-alpine

`eclipse-temurin:21-jre-alpine`을 채택한다.

- Alpine Linux는 `wget`을 기본 포함하므로 HEALTHCHECK CMD 패턴을 추가 설치 없이 사용할 수 있다.
- JRE 전용 이미지를 사용하여 불필요한 컴파일러, 개발 도구를 제거한다.
- digest pinning을 적용하여 이미지 변경 시 의도치 않은 업데이트를 방지한다.

### 2. 빌드 대상 아키텍처: AMD64 단일 빌드

크로스빌드(ARM64/AMD64 멀티 플랫폼)를 적용하지 않고 **AMD64 단일 빌드**만 수행한다.

- 프로덕션 타겟이 Intel N100(x86_64) 단일 노드이므로 ARM64 이미지를 생성할 이유가 없다.
- Docker Buildx 크로스빌드는 QEMU 에뮬레이션으로 ARM64를 빌드할 경우 빌드 시간이 3~5배 증가한다.
- 개발 환경(Apple M-series)과 프로덕션 환경의 아키텍처 불일치는 도커 레이어 캐시 미스 등 이슈를 유발할 수 있어, 단일 아키텍처 고정이 일관성에 유리하다.

### 3. 하드닝 조치

Alpine의 공격 표면이 Distroless보다 넓다는 트레이드오프를 다음 하드닝 조치로 보완한다.

| 조치 | 적용 방법 |
|------|----------|
| 비루트 실행 | `RUN addgroup / adduser`로 전용 유저 생성, `USER` 지시자로 전환. UID는 **1004**로 고정 — DB 서비스 공식 이미지 UID(999)와 분리하여 파일 시스템 권한 충돌 방지. 1000~1003은 Linux 기본 시스템 유저 범위와 겹칠 수 있어 회피. `init-nas.sh`의 호스트 디렉토리 `chown`과 각 서비스 Dockerfile의 `adduser -u` 값은 반드시 일치해야 한다. [^1] |
| 읽기 전용 파일 시스템 | `docker-compose.yml`에서 `read_only: true` 설정 |
| Linux Capabilities 제거 | `cap_drop: [ALL]` 적용 |
| Digest pinning | `FROM eclipse-temurin:21-jre-alpine@sha256:...` 형태로 고정 |
| 빌드 컨텍스트 최소화 | `.dockerignore`로 소스 코드, 테스트 파일, 빌드 캐시 제외 |

---

## 검토한 대안

### 대안 1: eclipse-temurin:21-jre (Debian 계열) — 기각

| 항목 | 내용 |
|------|------|
| 장점 | glibc 기반으로 musl 관련 호환성 이슈 없음, HEALTHCHECK 도구 포함 |
| 단점 | 이미지 크기가 Alpine 대비 약 100MB 이상 크다, CVE 노출 표면이 패키지 수 증가만큼 넓어진다 |

Alpine 대비 이점이 없고 이미지 크기 및 패키지 수 측면에서 불리하다. 기각.

### 대안 2: Google Distroless (gcr.io/distroless/java21-debian13) — 기각

| 항목 | 내용 |
|------|------|
| 장점 | 셸 없음, 패키지 관리자 없음 — 공격 표면이 가장 작음, Google 공식 지원 |
| 단점 | 셸·`wget`·`curl` 미포함으로 HEALTHCHECK CMD 패턴 사용 불가 |

Distroless에서 HEALTHCHECK를 구현하려면 별도의 HTTP 프로브 바이너리(정적 컴파일 Go 바이너리 등)를 이미지에 포함해야 한다. 이는 1인 프로젝트에서 다음 부담을 야기한다.

- 프로브 바이너리의 별도 빌드 파이프라인 관리
- 바이너리 자체의 보안 패치 추적 의무
- Dockerfile 복잡도 상승

보안 감사 결과 현재 배포 환경(내부 전용)에서 Alpine의 리스크가 LOW로 평가되었다. Distroless 도입으로 얻는 보안 이점이 복잡도 증가 비용을 정당화하지 못한다. 기각.

### 대안 3: ARM64/AMD64 멀티 플랫폼 크로스빌드 — 기각

| 항목 | 내용 |
|------|------|
| 장점 | 이미지 범용성, 로컬(Apple Silicon)과 프로덕션 동일 이미지 사용 가능 |
| 단점 | QEMU 에뮬레이션으로 빌드 시간 3~5배 증가, 단일 타겟 환경에서 실익 없음 |

프로덕션 타겟이 Intel N100 단일 노드로 고정되어 있으므로 크로스빌드의 실익이 없다. 기각.

---

## 결과

- eclipse-temurin:21-jre-alpine + 하드닝 조치 조합에 대해 보안 감사 결과 **LOW 리스크**로 평가되었다. 근거: 인터넷 직접 노출 없음(내부 전용 배포), 하드닝 조치(비루트·read-only·cap_drop·digest pinning)가 Alpine의 넓은 공격 표면을 실질적으로 보완한다.
- **musl libc + Virtual Threads**: 알려진 보안 이슈 없음. 단, 다음 항목은 프로덕션 운영 중 모니터링이 필요하다.
  - DNS 조회 동작(musl의 `resolv.conf` 처리 방식이 glibc와 다름)
  - 로케일/문자셋 관련 동작(musl은 로케일 지원이 제한적)
- **트레이드오프 명시**: Alpine의 공격 표면은 Distroless보다 넓다. 이 트레이드오프는 현재 배포 환경(내부 전용)을 전제로 수용 가능하다고 판단한다.
- **재검토 트리거**: 다음 조건 중 하나라도 충족되면 베이스 이미지 결정을 재검토한다.
  - 서비스가 인터넷에 직접 노출되는 환경으로 변경될 때
  - musl libc 관련 런타임 이슈(DNS, 로케일, 성능)가 프로덕션에서 발생할 때
  - 앱 서비스 컨테이너 UID를 변경할 때 (`init-nas.sh`와 Dockerfile 양쪽 동시 변경 필수) [^2]
- aaa-notifier, aaa-trader도 동일한 베이스 이미지 전략과 하드닝 조치를 적용한다.

[^1]: 2026-03-25 UID 1004 선택 근거 및 동기화 규칙 추가
[^2]: 2026-03-25 재검토 트리거 추가
