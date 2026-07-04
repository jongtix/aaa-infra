# ADR-032: aaa-analyzer Docker 베이스 이미지 — python:3.14-slim 채택 (ADR-012 예외)

- **상태**: 승인
- **일자**: 2026-07-04
- **범위**: aaa-analyzer (ADR-012 alpine 원칙의 예외)

---

## 맥락

ADR-012는 aaa-collector·aaa-notifier·aaa-trader의 Docker 베이스 이미지로 `eclipse-temurin:21-jre-alpine`(Alpine/musl 계열)을 채택하고, 이 전략을 프로젝트 전 서비스의 기본 원칙으로 삼았다. aaa-analyzer(Python 3.14 + FastAPI + uv, TECHSPEC 2.1)도 같은 원칙을 적용할지 검토했다.

analyzer는 ML 워크로드(LightGBM, XGBoost, pandas, numpy, scipy)를 실행하며, 이들 라이브러리의 PyPI 배포 휠(wheel)은 대부분 **manylinux(glibc) 대상**으로 빌드된다. Alpine은 musl libc를 사용하므로:

- musl 대상 휠(`musllinux_*` 태그)을 제공하지 않는 패키지가 다수 존재한다.
- 미제공 시 pip/uv가 소스 빌드를 시도하며, ML 라이브러리(특히 LightGBM/XGBoost의 C++ 네이티브 확장, numpy/scipy의 Fortran/BLAS 연동)는 Alpine에서 소스 빌드 시 컴파일 도구체인·빌드 시간·실패 위험이 크게 증가한다.
- 이는 ADR-012가 명시한 "1인 프로젝트, 유지보수 복잡도 최소화" 제약과 정면으로 충돌한다.

analyzer Phase 2 설계 논의([D-1] 런타임 검증, [D-17] CI/CD·품질 게이트, 2026-07-03~04)에서 `python:3.14-slim`(Debian 계열, glibc) multi-arch 이미지 제공을 확인했다.

---

## 결정

**aaa-analyzer는 `python:3.14-slim`을 베이스 이미지로 채택한다.** ADR-012의 alpine 원칙에 대한 명시적 예외다.

### 근거

1. **ML 휠 호환성**: `python:3.14-slim`은 glibc(Debian) 기반이므로 lightgbm·xgboost·pandas·numpy·scipy 전부 사전 빌드된 manylinux 휠을 그대로 설치한다(2026-07-03 PyPI 실측 — Phase 2 설계 문서 [D-1] 참조). 소스 빌드·컴파일 도구체인이 불필요하다.
2. **musl 소스 빌드 회피**: Alpine 채택 시 예상되는 빌드 시간 증가·빌드 실패 위험·Dockerfile 복잡도 상승(컴파일 도구체인 설치)이 slim 채택으로 전부 소거된다.
3. **1인 프로젝트 유지보수 제약과 정합**: ADR-012가 세운 "복잡도 최소화" 원칙을 이 예외가 오히려 더 잘 만족한다 — Alpine을 억지로 적용하면 ML 워크로드에서 복잡도가 늘어나는 역설이 발생한다.
4. **하드닝 조치는 동일하게 적용**: ADR-012의 하드닝 원칙(비루트 실행, read-only 파일시스템, `cap_drop: [ALL]`, digest pinning, 빌드 컨텍스트 최소화)은 이미지 계열과 무관하게 slim에도 그대로 적용한다.

---

## 검토한 대안

### 대안 1 — eclipse-temurin 계열과 동일하게 Alpine 기반 Python 이미지(`python:3.14-alpine`) 채택 — 기각

| 항목 | 내용 |
|------|------|
| 장점 | 프로젝트 전 서비스 베이스 이미지 전략 통일, 이미지 크기 최소화 |
| 단점 | ML 휠 musl 미지원으로 소스 빌드 강제, 빌드 시간·실패 위험 증가, Dockerfile에 컴파일 도구체인 필요 |

기각. 통일성의 이득보다 ML 워크로드 특성상 발생하는 유지보수 비용이 크다. ADR-012 자체도 "재검토 트리거"로 서비스 특성 변화를 인정하고 있다.

### 대안 2 — distroless 계열(Python distroless 이미지) — 기각

| 항목 | 내용 |
|------|------|
| 장점 | 공격 표면 최소화 |
| 단점 | 셸·패키지 관리자 미포함으로 헬스체크 CMD 패턴 사용 불가(ADR-012 대안 2 기각 사유와 동일), Python 공식 distroless 이미지 생태계가 Java 대비 미성숙 |

기각. ADR-012가 Java 서비스에 대해 동일 이유로 이미 기각한 패턴이며, analyzer도 내부 전용 배포(NAS, 인터넷 미노출) 환경 조건이 동일하므로 같은 판단이 적용된다.

### 대안 3 — full `python:3.14`(Debian 비-slim) — 기각

| 항목 | 내용 |
|------|------|
| 장점 | 빌드 도구·라이브러리가 이미지에 기본 포함되어 런타임 소스 빌드 상황에도 안전 |
| 단점 | 이미지 크기가 slim 대비 수백 MB 크다, 불필요한 개발 도구·문서 포함으로 공격 표면 증가 |

기각. ML 휠이 사전 빌드본으로 충분하므로(결정 근거 1) full 이미지의 이점(런타임 빌드 도구)이 불필요하다. slim이 crypto/헬스체크 등 실행에 필요한 최소 구성은 유지하면서 크기·공격 표면을 줄인다.

---

## 결과

- aaa-analyzer Dockerfile은 `python:3.14-slim`을 베이스로 사용한다(digest pinning 적용).
- ADR-012의 하드닝 조치(비루트 UID, read-only, cap_drop, 빌드 컨텍스트 최소화)를 동일하게 적용한다. UID는 기존 서비스(1004)와 충돌하지 않는 별도 값을 SPEC(ANALYZER-FOUNDATION-001) 구현 시 확정한다.
- ADR-012 본문은 "aaa-notifier, aaa-trader도 동일한 베이스 이미지 전략 적용"을 명시하나 aaa-analyzer는 언급하지 않는다 — 본 ADR이 그 공백을 메우며, Java 서비스 3종(collector/notifier/trader)은 ADR-012, Python 서비스(analyzer)는 본 ADR을 따르는 것으로 프로젝트 전체 베이스 이미지 정책을 완성한다.

### 재검토 트리거

- analyzer가 인터넷에 직접 노출되는 환경으로 변경될 때
- ML 라이브러리가 musllinux 휠을 사실상 표준으로 제공하게 되어 Alpine 채택의 비용이 소거될 때
- Python distroless 생태계가 성숙해 헬스체크 제약이 해소될 때
