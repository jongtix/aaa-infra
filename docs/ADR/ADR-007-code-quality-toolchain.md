# ADR-007: Java 서비스 코드 품질 도구 조합 — Spotless + SpotBugs + PMD

- **상태**: 승인
- **일자**: 2026-03-07
- **범위**: aaa-collector, aaa-notifier, aaa-trader (전체 Java 서비스)

---

## 맥락

Java 서비스(aaa-collector, aaa-notifier, aaa-trader)는 1인 개발 환경에서 일관된 코드 품질을 유지해야 한다. 코드 포맷 통일, 버그 및 보안 취약점 조기 탐지, 소스코드 품질 규칙 적용이라는 세 가지 목표를 달성하기 위해 도구 조합을 선정해야 했다.

도구 선정 기준은 다음과 같다:

1. 포맷 강제 적용: 리뷰 시 포맷 논쟁 제거
2. 버그·보안 탐지: 바이트코드 수준의 정적 분석
3. 품질 규칙 검사: 소스코드 수준의 안티패턴 방지
4. 커밋 전 자동 실행: 문제가 레포에 유입되기 전에 차단

---

## 결정

Java 서비스 코드 품질 도구로 **Spotless + SpotBugs(FindSecBugs) + PMD** 조합을 채택한다.

| 도구 | 역할 |
|------|------|
| Spotless (Google Java Format AOSP) | 코드 포맷 자동 적용 |
| SpotBugs + FindSecBugs | 바이트코드 기반 버그·보안 취약점 탐지 |
| PMD | 소스코드 기반 품질 규칙 검사 (bestpractices, errorprone, codestyle, design, multithreading, performance) |
| pre-commit hook | 커밋 전 Spotless(check) + PMD 자동 실행 |

SpotBugs는 CI에서 실행한다. pre-commit hook에서 제외하여 커밋 사이클 마찰을 줄인다.

---

## 검토한 대안

### Checkstyle 미채택

| 장점 | 단점 |
|------|------|
| 포맷 규칙을 명시적으로 선언 가능 | Spotless와 역할 중복 |
| | Spotless는 자동 수정(apply)까지 제공하므로 개발 경험이 더 좋음 |
| | check만 하는 Checkstyle은 수동 수정 부담이 남음 |

Spotless가 포맷을 강제 적용하므로 포맷 검사만 하는 Checkstyle은 중복이다. Spotless는 자동 수정까지 처리하므로 Checkstyle을 추가할 실익이 없다.

### PMD security 카테고리 미포함

PMD 7.x 기준 `category/java/security.xml`에는 `HardCodedCryptoKey`, `InsecureCryptoIv` 2개 룰만 존재한다. 두 룰 모두 FindSecBugs가 동일하게 커버한다(`HARD_CODE_KEY`, `STATIC_IV`). 중복 탐지로 노이즈만 추가되므로 제외한다.

### SpotBugs를 pre-commit hook에서 실행 (기각)

| 장점 | 단점 |
|------|------|
| 유입 전 차단 가능 | 바이트코드 분석 비용(30~120초)으로 커밋 사이클 마찰 |
| | CI 환경에서도 동일하게 실행되므로 중복 |

바이트코드 분석 비용으로 인한 커밋 사이클 마찰을 줄이기 위해 SpotBugs는 CI에서만 실행한다.

---

## 결과

- 세 Java 서비스 레포(aaa-collector, aaa-notifier, aaa-trader)에 동일한 Gradle 플러그인 구성을 적용한다.
- pre-commit hook에서 `./gradlew spotlessCheck pmdMain pmdTest`를 자동 실행한다. SpotBugs는 CI에서 실행하며 hook에서 제외한다.
- PMD 적용 카테고리는 bestpractices, errorprone, codestyle, design, multithreading, performance로 한정한다. security 카테고리는 FindSecBugs와 중복이므로 제외한다.
- 동일한 도구 조합이므로 설정 파일(PMD ruleset XML 등)은 서비스 간 복사하여 관리한다. 추후 공통 설정 레포 분리가 필요하면 별도 ADR로 결정한다.
- PMD ruleset XML 또는 SpotBugs 설정을 변경할 경우 세 서비스 레포에 동기화 적용을 확인한다.
