# TECHSPEC: AAA (Algorithmic Alpha Advisor)

> 최초 작성: 2026-02-22
>
> **상위 문서**: [PRD.md](PRD.md)
> **원칙**: PRD와 충돌 시 PRD가 우선한다.
>
> 이 문서는 PRD가 정의한 "무엇을"을 "어떻게" 구현하는지 기술한다.
> 구현자가 설계 의도를 이해하고 코딩을 시작할 수 있어야 한다.

---

## 목차

1. [시스템 아키텍처](#1-시스템-아키텍처)
2. [기술 스택](#2-기술-스택)
3. [데이터 수집](#3-데이터-수집)
4. [DB 스키마](#4-db-스키마)
5. [Redis 설계](#5-redis-설계)
6. [ML 파이프라인](#6-ml-파이프라인)
7. [피처 엔지니어링](#7-피처-엔지니어링)
8. [알림 필터 파이프라인](#8-알림-필터-파이프라인)
9. [주문 실행 흐름](#9-주문-실행-흐름)
10. [배포 환경](#10-배포-환경)
11. [성능 지표 측정](#11-성능-지표-측정)
12. [보안](#12-보안)

---

## 1. 시스템 아키텍처

### 1.1 서비스 구성

```
┌─────────────────────────────────────────────────────────────┐
│                        aaa-infra                            │
│              (Docker Compose, 공통 인프라)                    │
└─────────────────────────────────────────────────────────────┘
         │                │               │              │
         ▼                ▼               ▼              ▼
┌──────────────┐  ┌──────────────┐  ┌──────────┐  ┌──────────┐
│ aaa-collector│  │ aaa-analyzer │  │aaa-notif │  │aaa-trader│
│  (Phase 1)   │  │  (Phase 2)   │  │ (Phase 3)│  │(Phase 4) │
│ Java 21      │  │ Python 3.14  │  │ Java 21  │  │ Java 21  │
│ Spring Boot  │  │ FastAPI      │  │ Spring   │  │ Spring   │
└──────┬───────┘  └──────┬───────┘  └────┬─────┘  └────┬─────┘
       │                 │               │              │
       └─────────────────┴───────────────┴──────────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              ▼                  ▼                   ▼
       ┌────────────┐    ┌──────────────┐    ┌────────────┐
       │  MySQL 8.4 │    │  Redis 8.6   │    │  외부 API  │
       │  (단일 DB) │    │(Streams+캐시)│    │  KIS/FRED/ │
       └────────────┘    └──────────────┘    │  DART 등   │
                                             └────────────┘
```

### 1.2 서비스 간 통신 흐름

| 통신 경로 | 방식 | 비고 |
|-----------|------|------|
| collector → analyzer | Redis Streams | 일봉 수집 완료 이벤트 |
| collector → MySQL | JDBC | 배치 데이터 직접 저장 |
| collector → Redis | Lettuce | 틱 발행 (타이밍 평가용), 캐시, 카운터 |
| analyzer → MySQL | SQLAlchemy | 추론 결과 저장 |
| analyzer → Redis Streams | redis-py | 매매 신호 발행 |
| notifier → Redis Streams | Lettuce | 신호 구독 |
| notifier → Redis Streams | Lettuce | 실시간 체결/호가 틱 구독 (타이밍 평가) |
| notifier → Telegram API | HTTP | 알림 발송 |
| trader → Redis Streams | Lettuce | 알림 이벤트 구독 |
| trader → KIS API | HTTP | 주문 실행 |
| trader → Telegram Bot API | HTTP (Long Polling) | 명령 수신 |

**저장 전략**:
- WebSocket 실시간 데이터 → Redis Streams (타이밍 평가용 틱 발행, 틱 원본 비보관)
- REST 배치 데이터 → MySQL 단독 저장
- 서비스 간 직접 HTTP 호출 없음 (Redis Streams 경유)
- 데이터별 저장 위치·보관 기간 상세는 [3.6절](#36-데이터-보관-정책) 참조
- 전체 Redis Streams 목록은 [5.1절](#51-redis-streams-서비스-간-이벤트-버스) 참조

### 1.3 안전 모드 (Safe Mode)

자동 복구 상한 초과 시 장애 모듈만 비활성화하고, 나머지 파이프라인은 정상 운영한다.

**격리 단위**

| 서비스 | 모듈 | 비활성화 시 영향 |
|--------|------|-----------------|
| collector | KIS WebSocket (실시간) | 실시간 틱 수집 중단, REST 배치·ML 추론·알림 정상 |
| collector | 외부 API (환율/VIX 등) | 해당 피처 Fallback 또는 stale, 나머지 정상 |
| analyzer | ML 추론 | 신호 생성 중단, 수집·알림(기존 신호)·주문 정상 |
| notifier | 텔레그램 발송 | 알림 큐잉, 복구 후 요약 발송 |

**텔레그램 장애 큐잉 정책** ([PRD 10.4절](PRD.md#104-장애-알림-기준) 참조)

| 항목 | 정책 |
|------|------|
| 큐잉 저장소 | Redis List (`queue:telegram:pending`) |
| 보존 기간 | 최대 24시간 (이후 자동 삭제) |
| 복구 후 발송 | 큐에서 FIFO로 꺼내 요약 메시지 1건으로 묶어 발송 |
| 요약 형식 | "장애 기간: {시작}~{종료}, 미발송 {N}건" + 이벤트 목록 (최대 10건, 초과 시 건수만 표기) |
| Phase 적용 | Phase 3 (notifier 구현 시) |

**상태 관리**

- 저장소: Redis key (`safe_mode:{service}:{module}`)
- 값: `ON` / `OFF`
- 진입·해제 시 시스템 채널(텔레그램) 즉시 알림
- 상세 구현: [TBD]

**진입 조건**

| 조건 | 예시 |
|------|------|
| 자동 복구 상한 초과 | WebSocket 재연결 [TBD]회 연속 실패 (초기 기본값 범위: ~5회) |
| 외부 API Fallback 소진 | 모든 Fallback 체인 실패 |
| 자원 임계치 3단계 도달 | 디스크/RAM/CPU (10.5절 참조) |

**해제 조건**

- 운영자 수동 해제 (텔레그램 명령)
- 자동 해제: [TBD] (구현 시 결정)

**수동 개입 절차** ([PRD 10.2절](PRD.md#102-수동-개입-기준) 참조)

| 단계 | 행동 |
|------|------|
| 1. 원인 확인 | 시스템봇 알림 수신 → 서비스 로그에서 장애 원인 파악 |
| 2. 조치 | 원인에 따라 서비스 재시작, 설정 변경 등 수행 |
| 3. 안전 모드 해제 | 조치 완료 후 해제 |
| 4. 정상 복귀 확인 | 해제 후 최소 1개 수집 주기(5분) 동안 수집 건수 정상 여부 확인 |

### 1.4 텔레그램 채널 아키텍처

매매봇과 시스템봇을 독립 토큰·커넥션으로 분리하여, 매매봇 장애 시에도 시스템 알림을 정상 수신한다.

**봇 분리**

| 봇 | 용도 | 발신 서비스 |
|----|------|-------------|
| 매매봇 | Tier 1/2 신호 알림, 인라인 버튼, 주문 결과, 주문 명령 수신, 일일 리포트 | notifier, trader |
| 시스템봇 | 장애 알림, 안전 모드, 자동 복구 결과, 자원 경고 | notifier, collector, analyzer |

**독립성 보장**:
- 각 봇은 별도 Bot Token으로 운영
- 한쪽 봇의 토큰 만료·rate limit·장애가 다른 봇에 영향 없음
- 환경 변수로 토큰 분리 관리
- [TBD - Phase 3 착수 전] 봇 토큰 유출 시 대응 절차 정의 (BotFather 즉시 재발급 → 환경 변수 교체 → 서비스 재시작)

---

## 2. 기술 스택

### 2.1 서비스별 스택

| 서비스 | 언어/런타임 | 프레임워크 | 빌드 도구 |
|--------|------------|-----------|-----------|
| aaa-collector | Java 21 (Virtual Threads) | Spring Boot 3.5.11 | Gradle Kotlin DSL |
| aaa-analyzer | Python 3.14 | FastAPI | uv |
| aaa-notifier | Java 21 (Virtual Threads) | Spring Boot 3.5.11 | Gradle Kotlin DSL |
| aaa-trader | Java 21 (Virtual Threads) | Spring Boot 3.5.11 | Gradle Kotlin DSL |

### 2.2 인프라 스택

| 구성 요소 | 버전 | 용도 |
|-----------|------|------|
| MySQL | 8.4 LTS | 주 데이터 저장소 |
| Redis | 8.6 | Streams (서비스 간 통신) + 캐싱 + 카운터 |
| Docker Compose | - | 컨테이너 오케스트레이션 |

### 2.3 공통 규칙

- **시간대**: 모든 서비스 KST(Asia/Seoul) 통일. UTC 사용 금지
  - 외부 API(미국 거래소, FRED 등) 수신 타임스탬프는 KST로 변환 후 저장한다
  - 변환 기준: 각 소스의 명시적 타임존 정보 우선, 없으면 거래소 로컬 타임(NYSE/NASDAQ: ET) 기준 적용
  - ET 변환 시 고정 오프셋(`-5h`/`-4h`) 사용 금지. 반드시 `ZoneId.of("America/New_York")` 사용 (DST 자동 처리)
  - KIS API 해외 일봉 응답에는 현지 시각(EST/EDT)이 KST와 함께 포함된다. 현재는 KST만 저장하되, 향후 intraday 시간 기반 피처 도입 시 현지 시각도 수집 가능
  - ML 피처 계산 시 `created_at` 등 DATETIME 타임스탬프가 아닌 `trade_date DATE` 컬럼을 조인 키·정렬 기준으로 사용한다 (DST 전환일 오류 원천 차단)
  - 상세: [ADR-009](ADR/ADR-009-kst-timezone-strategy.md)
- **스케줄링**: `@Scheduled`를 사용하는 Java 서비스는 cron 표현식만 사용 (`fixedDelay` 금지 — Virtual Threads 버그: Spring Framework #31900, #31749). Python 서비스(analyzer)는 APScheduler cron 사용. Redis Streams 이벤트 구독은 스케줄링이 아닌 별개 메커니즘으로 이 규칙 적용 대상 아님
  - 상세: [ADR-008](ADR/ADR-008-virtual-threads-scheduling.md)
- **로깅**: Java 서비스 파일 appender는 ECS JSON 포맷 출력, 콘솔 appender는 plain text 유지. 민감 정보는 `SafeMdc` + ArchUnit 조합으로 구조적 마스킹
  - **마스킹 전략**: `SafeMdc`가 `MDC.put()` 시점에 자동 마스킹(1차), ArchUnit이 `MDC.put()` 직접 호출을 빌드 타임에 차단하여 `SafeMdc` 경유 강제(2차)
  - **마스킹 포맷**:

    | 정보 유형 | 노출 규칙 | 예시 |
    |-----------|-----------|------|
    | App Key | 앞 4자 + 뒤 4자 | `PSKd****q1xG` |
    | App Secret | 앞 4자만 | `s3cr****` |
    | Access Token | 앞 4자 + 뒤 4자 | `eyJh****ab3c` |
    | Bot Token | 앞 4자만 | `7312****` |
    | 계좌번호 | 뒤 2자리만 | `****01` |
  - **Virtual Threads MDC**: MDC는 부모→자식 스레드 자동 상속 안 됨. 자식 스레드에서 `TraceIdManager.set()` 별도 호출 필요
  - **로그 파일 롤링**: 최대 1GB / 보존 30일 / 총 용량 cap 50GB / gzip 압축
  - 상세: [ADR-011](ADR/ADR-011-structured-logging-strategy.md)
- **패키지 구조**: Java 서비스는 Package by Feature 구조 채택
  - 도메인 피처 패키지는 해당 도메인의 모든 레이어(controller, service, repository, dto 등)를 포함한다
  - `common` 하위는 목적 단위로 분리 (`logging`, `exception`, `config` 등)
  - 유틸 클래스는 `common.utils`로 통합하지 않고 해당 기술 관심사 패키지에 배치 (예: 로깅 유틸 → `common.logging`)
  - 상세: [ADR-010](ADR/ADR-010-package-by-feature.md)
- **코드 품질**: Java 서비스는 Spotless + SpotBugs(FindSecBugs) + PMD 조합 적용
  - Spotless: Google Java Format AOSP 기준 코드 포맷 자동 적용
  - SpotBugs + FindSecBugs: 바이트코드 기반 버그·보안 취약점 탐지 (CI에서 실행)
  - PMD: 소스코드 기반 품질 규칙 검사 (bestpractices, errorprone, codestyle, design, multithreading, performance)
  - pre-commit hook: `./gradlew spotlessCheck pmdMain pmdTest` 자동 실행
  - 상세: [ADR-007](ADR/ADR-007-code-quality-toolchain.md)
- **Trace ID**: 모든 서비스는 요청/이벤트 처리 시 `trace_id`를 생성하여 로그에 포함한다. Redis Streams 메시지 헤더를 통해 서비스 간 전파한다
  - 생성 방식: UUID v4
  - Redis Streams 헤더 key: `trace_id`
  - 수신 측: 메시지에 `trace_id`가 있으면 그대로 사용, 없으면 새로 생성
- **외부 API 응답 검증**: 외부 API(KIS, yfinance, FRED 등) 응답 데이터는 DB 저장 전 기본 유효성 검증을 수행한다
  - 필수 필드 null/empty 체크
  - 가격 데이터: 0 이하 값 거부
  - 극단값 필터: 전일 대비 변동률이 임계치 초과 시 로그 경고 후 저장 (임계치는 구현 시 확정)
  - 검증 실패 시: 해당 건 저장 제외 + 로그 기록

---

## 3. 데이터 수집

### 3.1 KIS API 제약 및 수용 설계

**API 제약 수치** (2025-04-28 기준)

| 항목 | 제한 | 산출 근거 |
|------|------|-----------|
| REST Rate Limit | 초당 20건 / 계좌 | 5계좌 × 20 = 초당 100건 |
| WebSocket 구독 | 세션당 41건 | 국내/해외/파생 합산 |
| WebSocket 세션 | 계좌(앱키)당 1세션 | 5계좌 = 최대 5세션 ([PRD 7.1절](PRD.md#71-kis-api-제약) 참조) |
| WebSocket 최대 구독 | 5세션 × 41건 = 205건 | 종목+호가 동시 구독 시 1종목 = 2건 소모 |

**종목 수 상한 계산**

- 체결+호가 동시 구독: 1종목 = 2건 → 5세션(205건) ÷ 2 = **최대 102종목** WebSocket 실시간 구독 가능
- REST 배치: 초당 100건 여유. 관심 종목 × API 수로 시간당 요청량 계산하여 관리

**WebSocket 구독 대상 선정**

- 매수 대상: ML 등급이 BUY 또는 STRONG_BUY인 종목
- 매도 대상: ML 등급이 SELL 또는 STRONG_SELL인 종목
- 장 시작 전 MySQL에서 대상 종목 목록을 조회하고, 해당 종목만 체결(H0STCNT0) + 호가(H0STASP0) 구독
- HOLD 종목 및 C/F등급 종목: WebSocket 구독 제외
- 대상 종목 수는 ML 등급 분포에 따라 유동적 (통상 수~수십 종목, 102종목 상한 내)

**Phase 1 임시 구독 정책**: ML 모델이 없는 Phase 1에서는 A·B등급 전 종목을 구독 대상으로 사용한다. 102종목 상한 초과 시 임의로 상한까지 절삭하여 구독한다. Phase 2에서 ML 등급 기반 선정으로 전환한다.

**등급 전환 시 데이터 보정**

- C→A/B 전환 시: 전환 시점부터 ML 추론 대상에 포함. 일봉 데이터는 REST로 이미 수집되어 있으므로 즉시 추론 가능
- 풀링 모델은 종목별 독립 모델이 아니므로 별도 학습 대기 기간 불필요

### 3.2 KIS API 국내 수집 상세

| 데이터 | 수집 방식 | 주기 / 비고 |
|--------|-----------|-------------|
| OHLCV (일봉) | REST | 장 마감 후 1회 |
| 실시간 체결 | WebSocket (`H0STCNT0`) | 틱 → Redis Streams 발행 (타이밍 평가용) |
| 실시간 호가 | WebSocket (`H0STASP0`) | 틱 → Redis Streams 발행 (타이밍 평가용) |
| 프로그램매매 | REST | 일별 배치. 투자자별 매매동향과 중복도 높아 WebSocket 제외 |
| 투자자별 매매동향 | REST | 5개 이상 API, 기관/외국인/개인 |
| 공매도 | REST (`daily_short_sale`, `short_sale`) | 일별 |
| 신용잔고/대차거래 | REST | 3개 이상 API |
| 재무제표 | REST | 7개 이상 API: 매출/영업이익/EPS/BPS/ROE 등 |
| 업종지수 | REST | KOSPI/KOSDAQ/KOSPI200, 7개 이상 API |
| 금리종합 | REST (`comp_interest`) | 국채/회사채 금리 |
| 증시자금종합 | REST (`mktfunds`) | 고객예탁금/신용잔고/MMF |
| 배당/증자/분할 | REST | ksdinfo 계열 12개 이상 API |
| 투자의견/추정실적 | REST (`estimate_perform`, `invest_opinion`) | |
| 뉴스 (제목만) | REST (`news_title`) | 본문 없음 |

### 3.3 KIS API 해외 수집 상세

| 데이터 | 수집 방식 | 주기 / 비고 |
|--------|-----------|-------------|
| OHLCV | REST | 장 마감 후 1회 |
| 실시간 체결 | WebSocket | 미국 0분 지연 (무료 실시간) |
| 호가 (Level 1) | WebSocket | 미국 1단계 호가 |
| 해외선물 | REST | ES, NQ, CL/WTI, VX(VIX 선물) |
| VIX 선물 실시간 | WebSocket (KIS) | VIX 지수와 괴리 있음, 보조 지표로 활용 |
| 배당/권리 | REST | 2개 API 조합 |
| 뉴스 (제목만) | REST (`news_title`, `brknews_title`) | 본문 없음 |

### 3.4 외부 API Fallback 체인

**환율 USDKRW 일봉**

| 순위 | 소스 | 특이사항 |
|------|------|---------|
| 1순위 (Primary) | 한국수출입은행 API | 매매기준율, 영업일 11시 갱신, 1000회/일. 도메인: `oapi.koreaexim.go.kr` (2025-06-25 변경) |
| 2순위 (Fallback 1) | 한국은행 ECOS API | 기준환율 |
| 3순위 (Fallback 2) | yfinance `USDKRW=X` | Close 부정확 버그 주의. 교차검증 용도 |

**VIX 일봉**

| 순위 | 소스 | 특이사항 |
|------|------|---------|
| 1순위 (Primary) | CBOE CDN CSV | `cdn.cboe.com/api/global/us_indices/daily_prices/VIX_History.csv` |
| 2순위 (Fallback 1) | FRED `VIXCLS` | Close만 제공 |
| 3순위 (Fallback 2) | yfinance `^VIX` | 15분 지연 |

**Pre/After-Hours 1분봉**

| 순위 | 소스 | 특이사항 |
|------|------|---------|
| 1순위 (Primary) | yfinance (`prepost=True`) | 1분봉 7일 제한 → 매일 수집 필수. tenacity exponential backoff 적용 |
| 2순위 (Fallback 1) | Alpaca Free API | Paper Trading 계좌, IEX 데이터 |
| 3순위 (Fallback 2) | Polygon.io Free | 5 req/min 제한 |

**yfinance 안정화 전략**:
- retry: tenacity, exponential backoff (4s → 8s → 16s → 32s → 64s, 최대 5회)
- Rate Limit: 요청 간 2~3초 딜레이, 배치 처리
- DB 캐싱: 수집 즉시 저장, 누락 구간만 재요청
- source 메타데이터: 출처 기록 (fallback 추적용)

### 3.5 단일 소스 외부 API

| API | 용도 | 비용 | 제한 |
|-----|------|------|------|
| FINRA Daily Short Sale Volume | 미국 공매도 일별 (`cdn.finra.org`) | 무료 | T+1 |
| FINRA Short Interest | 미국 공매도 반월 (`developer.finra.org`) | 무료 | ~2주 래그 |
| DART OpenAPI | 한국 기업 공시 | 무료 | Push 없음, 폴링 구현 필요. 분당 1000회 |
| 한국은행 ECOS | 한국 거시경제 (기준금리/CPI/GDP/실업률/경상수지) | 무료 | 통계별 갱신 주기 상이 |
| FRED API | 미국 거시경제 | 무료 | 120 req/min |

**FRED 주요 시리즈 ID**

| 지표 | Series ID | 주기 |
|------|-----------|------|
| GDP 성장률 | `A191RL1Q225SBEA` | 분기 |
| CPI | `CPIAUCSL` | 월 |
| 기준금리 | `DFF` | 일 |
| 실업률 | `UNRATE` | 월 |
| 국채 10년물 | `DGS10` | 일 |
| VIX | `VIXCLS` | 일 |

### 3.6 데이터 보관 정책

| 데이터 | 저장 위치 | 보관 기간 |
|--------|-----------|-----------|
| 실시간 체결/호가 (틱 원본) | 저장 안 함 | - |
| 틱 (타이밍 평가용) | Redis Streams | 소비 후 MAXLEN 초과분 자동 삭제 |
| 일봉 OHLCV | MySQL | 영구 보관 |
| 거시경제/수급/재무 데이터 | MySQL | 영구 보관 |

**WebSocket 유실 구간 처리**:
- WebSocket 재연결 성공 직후, 유실 기간 동안의 타이밍 알림 불가 상태를 로그에 기록
- 재연결 안정화 유예: 재연결 성공 후 최소 [TBD]초 동안 연결 상태를 확인 (초기 기본값 범위: ~30초)

**관심 종목 동기화**:

| 회차 | 시각 (KST) | 목적 |
|------|-----------|------|
| 1회 | 07:30 | 한국 프리마켓(08:30) 대비 |
| 2회 | 15:45 | 일과 중 변경분 반영, 미국 프리마켓(17:00/서머타임 16:00) 대비 |

- 동기화 방식: KIS API → DB
- 동기화 실패 시: 직전 DB 목록 유지 + 시스템봇 즉시 알림
- 종목 추가/삭제는 KIS MTS에서만 관리 (시스템 내 편집 불가)
- ML 등급 변경은 텔레그램 명령어로만 가능

### 3.7 시간외 데이터 수집 정책

**미국 Pre/After-Hours**

| 항목 | 정책 |
|------|------|
| 수집 방식 | 스냅샷 2~3회/일 (실시간 스트리밍 아님) |
| ML 추론 | 시간외 전용 신호 생성 안 함 |
| 피처 활용 | 정규장 모델 입력 피처로만 사용 (갭 방향/크기, 거래량 이상치 등) |

**한국 장전/장후 시간외**

| 항목 | 정책 |
|------|------|
| 수집 방식 | 정규장 배치에 포함하여 수집 |
| ML 추론 | 시간외 전용 신호 생성 안 함 |
| 피처 활용 | 시간외 거래량을 수급 피처로 활용 |

**시간외 이벤트 알림 (미국 Pre/After-Hours 전용)**

한국 시간외는 갭 알림 대상에서 제외한다 ([PRD 4절](PRD.md#4-비목표-non-goals) 참조). 한국 시간외 거래량은 수급 피처 경로로만 활용한다.

**갭 계산 기준**

| 세션 | 기준 가격 | 갭 계산 |
|------|-----------|---------|
| Pre-Market | 전일 정규장 종가 | (Pre 현재가 - 전일 종가) / 전일 종가 × 100 |
| After-Hours | 당일 정규장 종가 | (AH 현재가 - 당일 종가) / 당일 종가 × 100 |

**비정상 거래량 계산**

- 기준 통계량: 중앙값(Median) — 평균은 어닝일 거래량에 왜곡되므로 사용하지 않음
- 기간: 직근 20영업일 동일 세션(Pre-Market / After-Hours) 전체를 하나의 버킷으로 계산
- 계산: `volume_ratio = 금일 거래량 / 20영업일 중앙값`
- 중앙값 0인 경우 (평소 시간외 거래 없는 종목): 배율 대신 절대 거래량 기준으로 전환, 최소 거래량 필터 충족 시 알림

**최소 거래량 필터 (Floor)**

노이즈 방지를 위해 아래 조건을 모두 충족해야 알림을 발송한다.

| 조건 | 기준 |
|------|------|
| 거래량 OR 거래대금 | [TBD] 주 이상 OR [TBD] $ 이상 |
| 체결 건수 | [TBD] 건 이상 (수집 가능 시) |

모든 수치는 설정값으로 외부화하여 운영 중 조정 가능하게 구현한다.

**이벤트 태깅**

알림 메시지에 이벤트 컨텍스트를 태깅한다. 이벤트 유무로 임계값을 변경하지 않는다.

| 이벤트 | 데이터 소스 | 수집 주기 |
|--------|-----------|-----------|
| 어닝 (EARNINGS) | yfinance | 일 1회 배치 |
| 배당락일 (DIVIDEND_EX) | yfinance | 일 1회 배치 |
| 주식 분할 (STOCK_SPLIT) | yfinance | 일 1회 배치 |

- 이벤트 유효 기간: 이벤트일로부터 24시간
- 이벤트 API 장애 시: 태그 없이 알림 발송 (알림 기능 자체는 중단 없음)

**알림 임계값**

| 조건 | 임계값 | 알림 유형 |
|------|--------|-----------|
| 갭 | [TBD] % 이상 | 주의 환기 (매매 신호 아님) |
| 비정상 거래량 | [TBD] 배 (중앙값 대비) | 주의 환기 |
| 그 외 가격 변동 | - | 알림 없음 |

### 3.8 KIS API 토큰 관리

KIS API Access Token은 계좌(앱키)당 독립 발급·관리한다.

**시크릿 보호**

인프라 컨테이너와 앱 서비스의 시크릿을 격리한다. MySQL/Redis 컨테이너는 각각 전용 env 파일만 수신하며, 앱 서비스는 `.env.common` + 서비스 전용 파일을 순서대로 지정한다.

| 파일 | 범위 | 주요 내용 |
|------|------|-----------|
| `.env.common` | 앱 서비스 전용 | MySQL host/port/database, Redis host/port, REDIS_APPUSER_PASSWORD, TZ |
| `.env.mysql` | MySQL 컨테이너 전용 | MYSQL_ROOT_PASSWORD, MYSQL_DATABASE, 서비스별 DB 비밀번호 4개, TZ |
| `.env.redis` | Redis 컨테이너 전용 | REDIS_ADMIN_PASSWORD, REDISCLI_AUTH/REDISCLI_AUTH_USER, TZ |
| `.env.collector` | collector 전용 | collector DB 계정, KIS 수집용 앱키 5개, 외부 API 키 (변수명은 Phase 1 착수 시 `aaa-collector` 레포 `.env.example`에 작성) |
| `.env.analyzer` | analyzer 전용 | analyzer DB 계정 (변수명은 Phase 2 착수 시 `aaa-analyzer` 레포 `.env.example`에 작성) |
| `.env.notifier` | notifier 전용 | notifier DB 계정, 매매봇 토큰, 시스템봇 토큰 (변수명은 Phase 3 착수 시 `aaa-notifier` 레포 `.env.example`에 작성) |
| `.env.trader` | trader 전용 | trader DB 계정, KIS 주문용 앱키, 매매봇 토큰, 화이트리스트 (변수명은 Phase 4 착수 시 `aaa-trader` 레포 `.env.example`에 작성) |

`TELEGRAM_TRADE_BOT_TOKEN`은 notifier와 trader 양쪽에 중복 존재한다 (의도된 중복).

- 모든 `.env.*` 파일 권한: `chmod 600` (소유자만 읽기/쓰기)
- Git 커밋 방지: `.gitignore`에 `.env*` 패턴 등록 + pre-commit hook으로 이중 차단 (`.env.example`만 예외 처리)
- **`.env.example` 관리 전략**: `aaa-infra/.env.example`은 인프라 공통 변수만 관리, 서비스별 변수는 각 서비스 레포의 `.env.example`로 분리 관리 ([ADR-006](ADR/ADR-006-env-example-management-strategy.md) 참조)

**토큰 특성**

| 항목 | 값 |
|------|-----|
| 유효 기간 | 24시간 (KIS API 기준) |
| 발급 API | `POST /oauth2/tokenP` |
| 계좌 수 | 5개 (앱키 5개 독립 관리, [PRD 7.1절](PRD.md#71-kis-api-제약) 참조) |

**갱신 전략**

| 경로 | 동작 |
|------|------|
| 정상 (스케줄) | 매일 장 시작 전 `@Scheduled` cron으로 5개 계좌 토큰 일괄 발급 |
| 방어 (Lazy) | API 호출 시 401 응답 수신 → 즉시 재발급 후 원래 요청 재시도 |
| 갱신 실패 | 최대 3회 재시도 (exponential backoff). 3회 실패 시 해당 계좌 안전 모드 진입 + 시스템봇 즉시 알림 |

**저장**

- Redis: `cache:kis:token:{계좌별칭}` (TTL = 토큰 만료 시각 기반)
- 계좌별칭: 계좌번호 대신 별칭 사용 (예: `acct-a`, `acct-b`). 별칭 ↔ 계좌번호 매핑은 환경 변수(`.env`)에서만 관리
- 토큰 갱신 성공 시 Redis TTL 갱신

### 3.9 과거 데이터 백필 전략

Phase 2(ML 학습)에 필요한 과거 데이터를 Phase 1에서 사전 적재한다.

**백필 대상**

| 데이터 | 소스 | 범위 |
|--------|------|------|
| 일봉 OHLCV (국내/해외) | KIS REST API | 종목별 조회 가능한 최대 과거 |
| 수급 데이터 (투자자별 매매동향, 공매도, 신용잔고) | KIS REST API | 종목별 조회 가능한 최대 과거 |
| 거시경제 지표 | ECOS, FRED | 각 API 제공 범위 내 최대 과거 |
| 환율/VIX | Fallback 체인 (3.4절) | 각 소스 제공 범위 내 최대 과거 |

**백필 방식**:
- `backfill_status` 테이블에서 (대상 유형, 대상 코드, 데이터 테이블) 단위로 백필 상태 관리 (4절 스키마 참조)
- `@Scheduled` cron으로 하루 1회 실행: 미완료 항목 대상으로 과거 데이터 수집
- 슬라이딩 윈도우 방식: KIS API는 조회 기간과 무관하게 최신 100건만 반환하므로, 조회 종료일을 과거로 밀어가며 100건씩 소급 수집
- 종료 판단: 0건 반환(해당 날짜 이전 데이터 없음) 또는 100건 미만 반환(상장 초기 도달) 시 완료 처리. HTTP 오류·타임아웃은 실패 처리 (재시도 대상)
- 장애 복구: 마지막 수집 날짜를 기록하여 중단 지점부터 재개. DB 저장과 상태 업데이트를 동일 트랜잭션으로 묶어 중간 상태 방지. Upsert로 중복 무해 처리
- Rate Limit 준수하며 점진적으로 수집 (3.1절 제약 범위 내)

**완료 기준**:
- 모든 관심 종목·지표에 대해 `backfill_status` 전 항목이 완료 상태일 때

---

## 4. DB 스키마

> [TBD - Phase 1 구현 시 확정]

각 Phase 구현 착수 전에 해당 서비스의 테이블 스키마를 이 섹션에 추가한다.

**타입 규칙**: 모든 시간 컬럼은 `DATETIME` 사용. `TIMESTAMP` 사용 금지 (2038년 문제).

**접근 보안**:
- 서비스별 전용 MySQL 사용자 생성 + 최소 권한 원칙 (예: collector는 INSERT/SELECT, analyzer는 INSERT/SELECT)
- `order_log`, `notification_log` 테이블: 모든 애플리케이션 사용자에게 UPDATE/DELETE 권한 미부여 (INSERT-ONLY)
- root 계정 원격 접속 금지
- 포트(3306) 호스트 바인딩 금지 — Docker 내부 네트워크에서만 접근 (`expose`만 사용, `ports` 미사용)
- 비밀번호는 `.env`로 관리 (3.8절 시크릿 보호 참조)

**예정 테이블 분류**

| 분류 | 테이블 (예정) | 담당 서비스 |
|------|--------------|------------|
| 종목 마스터 | `stocks`, `stock_grades` | collector |
| 가격 데이터 | `daily_ohlcv` | collector |
| 시장 지표 | `market_indicators` | collector |
| 해외선물 | `futures_daily` | collector |
| 시간외 데이터 | `extended_hours` | collector |
| 수급 데이터 | `investor_trend`, `short_sale`, `credit_balance` | collector |
| 거시경제 | `macro_indicators` | collector |
| 재무제표 | `financials` | collector |
| 뉴스 | `news_headlines` | collector |
| 공시 | `disclosures` | collector |
| 기업 이벤트 | `corporate_events` | collector |
| 투자의견 | `analyst_estimates` | collector |
| ML 신호 | `trading_signals` | analyzer |
| 알림 이력 | `notification_log` | notifier |
| 주문 이력 | `order_log` | trader |

**테이블 범위 상세**:
- `daily_ohlcv`: 국내/해외 주식, ETF, 업종지수(KOSPI/KOSDAQ/KOSPI200), 시장지수(SPX/NDX) 포함. `asset_type` ENUM으로 구분. 일봉 전용
- `market_indicators`: 환율(USDKRW), VIX 등 일봉 OHLCV 형태의 시장 지표. 주식과 변환 로직이 달라 별도 관리
- `futures_daily`: 해외선물(ES, NQ, CL/WTI, VX). 미결제약정 등 선물 전용 컬럼 포함, 만기 롤오버 처리
- `extended_hours`: 미국 Pre-Market/After-Hours 스냅샷(2~3회/일). `session` ENUM('PRE','AFTER')으로 구분
- `investor_trend`: 투자자별 매매동향. 프로그램매매 포함 여부는 KIS API 응답 확인 후 결정
- `macro_indicators`: ECOS/FRED 거시경제 + 금리종합(`comp_interest`) + 증시자금종합(`mktfunds`). 지표 코드 + 날짜 + 값 구조
- `news_headlines`: 국내/해외 뉴스 제목 ([7.5절](#75-뉴스-피처) 피처 계산용)
- `disclosures`: DART 공시 데이터
- `corporate_events`: 배당/증자/분할/어닝 등 기업 이벤트 통합. `event_type` ENUM으로 구분
- `analyst_estimates`: 투자의견/추정실적

**스키마 상세 수준**:
- Phase 1 대상 테이블: KIS API 실제 응답 확인 후 DDL 수준(컬럼, 타입, 제약조건, 인덱스)으로 확정
- Phase 2~4 대상 테이블(`trading_signals`, `notification_log`, `order_log`): 테이블명 + 주요 컬럼 윤곽만 정의

**백필 메타데이터** — `backfill_status` 별도 테이블로 통합 관리:
- 종목/시장지표/해외선물/거시경제 모든 유형을 (대상 유형, 대상 코드, 데이터 테이블) 복합 키로 하나의 테이블에서 관리
- 데이터 테이블별 독립적으로 완료 상태·마지막 수집 날짜를 추적 (부분 완료 표현 가능)
- 상세 DDL(컬럼, 인덱스, 제약조건)은 Phase 1 구현 시 확정 (3.9절 참조)

**파티셔닝 검토**:
- 현재 예상 데이터 규모(관심 종목 수 × 1건/일 × 250일)에서는 인덱스 최적화로 충분
- [TBD] 연간 1,000만 건 초과 시 timestamp 기준 Range Partitioning 검토 (파티셔닝 단위는 실측 후 결정)

---

## 5. Redis 설계

**접근 보안**:
- ACL 기반 인증 (`aclfile /etc/redis/users.acl`). `requirepass`·`rename-command` 사용 안 함 (deprecated)
  - `default` 유저 비활성화, 명시적 인증 강제
  - `admin`: 전체 권한 (`+@all`) — healthcheck·유지보수 전용
  - `appuser`: `+@all -@dangerous` — 애플리케이션 서비스 전용. `KEYS`, `DEBUG`, `FLUSHALL`, `FLUSHDB`, `CONFIG`, `SHUTDOWN` 등 차단
- 포트(6379) 호스트 바인딩 금지 — Docker 내부 네트워크에서만 접근 (`expose`만 사용, `ports` 미사용)

**영속성**:
- AOF 활성화 (`appendonly yes`, `appendfsync everysec`). Consumer Group 메타데이터(PEL) 보존을 위해 필수
- AOF rewrite: `auto-aof-rewrite-percentage 100` (2배 증가 시 rewrite), `auto-aof-rewrite-min-size 64mb` (Redis 기본값 유지)
- RDB 비활성화 (`save ""`) — AOF와 중복 저장 방지
- 틱 스트림(`stream:tick:*`)은 실시간 소비 후 폐기해도 무방한 데이터이나, Redis는 키별 AOF 제외를 지원하지 않으므로 MAXLEN으로 메모리 상한을 제어하여 AOF 부담을 최소화한다

### 5.1 Redis Streams (서비스 간 이벤트 버스)

| Stream 이름 | 발행자 | 구독자 | 메시지 내용 |
|------------|--------|--------|------------|
| `stream:tick:domestic` | collector | notifier (타이밍 평가) | 국내 실시간 체결/호가 틱 (`symbol` 필드 포함) |
| `stream:tick:overseas` | collector | notifier (타이밍 평가) | 해외 실시간 체결/호가 틱 (`symbol` 필드 포함) |
| `stream:daily:complete` | collector | analyzer | 일봉 수집 완료 이벤트 (`market` 필드 포함: `domestic` / `overseas`) |
| `stream:signal:domestic` | analyzer | notifier | 국내 매매 신호 (`symbol`, 등급, confidence 필드 포함) |
| `stream:signal:overseas` | analyzer | notifier | 해외 매매 신호 (`symbol`, 등급, confidence 필드 포함) |
| `stream:alert` | notifier | trader (Phase 4) | 발송 완료 알림 이벤트 (`tier` 필드 포함) |
| `stream:system:{서비스명}` | collector, analyzer, trader | notifier (시스템봇 발송) | 장애 알림, 안전 모드 진입/해제, 자원 임계치 이벤트 |

**시스템 이벤트 발송 구조**:
- 각 서비스는 장애·복구 이벤트를 `stream:system:{서비스명}`에 발행한다
- notifier가 구독하여 시스템봇으로 텔레그램 발송한다
- notifier 자체 장애 시에는 직접 시스템봇 HTTP 호출로 발송한다 (1.2절 "직접 HTTP 호출 없음" 원칙의 유일한 예외)

**Consumer Group 전략**:
- 각 서비스는 Consumer Group으로 구독 (ACK 기반 메시지 처리 보장)
- 그룹 이름: 구독 서비스명 (예: `notifier`, `analyzer`, `trader`)
- Consumer 이름: `{서비스명}-{스트림역할}` (예: `notifier-signal-domestic`). 키 구분자(`:`)와 의도적으로 구분
- 그룹 생성: 구독 서비스 시작 시 `XGROUP CREATE {stream} {group} $ MKSTREAM` 자동 생성. 이미 존재하면 `BUSYGROUP` 예외 무시
- 초기 오프셋 `$` 정책: 최초 등록 시점 이후 메시지만 수신. 이전 Phase에서 쌓인 과거 메시지 재처리를 방지한다. 재시작 시에는 Redis가 마지막 ACK 위치를 기억하므로 중단 지점부터 이어서 처리

**운영 정책**:
- `MAXLEN` 상한 (Stream별, 환경 변수로 외부화):

| Stream | MAXLEN | trimming | 비고 |
|--------|--------|----------|------|
| `stream:tick:domestic` | 5,000 | `~` (approximate) | Phase 3 이후 Consumer lag 관측 후 재검토 |
| `stream:tick:overseas` | 5,000 | `~` (approximate) | Phase 3 이후 Consumer lag 관측 후 재검토 |
| `stream:daily:complete` | 100 | 정확 | |
| `stream:signal:domestic` | 500 | `~` (approximate) | 종목 수 증가 시 상향 |
| `stream:signal:overseas` | 500 | `~` (approximate) | 종목 수 증가 시 상향 |
| `stream:alert` | 500 | `~` (approximate) | 단일 스트림, `tier` 필드로 구분 |
| `stream:system:{서비스명}` | 200 | 정확 | 서비스별 각각 |
| `stream:dlq:{stream명}` | 500 | 정확 | 수동 확인 전 보존 필수 |

- Phase 1~2 Consumer 부재 참고: `stream:tick:*`의 Consumer(notifier)는 Phase 3에서 구현. Phase 1~2 동안 Consumer Group 없이 발행만 수행하며, MAXLEN으로 메모리 상한을 제어한다. Phase 1 목적은 WebSocket → Redis Streams 경로 검증이며, 5,000건(약 100초치 버퍼)으로 충분하다.
- Pending 메시지 재처리: `XAUTOCLAIM`으로 30초 이상 ACK 없는 메시지를 자신에게 재할당. 서비스 시작 시 `XPENDING` 확인 → 미처리 메시지 우선 처리 후 신규 메시지(`>`) 전환
- Dead-letter 처리: 재처리 3회 초과 시 별도 `stream:dlq:{stream명}`으로 이동 후 시스템 채널 알림

**중복 방지 전략**:
- MySQL 저장 시 Unique Key (종목코드 + 타임스탬프)로 중복 INSERT 방지 (`INSERT IGNORE` 또는 `ON DUPLICATE KEY`)
- REST 배치 수집 시 동일 타임스탬프 데이터가 중복 수집될 수 있으므로, DB 레벨에서 멱등성 보장

### 5.2 Redis 캐싱

| Key 패턴 | 용도 | TTL |
|----------|------|-----|
| `cache:kis:token` | KIS API Access Token | 만료 시간 기반 |
| `cache:stock:list` | 관심 종목 목록 | 장 시작 후 갱신 시까지 |
| `cache:grade:{종목코드}` | ML 등급 | [TBD] |
| `cache:macro:{지표}` | 거시경제 최신값 | 1일 |

### 5.3 Redis 카운터 (Phase 1~2 성능 지표)

| Key 패턴 | 용도 | 리셋 주기 |
|----------|------|-----------|
| `metric:collect:miss:{날짜}` | 수집 누락 건수 | 일별 |
| `metric:collect:latency:{날짜}` | 수집 지연 p95 누적 | 일별 |
| `metric:fallback:{소스}:{날짜}` | Fallback 전환 횟수 | 일별 |
| `metric:recovery:{서비스}:{날짜}` | 자동 복구 횟수 | 일별 |

### 5.4 Redis 주문 멱등성 (Phase 4)

| Key 패턴 | 용도 | TTL |
|----------|------|-----|
| `lock:callback:{callback_query_id}` | 텔레그램 콜백 중복 처리 방지 | 1분 |
| `idempotency:order:{order_id}` | 주문 실행 멱등성 보장 (UUID v4) | 24시간 |
| `limit:order:daily:{user_id}:{market}:{date}` | 일일 주문 금액 한도 (Hash: `confirmed`, `reserved` 필드) | 다음 개장 시각까지 |

- `limit:order:daily` 키는 9.2절 Safety Limits의 Reserve-Confirm-Cancel Lua 스크립트를 구체화한 것. Hash 구조로 `confirmed`(체결 확정 금액)과 `reserved`(API 호출 중 예약 금액)를 분리 관리
- `{market}`은 `KR`(한국) / `US`(미국)이며, 시장별로 한도와 TTL(다음 개장 시각)을 독립 관리

---

## 6. ML 파이프라인

### 6.1 모델 구조

**모델 수 계산**

```
시장 2개 (국내, 해외)
× 시간대 2개 (단기 20영업일, 중기 60영업일)
× 알고리즘 2개 (LightGBM + XGBoost)
= 총 8개 풀링 모델
```

- 풀링 모델: 시장별(국내/해외) A·B등급 전 종목 데이터를 각각 하나의 학습 데이터셋으로 통합. 종목 속성 피처(시가총액, 업종, 베타 등)로 종목을 구분
- 시장 분리 근거: 한국 시장(가격제한폭 ±30%)과 미국 시장(가격제한 없음)의 수익률 분포가 상이하여 동일 레이블 경계 적용 부적합
- 추론 시 종목별 개별 예측 생성 (풀링은 학습 단계, 예측은 종목별)
- [TBD] Phase 2 성능 검증 후 120영업일(~6개월) 모델 추가 검토. 반기 업종 로테이션, 밸류에이션 회귀 포착 목적
- 해외 종목 업종 편중 인지: 현재 해외 관심 종목은 IT 업종 비중이 높다 (약 44%). 대응 전략은 "현재 목록으로 시작 → 업종별 성능 모니터링 → 편향 감지 시 종목 추가"로 한다
- 업종별 성능 모니터링: 업종별 precision/recall을 분리 추적하고, IT 업종 대비 비IT 업종 precision 차이가 15%p 이상이면 편향으로 판단한다. Phase 2 배포 후 30거래일 시점에 첫 리뷰를 수행한다

**5클래스 레이블 정의**

예측 기간(단기 20영업일 / 중기 60영업일) 종료 시점의 실제 수익률로 레이블을 부여한다. 레이블 경계값은 시장별(국내/해외)로 독립 설정한다.

**국내 (가격제한폭 ±30%)**

| 등급 | 단기 (20영업일) | 중기 (60영업일) |
|------|----------------|----------------|
| STRONG_BUY | ≥ +7% | ≥ +12% |
| BUY | +2% ~ +7% | +4% ~ +12% |
| HOLD | -2% ~ +2% | -4% ~ +4% |
| SELL | -7% ~ -2% | -12% ~ -4% |
| STRONG_SELL | ≤ -7% | ≤ -12% |

**해외 (가격제한 없음)**

| 등급 | 단기 (20영업일) | 중기 (60영업일) |
|------|----------------|----------------|
| STRONG_BUY | ≥ +8% | ≥ +15% |
| BUY | +3% ~ +8% | +5% ~ +15% |
| HOLD | -3% ~ +3% | -5% ~ +5% |
| SELL | -8% ~ -3% | -15% ~ -5% |
| STRONG_SELL | ≤ -8% | ≤ -15% |

위 경계값은 변동성 기반 통계적 추정 초안이며, Phase 2에서 실 데이터 수익률 분포 검증 후 조정한다.

- 수익률 계산: 레이블 부여일 종가 → 예측 기간 종료일 종가 기준 (배당 미포함, Close-to-Close)
- 수익률 범위는 시장(국내/해외)별, 시간대(단기/중기)별로 상이할 수 있다
- 클래스 불균형 발생 시 SMOTE 또는 가중치 조정 적용 (시장별 독립 적용)
- 수익률 범위 조정 시점: Phase 2에서 실 데이터 수익률 분포 기반으로 재조정
- 조정 기준 원칙: 시장별 클래스 간 균형, 단기/중기별 변동성 차이 반영, 경계값 근처 샘플의 레이블 민감도 검토 (Label Smoothing, 변동성 비례 HOLD 범위 등)
- Strict Causality: 피처는 추론 시점에 실제로 사용 가능한 데이터만 사용한다 (No Look-Ahead Bias)
- 조정 종가: 배당락·주식분할 발생 시 조정 종가 사용 여부는 Phase 2 착수 시 결정 [TBD]

**앙상블 조합 규칙**

| 조건 | 최종 신호 |
|------|-----------|
| LightGBM과 XGBoost 방향 일치 | 합의 방향으로 확정, confidence = 평균 |
| LightGBM과 XGBoost 방향 불일치 | HOLD로 강등 또는 낮은 confidence 부여 |
| 불일치 처리 세부 규칙 | [TBD] (초기 기본값 범위: HOLD 강등 + confidence = min(두 모델)) |

NAS RAM 16GB 확장 시 CatBoost 추가를 검토한다 (8GB에서 전체 Phase 운영 가능하므로 확장은 선택 사항).

### 6.2 학습 인프라

| 역할 | 장비 | 사양 |
|------|------|------|
| 학습 (Training) | MacBook M1 Pro | 10코어, 32GB RAM |
| 추론 (Inference) | UGREEN DXP2800 NAS | Intel N100, 8GB RAM |

**학습 자동화 흐름**

1. analyzer APScheduler cron → WoL(Wake-on-LAN) → MacBook 부팅
   - WoL 실패 시 3회 재시도 → 최종 실패 시 로그 기록 + 오전 8시 알림
2. WoL 후 30초 대기 → SSH 접속 시도 (실패 시 10초 간격 최대 6회 재시도)
3. SSH → MacBook 학습 스크립트 실행
4. MacBook → NAS MySQL 직접 접속 (로컬 네트워크) → 시장별 전 종목(A·B등급) 수년 일봉 + 종목 속성 피처 조회 (시장별 독립 학습 데이터셋 구성)
5. 학습 완료 → 모델 파일 NFS/SMB 공유 스토리지에 저장
6. SSH 종료 → analyzer가 완료 인지 (exit code로 성공/실패 판별)
7. `stream:system:analyzer` 이벤트 발행 (학습 결과 + 성능 지표, 텔레그램 알림은 Phase 3 이후)

- 학습 스크립트 타임아웃: 초기값 주간 재학습 4시간, 월간 Optuna 튜닝 36시간 (운영하며 조정). 초과 시 SSH 세션 강제 종료 + 실패 처리
- 실패 시 처리 (WoL 실패·SSH 접속 실패·학습 실패 공통): 로그 기록 + 시스템 채널 알림 (Phase 3 이후 텔레그램). 직전 모델 파일 유지 (다음 추론 시 자동 로드)
- 모델 미갱신 경고: 모델 파일명의 학습일자(`{시장}_{시간대}_{알고리즘}_{학습일자}.txt`)를 파싱하여 마지막 성공 학습 날짜를 추적. 4주 이상 미갱신 시 시스템 채널로 경고 알림
- [TBD - Phase 2 착수 전] MacBook → NAS MySQL 접속 보안: 학습 전용 사용자(SELECT만) 분리, TLS/SSH 터널 적용 여부 결정

**SSH 보안 최소 조치** (NAS ↔ MacBook, 동일 LAN 전제):
- 비밀번호 인증 비활성화 (`PasswordAuthentication no`), 공개키 인증만 허용
- Ed25519 키 사용 (기존 RSA 4096이면 변경 불필요)
- 키 생성 시 passphrase 설정 (MacBook Keychain 자동 관리)
- `ServerAliveInterval 60` + `ServerAliveCountMax 3` (60초 keepalive, 3회 무응답 시 끊김 감지)
- 공유기에서 22번 포트 외부 노출되지 않음을 확인
- 네트워크 계층 제한(`ListenAddress` 등)은 미적용: 공개키 인증 + passphrase로 인증 계층이 충분히 방어되며, DHCP 환경에서 IP 고정 시 운영 장애 위험

**모델 파일 관리**:
- 저장 포맷: LightGBM/XGBoost 네이티브 포맷(`.txt`, `.json`, `.ubj`)만 사용. 역직렬화 보안 위험이 있는 포맷 사용 금지
- 저장 경로: NFS/SMB 공유 스토리지 내 `models/{시장}/{시간대}/{알고리즘}/`
- 파일명: `{시장}_{시간대}_{알고리즘}_{학습일자}.txt` (예: `domestic_20d_lgbm_20260301.txt`)
- 버전 보관: 최근 [TBD] 버전 보관, 이전 버전 자동 삭제
- 무결성 검증: 학습 완료 시 SHA-256 해시 파일(`.sha256`)을 모델과 함께 저장. 추론 시 모델 로드 전 해시 검증 → 불일치 시 로드 거부 + 직전 모델 유지 + 로그 기록

**모델 로드 전략** (aaa-analyzer):
- Lazy Load: `stream:daily:complete`의 `market` 필드에 따라 해당 시장 4개 모델만 로드 → 추론 → 언로드. 국내/해외 마감 시간이 다르므로 8개 상시 로드 불필요
- 모델 갱신: 재학습 SSH 종료 후 공유 스토리지에 신규 모델 파일 저장. 다음 추론 시점에 최신 모델 자동 로드

**추론 트리거**:
- 장 마감 후 배치: 일봉 수집 완료 이벤트(`stream:daily:complete`) 수신 시, `market` 필드에 해당하는 시장의 모델만 추론 실행 (국내 마감 → 국내 4개 모델, 해외 마감 → 해외 4개 모델)
- 시장별 4개 풀링 모델 × 해당 시장 A·B등급 전 종목 = 단일 predict 호출로 배치 처리. N100에서 수 분 이내 완료 예상
- 장중 실시간 추론 없음 (Throttling 불필요)
- 추론 결과: 종목별 등급(5클래스) + confidence → MySQL `trading_signals` 저장 + `stream:signal:domestic/overseas` 발행 (`symbol` 필드 포함)

### 6.3 재학습 정책

| 항목 | 정책 |
|------|------|
| 주기 | 주간 (주말) |
| 방식 | 매번 전체 재학습 (증분 학습 아님) |
| 검증 방법 | Walk-Forward Validation (시간순 학습 → 검증 → 테스트, 데이터 리크 방지) |
| 하이퍼파라미터 튜닝 | Optuna (베이지안 최적화) |
| 튜닝 주기 | 월간 (월 1회) |

**Walk-Forward 분할 비율**: 학습 70% / 검증 15% / 테스트 15% (초기 기본값, 파라미터 외부화). Phase 2 실 데이터 기반 수익률 분포 검증 시 최종 조정

### 6.4 성능 모니터링

| 지표 | 정의 | 임계값 |
|------|------|--------|
| 방향 적중률 (Hit Rate) | 예측 방향 == 실제 방향 비율 | [TBD - Phase 2 초기 백테스트 후 확정] |
| Precision | TP / (TP + FP) | [TBD] |
| 샤프 비율 | 단순 매수보유 대비 향상 | [TBD] |
| 최대 낙폭 (MDD) | 모델 기반 전략의 최대 손실 | [TBD] |

> 목표 방향(단순 매수보유 대비 향상)은 [PRD 3절](PRD.md#3-성공-지표-success-metrics) 참조.

**체제 감지 (Regime Detection)**:
- VIX > [TBD] 또는 국채 금리 급변 시 → 신호 자동 억제 (HOLD 강제)
- 억제 조건 해제 기준: [TBD]
- 체제 감지 발동/해제 시 텔레그램 알림

**성능 저하 알림 조건**: [TBD]

### 6.5 종목 등급 분류 로직

PRD 6.2절에 정의된 A/B/C/F 등급을 자동 분류하는 기준.

**A/B/C 자동 분류 정량 기준**

| 등급 | 상장 기간 | 일평균 거래대금 기준 |
|------|-----------|---------------------|
| A | 7년 이상 | 시장 전체 종목 대상 상위 20% |
| B | 3~7년 | 시장 전체 종목 대상 20%~60% |
| C | 3년 미만 또는 거래대금 하위 40% | 나머지 |

- 상장 기간과 거래대금 기준은 AND 조건. 양쪽 모두 충족해야 해당 등급 부여
- 거래대금 백분위는 시장별(한국 KRX / 미국 NYSE+NASDAQ+AMEX) 독립 계산
- 데이터 소스: KIS API 순위분석 (국내: 거래량순위 API `fid_blng_cls_code="3"`, 해외: 거래대금순위 API)

**중복 ETF 대표 선정 알고리즘**:
1. 같은 거래소 + 같은 기초지수 추종 ETF 그룹화
2. AUM(순자산총액) 기준 내림차순 정렬
3. AUM 동률 시 일평균 거래대금으로 재정렬
4. 거래대금도 동률 시 총보수(TER) 낮은 순으로 정렬
5. 1위만 A/B 등급 부여, 나머지는 C 등급 (데이터 수집만)

**F등급 판별**:
- TDF 계열: 펀드명 또는 상품분류 코드로 감지
- 액티브 ETF: KRX 상품분류 코드 `액티브`로 감지
- F등급도 사용자가 텔레그램으로 수동 변경 가능 (Phase 4에서 구현, Phase 4 이전에는 DB 직접 수정)

---

## 7. 피처 엔지니어링

### 7.1 피처 카테고리 개요

| 카테고리 | 공급원 | 적용 대상 |
|----------|--------|-----------|
| 기술적 지표 | OHLCV (일봉) | 전 종목 |
| 수급 | KIS 수급 API, 공매도 API | 전 종목 |
| 거시경제 | ECOS, FRED, KIS 금리 | 전 종목 공통 피처 |
| 시장 지수 | KOSPI/KOSDAQ/S&P500/NASDAQ | 전 종목 공통 피처 |
| 환율/VIX | 한국수출입은행/CBOE/FRED | 전 종목 공통 피처 |
| 뉴스 (Phase 1) | KIS `news_title` | 개별 종목 |
| 뉴스 감성 (Phase 2 이후) | 네이버 뉴스 API, GDELT | 개별 종목 |
| 시간외 갭/거래량 | yfinance Pre/After-Hours | 미국 종목 |
| 종목 속성 | MySQL 종목 마스터 | 전 종목 (풀링 모델 구분용) |

### 7.2 기술적 지표 피처

[TBD - Phase 2 모델 설계 시 확정. 이동평균, RSI, MACD, 볼린저밴드, ATR 등 표준 지표 포함 예정]

### 7.3 수급 피처

**투자자별 매매동향**
- 기관/외국인/개인 순매수 금액 및 비율
- N일 누적 순매수 (이동 합계)

**공매도 피처**

| 피처 | 출처 | 계산 방법 |
|------|------|-----------|
| `SVR` | FINRA Daily Short Volume | `ShortVolume / TotalVolume` |
| `SVR_ma5` | - | SVR 5일 이동평균 |
| `SVR_ma20` | - | SVR 20일 이동평균 |
| `SVR_zscore` | - | SVR Z-score |
| `SVR_spike` | - | SVR Z-score 임계값 초과 여부 |
| `SI_pct_float` | FINRA Short Interest (반월) | 유동주식 대비 공매도 잔고 비율 |
| `SI_ratio` | - | Days to Cover (공매도잔고 / 일평균거래량) |
| `SI_change_pct` | - | 전 반월 대비 변화율 |
| `SI_zscore_6m` | - | 6개월 Z-score |
| `SI_SVR_divergence` | 복합 | SI 하락 + SVR 상승 → 신규 공매도 진입 시그널 |

- FINRA Short Interest는 월 2회 갱신 → LOCF(Last Observation Carried Forward)로 일별 확장

### 7.4 거시경제 피처

| 피처 | 출처 | 주기 |
|------|------|------|
| 기준금리 (한국) | 한국은행 ECOS | 변경 시 |
| CPI (한국) | 한국은행 ECOS | 월 |
| GDP 성장률 (한국) | 한국은행 ECOS | 분기 |
| 경상수지 (한국) | 한국은행 ECOS | 월 |
| 국채/회사채 금리 | KIS `comp_interest` | 일 |
| 기준금리 (미국, DFF) | FRED | 일 |
| 국채 10년물 (미국, DGS10) | FRED | 일 |
| CPI (미국, CPIAUCSL) | FRED | 월 |
| GDP 성장률 (미국) | FRED `A191RL1Q225SBEA` | 분기 |
| 실업률 (미국, UNRATE) | FRED | 월 |
| VIX 지수 | CBOE → FRED → yfinance | 일 |
| USDKRW 환율 | 한국수출입은행 → ECOS → yfinance | 일 |

### 7.5 뉴스 피처

**Phase 1 (NLP 없이)**

| 피처 | 계산 방법 |
|------|-----------|
| `news_count_daily` | 당일 뉴스 제목 수 |
| `news_volume_zscore` | 뉴스 수 Z-score (20일 기준) |
| `news_spike_flag` | Z-score 임계값 초과 여부 |
| 키워드 이벤트 플래그 | 실적/인수합병/소송/배당 등 문자열 매칭 → 이진 플래그 |

**Phase 2 이후 (감성 분석)**

| 대상 | 모델 | 본문 소스 |
|------|------|-----------|
| 한국 종목 | KB-BERT / KB-ALBERT | 네이버 뉴스 검색 API (25,000건/일) |
| 미국 종목 | FinBERT (F1 90.8%) | GDELT (무료) |

- GDELT 도입 시점은 [PRD 7.4절](PRD.md#74-기타-외부-api)에 정의된 조건에 따른다. 도입 이전에는 이 피처 경로를 비활성화한다

### 7.6 틱 데이터 활용 (타이밍 평가 전용)

WebSocket 실시간 체결/호가 데이터는 ML 학습 피처로 사용하지 않는다. notifier의 규칙 기반 타이밍 평가에서만 소비한다.

| 데이터 | 출처 | 용도 |
|--------|------|------|
| 실시간 체결가/체결량 | WebSocket (`H0STCNT0`) | 가격 수준, 거래량 조건 평가 |
| 실시간 호가 (매수/매도 잔량) | WebSocket (`H0STASP0`) | 호가 스프레드, 수급 강도 참고 |

- 타이밍 평가 규칙 상세는 [8절](#8-알림-필터-파이프라인)에서 정의

---

## 8. 알림 필터 파이프라인

### 8.1 파이프라인 6단계

신호가 알림으로 발송되기까지 순서대로 적용.

```
[실시간 틱 입력 — stream:tick:domestic / stream:tick:overseas]
    │
    ▼
1. 타이밍 평가 (장중 실시간)
    │  symbol 필드로 종목 식별
    │  ML 등급 확인 (BUY/SELL 방향인 종목만 통과)
    │  가격 수준 규칙 (전일 종가 대비 하락/상승률)
    │  거래량 확인 (거래량 임계값)
    │  시간대 필터 (장 초반/마감 전 제외 등)
    │  변동성 필터 (ATR 기준 과열 구간 제외)
    ▼
2. 히스테리시스 필터
    │  경계 신호 진동 제거
    ▼
3. 확증 카운터
    │  연속 N회 동일 신호 확인
    ▼
4. 쿨다운
    │  억제 시간 경과 확인 (장 시작 시 리셋)
    ▼
5. Confidence 방향성 검사
    │  confidence 추세 (강화 / 약화) 반영
    ▼
6. Tier 분류 및 라우팅
    │
    ├── Tier 1 → 즉시 발송
    ├── Tier 2 → 즉시 발송 (필터 통과 시)
    └── Tier 3 → 집계 알림 또는 일일 리포트
```

**필터 상태 저장소**

모든 필터 상태는 notifier가 Redis에 저장·관리한다. analyzer는 순수 신호(등급 + confidence)만 발행한다.

| 상태 | Redis Key 패턴 | TTL |
|------|---------------|-----|
| 타이밍 평가 상태 | `filter:timing:{종목코드}` | `EXPIREAT` 장 종료 시각 |
| 히스테리시스 직전 등급 | `filter:hysteresis:{종목코드}` | `EXPIREAT` 장 종료 시각 |
| 확증 카운터 | `filter:confirm:{종목코드}` | `EXPIREAT` 장 종료 시각 |
| 쿨다운 만료 시각 | `filter:cooldown:{종목코드}:{tier}` | 쿨다운 시간 TTL 자동 만료 |
| Confidence 추이 버퍼 | `filter:confidence:{종목코드}` | `EXPIREAT` 장 종료 시각 |

- 장 종료 시 초기화: 모든 필터 키에 `EXPIREAT`로 해당 시장 장 종료 시각을 설정하여 TTL 자연 만료로 처리. 별도 삭제 cron 불필요 (`KEYS` 비활성화 정책과 충돌 없음)
- 모든 Key는 `filter:` 네임스페이스로 관리

### 8.2 히스테리시스

경계 구간에서 신호가 HOLD ↔ BUY/SELL을 반복하는 진동 방지.

- 구체 기준: [TBD] (confidence 상·하한 밴드 방식 또는 연속 유지 횟수 방식 중 결정 필요)

### 8.3 방향 전환 유형별 확증/쿨다운

| 전환 유형 | 예시 | 확증 횟수 | 쿨다운 | 긴급도 |
|-----------|------|-----------|--------|--------|
| 직접 전환 | BUY → SELL | [TBD] (최소) | 없음 | 높음 |
| HOLD 경유 이탈 | BUY → HOLD, HOLD → SELL | [TBD] (중간) | [TBD] (짧음) | 중간 |
| HOLD 이탈 (신규 진입) | HOLD → BUY | [TBD] (최대) | [TBD] (김) | 낮음 |

**Tier별 쿨다운**

| Tier | 조건 | 쿨다운 |
|------|------|--------|
| Tier 1 (STRONG) | 같은 방향 반복 알림만 | [TBD] |
| Tier 2 (방향 전환) | 전환 유형별 비대칭 | 위 표 참조 |
| Tier 3 | 집계 라우팅 | 해당 없음 |

**쿨다운 리셋 조건**: 장 시작 시 모든 쿨다운 초기화

### 8.4 Confidence 방향성 검사

- confidence 값이 연속으로 강화(상승) 중이면 필터 완화
- confidence 값이 약화(하락) 중이면 필터 강화 또는 HOLD 강등
- 구체 임계값: [TBD]

### 8.5 Tier 분류 기준

| Tier | 조건 | 라우팅 |
|------|------|--------|
| Tier 1 | STRONG_BUY 또는 STRONG_SELL + confidence ≥ [TBD] | 즉시 텔레그램 발송 (같은 방향 반복 시 쿨다운 적용, Tier별 쿨다운은 8.3절에서 정의) |
| Tier 2 | 방향 전환 신호 (8.3절 유형) | 즉시 발송 (필터 통과 시) |
| Tier 3 | 나머지 신호 변동 | 집계 알림 또는 일일 리포트 |

---

## 9. 주문 실행 흐름

### 9.1 주문 흐름 7단계

```
1. 트리거
   ├── STRONG 등급 알림의 [매수]/[매도] 인라인 버튼 탭
   └── 텔레그램 명령어 직접 입력 (예: /buy 삼성전자 10)

2. 수량/금액 입력
   └── 사용자가 매번 직접 지정 (시스템 기본값 없음)

3. 주문 확인 메시지 표시 (1차 확인)
   ├── 종목명, 수량, 가격 유형(시장가/지정가), 예상 금액 표시
   └── 인라인 버튼: [확인] / [취소]

4. 사용자 최종 확인 (2차 확인)
   ├── Telegram User ID 화이트리스트 권한 검사
   ├── 주문 요약 재표시 + "최종 실행" 인라인 버튼 (실수 터치 방지)
   └── 확인 대기 만료: 10분 이내 미응답 시 자동 취소
       (만료된 확인 요청의 인라인 버튼은 비활성화)

5. 멱등성 검증
   ├── 콜백 중복 체크 (lock:callback:{callback_query_id}, SET NX)
   ├── 주문 멱등성 키 등록 (idempotency:order:{order_id}, SET NX)
   └── 중복 감지 시: "이미 처리 중" 알림 → 흐름 종료

6. 한도 예약 + KIS API 주문 실행
   ├── Reserve: Lua 스크립트로 주문 금액만큼 일일 한도 원자 예약 → 초과 시 주문 거부 + 알림
   ├── KIS API 주문 실행
   └── Confirm / Cancel: 체결 성공 금액 확정, 미체결 금액 예약 해제

7. 결과 알림
   └── 체결 완료 / 실패 사유 텔레그램 발송
```

### 9.2 주문 안전 한도 (Safety Limits)

| 항목 | 정책 |
|------|------|
| 단일 주문 최대 금액 | [TBD] (환경 변수로 외부화) |
| 일일 총 주문 금액 한도 | [TBD] (환경 변수로 외부화) |

- 일일 주문 한도는 KIS API 제약이 아닌 프로젝트 자체 Safety Limit이며, **Reserve-Confirm-Cancel 패턴**으로 원자 처리:

| 단계 | 시점 | Lua 스크립트 동작 |
|------|------|-------------------|
| Reserve | KIS API 호출 전 | `(confirmed + reserved + 주문금액) ≤ 한도` 검증 → 통과 시 `reserved` 증가 |
| Confirm | KIS API 체결 성공 | `reserved` 감소 + `confirmed` 증가 (체결 금액만큼) |
| Cancel | KIS API 실패 또는 미체결 | `reserved` 감소 (예약 해제) |

- 일일 한도 리셋 시점: 시장 개장 기준 (한국 09:00 KST, 미국 22:30 KST). 자정 리셋 시 한도 2배 우회 가능하므로 개장 기준 적용
- 한도 초과 시: 주문 거부 + 사용자 알림
- 모든 한도는 환경 변수로 관리하며, 기본값을 보수적으로 설정
- Cancel 실패 안전망: Cancel Lua 호출 실패 시 로그 기록 + 시스템 채널 알림. 한도 키 TTL(다음 개장 시각)에 의해 자연 리셋되므로 영구 누수 없음

### 9.3 권한 제어

주문 권한 검사는 **aaa-trader가 단독 수행**한다. aaa-notifier는 화이트리스트 검사를 수행하지 않는다.

**KIS 주문 API 호출 권한 분리**: KIS 주문 API(`POST /uapi/domestic-stock/v1/trading/order-*` 등)는 aaa-trader에서만 호출한다. collector를 포함한 다른 서비스는 주문 관련 API 의존성을 코드에 포함하지 않는다. 앱키는 서비스별 `.env` 파일로 물리 분리되어 있으며(`.env.collector`: 수집 전용, `.env.trader`: 주문 전용), collector 침해 시에도 주문 실행 경로가 차단된다.

| 항목 | 설명 |
|------|------|
| 검사 주체 | aaa-trader |
| 적용 명령 | `/buy`, `/sell` 및 알림 인라인 버튼 탭 이벤트 |
| 화이트리스트 관리 | 환경 변수로 관리 (`.env`), 복수 User ID 지원 |
| 미등록 계정 처리 | 명령 무시 + 시스템 채널 즉시 알림 (User ID 포함) |

- 2차 인증: 도입하지 않음. User ID 화이트리스트 + 봇 토큰 보호(`.env` 권한 600, Git 커밋 방지)로 충분. 토큰 유출 시 즉시 재발급으로 대응
- [TBD - Phase 4 착수 전] 텔레그램 명령 입력값 검증: 종목코드/수량 형식 검사, 음수·비정상 값 거부

---

## 10. 배포 환경

### 10.1 인프라 구성

| 구성 요소 | 장비 | 용도 |
|-----------|------|------|
| 운영 서버 (추론 + 서비스) | UGREEN DXP2800 NAS (Intel N100, 8GB RAM) | 전체 서비스 운영 |
| ML 학습 | MacBook M1 Pro (10코어, 32GB RAM) | 주말 재학습 전용 |
| 모델 공유 스토리지 | NAS NFS/SMB | 학습 결과 → 추론 전달 |

### 10.2 CI/CD 파이프라인

```
GitHub Push
    │
    ▼
GitHub Actions (CI)
    │  빌드 + 테스트
    │  테스트
    │  이미지 푸시 → GHCR (GitHub Container Registry)
    │
    ▼
Watchtower (NAS에서 실행)
    │  GHCR 폴링 → 신규 이미지 감지
    │  자동 컨테이너 업데이트
    │
    ▼
Docker Compose (NAS)
    │  서비스 재시작
    ▼
텔레그램 배포 완료 알림
```

- GHCR 접근 토큰은 최소 권한(`read:packages`)으로 설정

**Docker 이미지 태그 전략**:
- 릴리스 시 GHCR에 3가지 태그 동시 push:
  - `:v1.2.3` — 불변 태그, 롤백 및 감사 기준점
  - `:latest` — Watchtower 폴링 대상 (docker-compose.yml에서 앱 서비스가 사용)
  - `:sha-<commit>` — 트레이서빌리티, 디버깅
- Watchtower는 semver 태그 간 업그레이드를 감지하지 못함 → 앱 서비스는 `:latest` 사용 필수
- 인프라 이미지(MySQL, Redis, Watchtower)는 고정 버전 태그 사용 → Dependabot PR로 관리

**자동 버저닝 (semantic-release)**:
- 커밋 메시지 기반 SemVer 자동 결정: `feat` → minor, `fix` → patch, `!` → major
- Gitmoji + Conventional Commits 하이브리드 형식 지원: `@semantic-release/commit-analyzer`의 커스텀 `headerPattern`으로 `✨ feat(scope): ...` 파싱
- Java 서비스: semantic-release + `gradle-semantic-release-plugin` (`gradle.properties` 버전 자동 업데이트)
- Python 서비스: python-semantic-release + 커스텀 파서 (`pyproject.toml` 버전 자동 업데이트)
- 흐름: main 머지 → semantic-release → Git 태그(v1.2.3) → `on: push: tags` → Docker Buildx → GHCR push → Watchtower 감지

**의존성 자동 업데이트 (Dependabot)**:
- 레포별 `.github/dependabot.yml` 개별 설정 (5개 독립 레포)
- 에코시스템: aaa-infra(`docker-compose` + `github-actions`), Java 서비스(`gradle`), aaa-analyzer(`uv`)
- 스케줄: `weekly`, 레포별 요일 분산으로 PR 집중 방지
- Dependabot Security Updates: 즉시 활성화 (CVE 감지 시 자동 PR)
- 역할 분담: Watchtower = GHCR 빌드 앱 서비스 자동 배포, Dependabot = 인프라 이미지 + 라이브러리 의존성 PR 관리
- ignore 정책 (`docker-compose` 에코시스템):
  - MySQL(`mysql`): 메이저/마이너 업그레이드 ignore → 패치만 자동 PR. 8.4 LTS 고정 정책, 스키마 호환성 검토 후 수동 진행
  - Redis(`redis`): 메이저 업그레이드 ignore → 마이너·패치 자동 PR. Streams API 등 주요 변경 동반 시 수동 검토

### 10.3 Docker Compose 구성

**NAS 운영 환경 서비스 목록**

| 서비스 | 이미지 소스 | 포트 (내부) |
|--------|------------|-------------|
| aaa-collector | GHCR | - |
| aaa-analyzer | GHCR | - |
| aaa-notifier | GHCR | - |
| aaa-trader | GHCR | - |
| mysql | Docker Hub (mysql:8.4) | 3306 |
| redis | Docker Hub (redis:8.6) | 6379 |
| watchtower | GHCR (nicholas-fedor 포크) | - |

**Docker 네트워크**:
- `aaa-network` 네트워크: MySQL, Redis, 전체 애플리케이션 서비스 (collector, analyzer, notifier, trader)
- Watchtower: Docker socket만 접근, `aaa-network` 연결 불필요 (default 네트워크 사용). 포크 선택 배경은 [ADR-004](ADR/ADR-004-watchtower-fork.md) 참조
- MySQL(3306), Redis(6379) 포트는 호스트에 바인딩하지 않음 (`expose`만 사용, `ports` 미사용)
- 서브넷 고정(`172.20.0.0/24`) 이유:
  1. Docker 기본 브리지(`docker0`)는 `172.17.0.0/16`, Compose 자동 할당은 `172.17~19.x.x`부터 시작. `172.20.x.x`로 명시 지정하여 충돌 방지
  2. NAS에서 여러 Docker Compose 스택 공존 시 자동 할당끼리 서브넷이 겹쳐 라우팅이 무음 실패할 수 있음. 고정으로 예측 가능성 확보
  3. 재시작 후에도 서브넷 불변이므로 호스트 방화벽(iptables) 규칙이 깨지지 않음
  - `/24` 선택: 현재 ~7개 컨테이너 대비 254 호스트로 충분. 향후 스택 추가 시 `172.21.0.0/24` 이후 대역 사용

**Watchtower 감시 범위**:
- Opt-in 라벨 모드(`WATCHTOWER_LABEL_ENABLE=true`): `com.centurylinklabs.watchtower.enable: "true"` 라벨이 있는 컨테이너만 감시
- 감시 대상: GHCR에서 빌드되는 애플리케이션 서비스 (collector, analyzer, notifier, trader). 각 서비스 정의 시 라벨 부여 필수
- 감시 제외: MySQL, Redis (Docker Hub 버전 고정 이미지), Watchtower 자체 (`latest` 태그 안정성 우선)
- NAS 멀티 스택 공존 시 다른 스택의 컨테이너가 의도하지 않게 업데이트되는 것을 방지

**서비스별 JVM 메모리 제한 (8GB 기준)**

| 서비스 | `-Xms` | `-Xmx` | `MaxMetaspaceSize` | `MaxDirectMemorySize` | 컨테이너 limit | 비고 |
|--------|--------|--------|--------------------|-----------------------|----------------|------|
| aaa-collector | 128m | 384m | 160m | 64m | 800MB | WebSocket 5세션 + REST 배치 + 백필, 힙 압력 중~높 |
| aaa-analyzer | - | - | - | - | 500MB | Python 프로세스, JVM 없음. ML 모델 8개 상시 적재. **⚠️ Phase 2 착수 전 실측 필요**: LightGBM/XGBoost 모델 로드 + 추론 시 peak RSS 미검증. tracemalloc/memory_profiler로 측정 후 재검토 |
| aaa-notifier | 64m | 192m | 128m | 64m | 600MB | 틱 구독 + 6단계 필터, 재처리 급증 대비 |
| aaa-trader | 64m | 128m | 128m | 32m | 450MB | I/O 위주 극저부하, 동시 주문 사실상 1건 |

**메모리 예산 (Phase 4 전체 운영 기준)**

| 구성 요소 | 예상 RSS |
|-----------|---------|
| OS + Docker 오버헤드 | ~660MB |
| MySQL 8.4 (`innodb_buffer_pool_size=512M`) | ~650MB |
| Redis 8.6 (`maxmemory 128mb`, 컨테이너 limit 256M) | ~256MB |
| aaa-collector | ~800MB |
| aaa-analyzer | ~500MB |
| aaa-notifier | ~600MB |
| aaa-trader | ~450MB |
| Watchtower | ~128MB |
| **합계** | **~4,044MB (49%)** |
| **여유** | **~4,148MB (51%)** |

Redis 컨테이너 limit = `maxmemory` × 2: AOF rewrite 시 `fork()` → Copy-on-Write로 최악의 경우 데이터 메모리의 2배 소비. fragmentation, output buffer 오버헤드 포함.

배분 순서: (1) OS/DB 오버헤드 확보 → (2) 서비스별 JVM 힙 배분 → (3) 나머지를 ML 추론 캐시(6.2절)에 할당. GC는 G1GC(Java 21 기본값) 사용.

**컨테이너 헬스체크**:
- 모든 서비스 컨테이너에 `healthcheck` 설정 (Spring Boot: `/actuator/health`, FastAPI: `/health`)
- 헬스체크 실패 시 `restart: unless-stopped` 정책으로 자동 재시작
- 역할: 인프라 계층 감시 (컨테이너 크래시, JVM 무응답 자동 복구)
- [TBD - Phase 1 구현 시] Spring Boot Actuator는 `health`만 노출 (`management.endpoints.web.exposure.include=health`), FastAPI `/docs`·`/redoc`는 프로덕션 비활성화

### 10.4 모니터링 전략

| Phase | 방법 | 이유 |
|-------|------|------|
| Phase 1~2 | Redis 카운터 | notifier 미구현으로 텔레그램 미지원 |
| Phase 3~4 | Redis 카운터 + 텔레그램 일일 리포트 | notifier 구현 후 발송 가능 |

**일일 리포트 포함 항목 (Phase 1~2)**:
- 수집 누락률 (Redis 카운터 기반)
- 수집 지연 p95
- Fallback 전환 내역 및 횟수
- 자동 복구 횟수 요약
- ML 신호 생성 건수 및 등급 분포

**실시간 수집 상태 감시 (Phase 1)**:
- 수집 정상 여부를 Redis 카운터(마지막 수집 타임스탬프 또는 분당 수집 건수)로 추적
- 장중 [TBD]분 이상 수집 건수가 0이면 시스템봇으로 즉시 알림
- 구현 방식: `@Scheduled` cron으로 주기적 카운터 점검 (별도 Watchdog 프로세스 불필요)
- 역할: 비즈니스 계층 감시 (프로세스는 정상이나 수집이 멈춘 침묵 장애 감지)

### 10.5 자원 모니터링 임계값 (NAS)

| 자원 | 1단계 경고 | 2단계 경고 | 3단계 (위험) |
|------|-----------|-----------|------------|
| 디스크 사용률 | 70% | 80% | 90% |
| RAM 사용률 | 70% | 80% | 90% |
| CPU 사용률 (5분 이동평균) | 70% | 85% | 90% |

- **디스크**: SSD write amplification 80% 초과 시 심화. 90% 초과 시 MySQL 쓰기 실패 위험
- **CPU**: 순간 스파이크(배치+추론 겹침)는 정상. 5분 이동평균 기준으로 지속 고부하만 감지

### 10.6 데이터 백업 정책

| 항목 | 정책 |
|------|------|
| 대상 | MySQL 전체 데이터베이스 |
| 방식 | mysqldump (`--single-transaction`) + binlog PITR |
| 실행 주기 | 주 1회 (일요일 03:00 KST) |
| 보관 기간 | 4주치 (4개 파일, 이후 자동 삭제) |
| 저장 위치 | [TBD] (NAS 로컬 경로 또는 외부 스토리지). 백업 파일 권한: `chmod 600` |
| 실패 시 처리 | 시스템 채널(텔레그램) 즉시 알림 |

**binlog 설정**:
- `binlog_expire_logs_seconds`: 2592000 (30일, MySQL 8.4 기본값)
- `max_binlog_size`: 1GB (기본값)
- 복구 방법: mysqldump 복원 후 해당 시점 이후 binlog를 `mysqlbinlog`로 재실행 (PITR)

---

## 11. 성능 지표 측정

### 11.1 Phase별 핵심 지표

> 목표 수치는 [PRD 3절](PRD.md#3-성공-지표-success-metrics) 참조. 이 절은 측정 방법만 정의한다.

**Phase 1 (Collector)**

| 지표 | 측정 방법 |
|------|-----------|
| 수집 누락률 | Redis 카운터: 예상 수집 건수 vs 실제 수집 건수 |
| 수집 지연 | 체결 시간 vs Redis 적재 시간 차이 기록 |
| Fallback 동작 | Fallback 전환 시 Redis 카운터 증가 |

**Phase 2 (Analyzer)**

| 지표 | 측정 방법 |
|------|-----------|
| 등급 확정 지연 | 일봉 수집 완료 이벤트 → 전 종목 등급 확정 시간 차이 |
| 방향 적중률 | 예측 방향 vs 실제 N일 후 방향 비교 |
| Precision | TP / (TP + FP), 매수/매도 방향별 각각 산출 |
| 샤프 비율 | 모델 기반 전략 샤프 비율 vs 단순 매수보유 샤프 비율 비교 (백테스트) |

**Phase 3 (Notifier)**

| 지표 | 측정 방법 |
|------|-----------|
| STRONG 알림 지연 | 신호 수신 → 텔레그램 발송 시간 차이 |
| 필터 오작동 | 차단했어야 할 알림 통과 건수 수동 검증 |
| 일일 리포트 발송 | 발송 성공 로그 |

**Phase 4 (Trader)**

| 지표 | 측정 방법 |
|------|-----------|
| 주문 처리 지연 | 텔레그램 명령 수신 → KIS API 호출 시간 차이 |
| 주문 실패 알림 | 실패 이벤트 → 알림 발송 로그 |

### 11.2 측정 인프라

**Phase 1~2: Redis 카운터 방식**

```
카운터 Key: 5.3절 Redis 카운터 Key 패턴 참조
저장소:     Redis (일별 Key, 자동 만료)
흐름:       이벤트 발생 → 해당 Key increment → 일일 리포트 시 조회 → 텔레그램 발송
```

---

## 12. 보안

이 절은 각 절에 분산된 보안 관련 설계를 한 곳에서 참조하기 위한 인덱스다.

| 영역 | 참조 위치 | 핵심 내용 |
|------|-----------|-----------|
| 로그 마스킹 | 2.3절 공통 규칙 | 민감 정보 종류별 마스킹 처리 후 출력 |
| 시크릿 관리 | 3.8절 시크릿 보호 | `.env` 공통+서비스별 분리, chmod 600, pre-commit hook, `.env.example` 혼합형 관리 |
| MySQL 접근 | 4절 접근 보안 | 서비스별 전용 사용자, INSERT-ONLY 감사 로그, root 원격 접속 금지 |
| Redis 접근 | 5절 접근 보안 | ACL 기반 인증(aclfile), 위험 명령어 차단(-@dangerous), 호스트 바인딩 금지 |
| SSH 접근 | 6.2절 SSH 보안 최소 조치 | 공개키 인증만 허용, Ed25519, passphrase 설정 |
| 모델 파일 | 6.2절 모델 파일 관리 | 네이티브 포맷만 사용, 역직렬화 위험 포맷 금지 |
| 주문 안전 한도 | 9.2절 Safety Limits | 단일 주문 최대 금액, 일일 총 주문 한도 |
| 주문 권한 | 9.3절 권한 제어 | Telegram User ID 화이트리스트, trader 단독 검사 |
| Docker 네트워크 | 10.3절 Docker 네트워크 | aaa-network 분리, DB/Redis 호스트 바인딩 금지 |
| Actuator 노출 | 10.3절 헬스체크 | health만 노출, Swagger UI 프로덕션 비활성화 |

**Phase별 보안 [TBD] 항목**:

| Phase | 참조 위치 | 내용 |
|-------|-----------|------|
| Phase 1 | 10.3절 | Actuator 엔드포인트 제한, FastAPI docs 비활성화 |
| Phase 2 | 6.2절 | MacBook → NAS 접속 보안 (학습 전용 사용자, TLS/SSH 터널) |
| Phase 3 | 1.4절 | 봇 토큰 유출 시 대응 절차 |
| Phase 4 | 9.3절 | 2차 인증 메커니즘, 명령 입력값 검증 |


---

*최종 업데이트: 2026-03-02*
