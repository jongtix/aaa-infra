# MILESTONE: AAA (Algorithmic Alpha Advisor)

> 최초 작성: 2026-02-24
>
> **상위 문서**: [PRD.md](PRD.md), [TECHSPEC.md](TECHSPEC.md)
>
> 이 문서는 Phase별 마일스톤과 완료 기준을 정의한다. 날짜 예측 없이 순서와 의존성만 표현한다.
> 상세 내용은 PRD/TECHSPEC 링크로 대체한다.

---

## 전체 Phase 개요

```
Phase 0 (인프라 공통)
    │
    ▼
Phase 1 (aaa-collector: 데이터 수집)
    │
    ▼
Phase 2 (aaa-analyzer: ML 분석)
    │
    ▼
Phase 3 (aaa-notifier: 알림)
    │
    ▼
Phase 4 (aaa-trader: 반자동 주문)
```

각 Phase는 이전 Phase 완료 후 착수한다. Phase 0은 모든 Phase의 전제 조건이다.

---

## Phase 0: 인프라 공통 (aaa-infra)

모든 Phase의 전제가 되는 공통 인프라를 구성한다.

### 0-1. Docker Compose 기본 구성

- `docker-compose.yml` 작성 — MySQL 8.4, Redis 8.4, Watchtower 포함
- Docker 네트워크 `aaa-network` 구성 — 애플리케이션 서비스 격리 ([TECHSPEC 10.3절](TECHSPEC.md#103-docker-compose-구성))
- MySQL/Redis 포트 호스트 바인딩 금지 (`expose`만 사용)
- `restart: unless-stopped` 정책 전 서비스 적용

### 0-2. 환경 변수 및 시크릿 관리

- `aaa-infra/.env.example` 작성 — 인프라 공통 변수만 포함 (`.env`, `.env.mysql`, `.env.redis`, `.env.common`) ([ADR-006](ADR/ADR-006-env-example-management-strategy.md))
- 서비스 전용 변수 (`.env.collector`, `.env.analyzer`, `.env.notifier`, `.env.trader`)는 각 서비스 레포 `.env.example`로 분리 관리 — 해당 Phase 착수 시 작성 ([ADR-006](ADR/ADR-006-env-example-management-strategy.md))
- `.gitignore`에 `.env*` 패턴 등록 (`.env.example` 예외)
- pre-commit hook 설정 — `.env*` 파일 커밋 방지 이중 차단
- 모든 `.env.*` 파일 `chmod 600` 적용

### 0-3. MySQL 초기화

- `my.cnf` 템플릿 작성 — NAS 환경 메모리 설정 ([TECHSPEC 4절](TECHSPEC.md#4-db-스키마))
- `initdb.d/*.sql` 템플릿 작성 — 서비스별 전용 사용자 생성 + 최소 권한 원칙
- MySQL 서비스별 전용 사용자 생성 + 최소 권한 원칙 ([TECHSPEC 4절](TECHSPEC.md#4-db-스키마))
- root 계정 원격 접속 금지 설정

### 0-4. Redis 초기화

- `redis.conf` 템플릿 작성 — `maxmemory`, AOF, RDB 비활성화 ([TECHSPEC 5절](TECHSPEC.md#5-redis-설계))
- `users.acl` 템플릿 작성 — `default` 비활성화, `admin`, `appuser` 권한 정의
- ACL 기반 인증 (`aclfile`) — `default` 유저 비활성화, `admin` 유저(healthcheck·관리용), `appuser`에 `-@dangerous` 적용 ([TECHSPEC 5절](TECHSPEC.md#5-redis-설계))

### 0-5. CI/CD 파이프라인

- ~GitHub Actions 워크플로우 작성 — Docker 이미지 빌드~ → Phase 1 이월 (빌드 대상 앱 서비스 없음) ([TECHSPEC 10.2절](TECHSPEC.md#102-cicd-파이프라인))
- ~GHCR(GitHub Container Registry) 이미지 푸시 설정~ → Phase 1 이월 (빌드 대상 앱 서비스 없음)
- Watchtower GHCR 폴링 설정 — 자동 컨테이너 업데이트 (opt-in 라벨 모드)
- Dependabot 설정 — `docker-compose` + `github-actions` 에코시스템 ([TECHSPEC 10.2절](TECHSPEC.md#102-cicd-파이프라인))
- Docker 이미지 태그 전략 수립 — semver + latest + sha 동시 push

### 완료 기준 (Phase 0)

- Docker Compose `up` 시 MySQL, Redis, Watchtower 정상 기동
- `.env.*` 파일이 git 커밋에 포함되지 않음을 pre-commit hook으로 검증
- ~GitHub Push → GHCR 이미지 빌드 → Watchtower 자동 업데이트 흐름 동작 확인~ → Phase 1 완료 기준으로 이동

---

## Phase 1: aaa-collector (데이터 수집)

> **전제**: Phase 0 완료

[PRD 2절 목표](PRD.md#2-목표-goals), [PRD 7절 데이터 수집 범위](PRD.md#7-데이터-수집-범위) 구현.

### 1-1. 프로젝트 기반 설정

- Spring Boot 3.5.11, Java 21 Virtual Threads, Gradle Kotlin DSL 초기 설정
- KST 시간대 통일 설정 ([TECHSPEC 2.3절](TECHSPEC.md#23-공통-규칙))
- 구조화 로그(JSON) + 민감 정보 마스킹 설정 ([TECHSPEC 2.3절](TECHSPEC.md#23-공통-규칙))
- Trace ID 생성 및 로그 포함 ([TECHSPEC 2.3절](TECHSPEC.md#23-공통-규칙))
- Spring Boot Actuator `health`만 노출 — Swagger UI 프로덕션 비활성화 ([TECHSPEC 10.3절](TECHSPEC.md#103-docker-compose-구성), [TECHSPEC 12절](TECHSPEC.md#12-보안))
- 컨테이너 `healthcheck` 설정 (`/actuator/health`)

### 1-2. KIS API 토큰 관리

- 앱키 5개 독립 토큰 발급 및 Redis 저장 구현 ([TECHSPEC 3.8절](TECHSPEC.md#38-kis-api-토큰-관리))
- 스케줄 갱신: 매일 장 시작 전 `@Scheduled` cron으로 일괄 발급
- Lazy 갱신: 401 응답 시 즉시 재발급 후 재시도
- 갱신 실패 처리: 최대 3회 재시도 → 실패 시 안전 모드 진입 + 로그 기록 (텔레그램 알림은 Phase 3 이후)

### 1-3. DB 스키마 (Phase 1)

구현 시점에 필요한 테이블부터 순차 진행.

- KIS API 실제 응답 데이터 확인 후 스키마 설계
- 종목 마스터 테이블 설계 및 생성: `stocks`, `stock_grades` ([TECHSPEC 4절](TECHSPEC.md#4-db-스키마))
- 가격 데이터 테이블: `daily_ohlcv` (주식/ETF/지수 포함, `asset_type` ENUM) ([TECHSPEC 4절](TECHSPEC.md#4-db-스키마))
- 시장 지표 테이블: `market_indicators` (환율, VIX)
- 해외선물 테이블: `futures_daily`
- 시간외 데이터 테이블: `extended_hours` (Pre/After-Hours, `session` ENUM)
- 수급 데이터 테이블: `investor_trend`, `short_sale`, `credit_balance`
- 거시경제 테이블: `macro_indicators` (금리종합, 증시자금종합 포함)
- 재무제표 테이블: `financials`
- 뉴스 테이블: `news_headlines`
- 공시 테이블: `disclosures`
- 기업 이벤트 테이블: `corporate_events`
- 투자의견 테이블: `analyst_estimates`
- 모든 시간 컬럼 `DATETIME` 사용 (`TIMESTAMP` 금지)
- Unique Key 설정 (종목코드 + 타임스탬프) — 중복 INSERT 방지 ([TECHSPEC 5.1절](TECHSPEC.md#51-redis-streams-서비스-간-이벤트-버스))

### 1-4. 관심 종목 동기화

- 장 시작 전 KIS API → DB 동기화 구현 — 1일 2회(07:30, 15:45 KST) ([TECHSPEC 3.6절](TECHSPEC.md#36-데이터-보관-정책))
- 동기화 실패 시 직전 DB 목록 유지 + 로그 기록 (텔레그램 알림은 Phase 3 이후)
- 종목 등급 자동 분류 로직 (A/B/C/F) ([TECHSPEC 6.5절](TECHSPEC.md#65-종목-등급-분류-로직), [PRD 6.2절](PRD.md#62-ml-매매-신호-생성-대상))
- 중복 ETF 대표 선정 알고리즘 구현 ([TECHSPEC 6.5절](TECHSPEC.md#65-종목-등급-분류-로직))
- Redis 캐싱: `cache:stock:list`, `cache:grade:{종목코드}` ([TECHSPEC 5.2절](TECHSPEC.md#52-redis-캐싱))

### 1-5. KIS WebSocket 실시간 수집

- 국내 체결 (`H0STCNT0`), 호가 (`H0STASP0`) 구독 ([TECHSPEC 3.2절](TECHSPEC.md#32-kis-api-국내-수집-상세))
- 해외 체결, 호가(Level 1), VIX 선물 실시간 구독 ([TECHSPEC 3.3절](TECHSPEC.md#33-kis-api-해외-수집-상세))
- 5세션 × 41건 = 205건 구독 상한 관리 ([TECHSPEC 3.1절](TECHSPEC.md#31-kis-api-제약-및-수용-설계))
- 틱 → Redis Streams (`stream:tick:domestic/overseas`) 발행 (notifier 타이밍 평가용, `symbol` 필드 포함). Phase 1~2 중 Consumer(notifier) 미존재 — 발행만 수행, MAXLEN으로 메모리 제어 ([TECHSPEC 5.1절](TECHSPEC.md#51-redis-streams-서비스-간-이벤트-버스))
- WebSocket 재연결 로직 + 안전 모드 진입 기준 구현 ([TECHSPEC 1.3절](TECHSPEC.md#13-안전-모드-safe-mode))
- Trace ID Redis Streams 헤더 전파 ([TECHSPEC 2.3절](TECHSPEC.md#23-공통-규칙))

### 1-6. KIS REST 배치 수집

- 국내 배치: OHLCV 일봉, 투자자별 매매동향, 공매도, 신용잔고, 재무제표, 업종지수, 금리, 증시자금, 배당/증자, 투자의견, 뉴스 제목 ([TECHSPEC 3.2절](TECHSPEC.md#32-kis-api-국내-수집-상세))
- 해외 배치: OHLCV, 해외선물, 배당/권리, 뉴스 제목 ([TECHSPEC 3.3절](TECHSPEC.md#33-kis-api-해외-수집-상세))
- Rate Limit 준수: 초당 20건/계좌 × 5계좌 = 100건 ([TECHSPEC 3.1절](TECHSPEC.md#31-kis-api-제약-및-수용-설계))
- `@Scheduled` cron 표현식만 사용 (`fixedDelay` 금지)
- 일봉 수집 완료 시 `stream:daily:complete` 이벤트 발행 (`market` 필드: `domestic` / `overseas`) ([TECHSPEC 5.1절](TECHSPEC.md#51-redis-streams-서비스-간-이벤트-버스))
- 과거 데이터 백필: 일봉 OHLCV, 수급 데이터를 종목별 최대 과거까지 수집 ([TECHSPEC 3.9절](TECHSPEC.md#39-과거-데이터-백필-전략))
- `backfill_status` 테이블 관리: (대상, 데이터 테이블) 단위로 백필 상태 추적, 미완료 항목 대상 하루 1회 스케줄 실행 ([TECHSPEC 3.9절](TECHSPEC.md#39-과거-데이터-백필-전략))
- 외부 API 응답 검증: null/0 이하/극단값 필터 적용, 검증 실패 건 저장 제외 + 로그 기록 ([TECHSPEC 2.3절](TECHSPEC.md#23-공통-규칙))

### 1-7. 외부 API 수집

- 환율 USDKRW 일봉 Fallback 체인: 한국수출입은행 → ECOS → yfinance ([TECHSPEC 3.4절](TECHSPEC.md#34-외부-api-fallback-체인))
- VIX 일봉 Fallback 체인: CBOE CDN → FRED → yfinance
- Pre/After-Hours 1분봉: yfinance → Alpaca → Polygon.io (스냅샷 2~3회/일) ([TECHSPEC 3.7절](TECHSPEC.md#37-시간외-데이터-수집-정책))
- FINRA Daily Short Volume, FINRA Short Interest 수집 ([TECHSPEC 3.5절](TECHSPEC.md#35-단일-소스-외부-api))
- DART OpenAPI 공시 폴링 (분당 1000회 제한)
- 한국은행 ECOS: 기준금리, CPI, GDP, 경상수지
- FRED API: GDP, CPI, DFF, UNRATE, DGS10, VIXCLS (120 req/min)
- Fallback 전환 시 Redis 카운터 기록 ([TECHSPEC 5.3절](TECHSPEC.md#53-redis-카운터-phase-12-성능-지표))
- 거시경제/환율/VIX 과거 데이터 백필: 각 API 제공 범위 내 최대 과거까지 수집 ([TECHSPEC 3.9절](TECHSPEC.md#39-과거-데이터-백필-전략))

### 1-8. 장애 감지 및 시스템 알림

- 수집 정상 여부 Redis 카운터 추적 (마지막 수집 타임스탬프 또는 분당 수집 건수) ([TECHSPEC 10.4절](TECHSPEC.md#104-모니터링-전략))
- 장중 일정 시간 이상 수집 건수 0 → 로그 기록 (텔레그램 알림은 Phase 3 이후)
- 수집 누락률, 수집 지연 p95 Redis 카운터 기록 ([TECHSPEC 5.3절](TECHSPEC.md#53-redis-카운터-phase-12-성능-지표))
- `stream:system:collector` 장애 이벤트 발행 ([TECHSPEC 5.1절](TECHSPEC.md#51-redis-streams-서비스-간-이벤트-버스))
- NAS 자원 모니터링 (디스크/RAM/CPU) + 3단계 임계치 알림 ([TECHSPEC 10.5절](TECHSPEC.md#105-자원-모니터링-임계값-nas), [PRD 10.5절](PRD.md#105-자원-모니터링))

### 완료 기준 (Phase 1)

[PRD 3절 Phase 1 성공 지표](PRD.md#3-성공-지표-success-metrics) 충족:

- GitHub Push → GHCR 이미지 빌드 → Watchtower 자동 업데이트 흐름 동작 확인 (Phase 0에서 이월)
- 수집 누락률 < 1% (장중 기준)
- 데이터 파이프라인 장애 시 자동 복구 (Fallback 체인 동작 확인)
- 수집 지연 < 5초 (실시간 체결 기준)
- 일봉 수집 완료 이벤트가 `stream:daily:complete`에 `market` 필드(`domestic`/`overseas`) 포함하여 정상 발행됨을 확인
- 일일 리포트 항목 (수집 누락률, 지연 p95, Fallback 내역, 자동 복구 횟수) 데이터 산출 확인 (텔레그램 발송은 Phase 3)
- 모든 관심 종목의 과거 데이터 백필 완료 (`backfill_status` 전 항목 완료 확인)
- 관심 종목 일봉 수익률 분포 확인 — TECHSPEC 6.1절 초안 경계값의 클래스 비율이 극단적으로 편향되지 않음을 확인 (정밀 조정은 Phase 2)
- 종목 등급 자동 분류 검증 완료 — A/B/C/F 등급 분류 결과를 TECHSPEC 6.5절 기준과 대조하여 오분류 없음 확인

---

## Phase 2: aaa-analyzer (ML 분석)

> **전제**: Phase 1 완료. 일봉 데이터가 MySQL에 안정적으로 적재되고, `stream:daily:complete` 이벤트가 정상 발행되는 상태
>
> **리소스 점검**: `docker stats`로 Phase 1 운영 중 메모리 사용량 측정 → 추가 서비스 수용 가능 여부 확인. 부족 시 RAM 증설 후 진행

[PRD 2절 목표](PRD.md#2-목표-goals), [PRD 12절 ML 전략](PRD.md#12-ml-전략), [TECHSPEC 6절](TECHSPEC.md#6-ml-파이프라인), [TECHSPEC 7절](TECHSPEC.md#7-피처-엔지니어링) 구현.

### 2-1. 프로젝트 기반 설정

- Python 3.14, FastAPI, uv 초기 설정
- KST 시간대 통일 설정 ([TECHSPEC 2.3절](TECHSPEC.md#23-공통-규칙))
- 구조화 로그(JSON) + 민감 정보 마스킹
- Trace ID 수신 및 전파 ([TECHSPEC 2.3절](TECHSPEC.md#23-공통-규칙))
- FastAPI `/health` 엔드포인트 구현 — `/docs`, `/redoc` 프로덕션 비활성화 ([TECHSPEC 12절](TECHSPEC.md#12-보안))
- 컨테이너 `healthcheck` 설정

### 2-2. DB 스키마 (Phase 2)

- ML 신호 테이블: `trading_signals` ([TECHSPEC 4절](TECHSPEC.md#4-db-스키마))

### 2-3. 피처 파이프라인

- 기술적 지표 피처 계산 (이동평균, RSI, MACD, 볼린저밴드, ATR 등) ([TECHSPEC 7.2절](TECHSPEC.md#72-기술적-지표-피처))
- 수급 피처: 투자자별 매매동향, 공매도 피처(`SVR`, `SVR_ma5`, `SVR_zscore` 등) ([TECHSPEC 7.3절](TECHSPEC.md#73-수급-피처))
- FINRA Short Interest LOCF(Last Observation Carried Forward) 일별 확장
- 거시경제 피처: ECOS, FRED, KIS 금리 ([TECHSPEC 7.4절](TECHSPEC.md#74-거시경제-피처))
- 뉴스 피처 (NLP 없이): `news_count_daily`, `news_volume_zscore`, `news_spike_flag`, 키워드 이벤트 플래그 ([TECHSPEC 7.5절](TECHSPEC.md#75-뉴스-피처))
- 종목 속성 피처 설계: 시가총액, 업종, 베타, 상장 기간 등 (풀링 모델 구분용) ([TECHSPEC 7.1절](TECHSPEC.md#71-피처-카테고리-개요))
- 시간외 갭/거래량 피처: Pre/After-Hours 갭 방향/크기, 거래량 이상치 ([TECHSPEC 7.1절](TECHSPEC.md#71-피처-카테고리-개요))
- Look-Ahead Bias 방지 — Strict Causality 원칙 준수 ([TECHSPEC 6.1절](TECHSPEC.md#61-모델-구조))

### 2-4. 레이블 설계

- 5클래스 레이블 경계값 검증: TECHSPEC 6.1절 초안 경계값을 실 데이터 수익률 분포와 대조, 필요 시 조정 ([TECHSPEC 6.1절](TECHSPEC.md#61-모델-구조), [PRD 8.1절](PRD.md#81-신호-등급))
- 클래스 불균형 처리 (SMOTE 또는 가중치 조정)
- 조정 종가 사용 여부 결정 (배당락·주식분할 처리)

### 2-5. 모델 학습 (MacBook)

- MacBook → NAS MySQL 접속 보안 설정: 학습 전용 사용자(SELECT만), TLS/SSH 터널 ([TECHSPEC 6.2절](TECHSPEC.md#62-학습-인프라), [TECHSPEC 12절](TECHSPEC.md#12-보안))
- SSH 보안 최소 조치: 비밀번호 인증 비활성화, Ed25519 키 + passphrase 설정 ([TECHSPEC 6.2절](TECHSPEC.md#62-학습-인프라))
- LightGBM + XGBoost 풀링 모델 구현 — 시장별(국내/해외) 전 종목 통합 학습 (총 8개 모델), 종목 속성 피처 포함 ([TECHSPEC 6.1절](TECHSPEC.md#61-모델-구조))
- Walk-Forward Validation 구현 ([TECHSPEC 6.3절](TECHSPEC.md#63-재학습-정책))
- Optuna 하이퍼파라미터 튜닝 통합
- 앙상블 조합 규칙 구현 (방향 일치 → 합의, 불일치 → HOLD 강등) ([TECHSPEC 6.1절](TECHSPEC.md#61-모델-구조))
- 모델 파일 저장: LightGBM/XGBoost 네이티브 포맷(`.txt`, `.json`, `.ubj`)만 사용 ([TECHSPEC 6.2절](TECHSPEC.md#62-학습-인프라))
- 모델 파일 경로: `models/{시장}/{시간대}/{알고리즘}/`
- 학습 자동화 흐름: analyzer APScheduler cron → WoL(3회 재시도) → SSH 접속(대기+재시도) → 학습 실행(타임아웃 적용) → NFS/SMB 저장 → SSH 종료로 완료 인지 → `stream:system:analyzer` 이벤트 발행. 실패 시 직전 모델 유지 + 알림 ([TECHSPEC 6.2절](TECHSPEC.md#62-학습-인프라))
- 모델 파일 무결성 검증: SHA-256 해시 생성 + 로드 전 검증 ([TECHSPEC 6.2절](TECHSPEC.md#62-학습-인프라))
- 초기 백테스트 수행 → 방향 적중률, Precision, 샤프 비율 기준값 확정 → PRD 3절 기준 업데이트 ([TECHSPEC 6.4절](TECHSPEC.md#64-성능-모니터링))

### 2-6. 추론 서버 (NAS)

- `stream:daily:complete` 이벤트 구독 — `market` 필드에 따라 해당 시장 모델만 배치 추론 트리거 ([TECHSPEC 5.1절](TECHSPEC.md#51-redis-streams-서비스-간-이벤트-버스))
- 모델 Lazy Load: `market` 필드에 따라 해당 시장 4개 모델만 로드 → 추론 → 언로드 ([TECHSPEC 6.2절](TECHSPEC.md#62-학습-인프라))
- 장 마감 후 배치 추론 — 시장별 4개 모델 × 해당 시장 전 종목 일괄 predict (실시간 추론 없음, Throttling 불필요) ([TECHSPEC 6.2절](TECHSPEC.md#62-학습-인프라))
- 추론 결과 MySQL `trading_signals` 저장
- 매매 신호 발행: `stream:signal:domestic/overseas` → notifier Consumer Group (`symbol` 필드 포함) ([TECHSPEC 5.1절](TECHSPEC.md#51-redis-streams-서비스-간-이벤트-버스))

### 2-7. 체제 감지 및 성능 모니터링

- 체제 감지 구현: VIX / 국채 금리 급변 시 신호 자동 억제 (HOLD 강제) ([TECHSPEC 6.4절](TECHSPEC.md#64-성능-모니터링))
- 체제 감지 발동/해제 시 `stream:system:analyzer` 이벤트 발행 (텔레그램 알림은 Phase 3 이후)
- 등급 확정 지연 측정 (일봉 수집 완료 → 전 종목 등급 확정 시간 차이) ([TECHSPEC 11.1절](TECHSPEC.md#111-phase별-핵심-지표))
- `stream:system:analyzer` 장애 이벤트 발행
- 주간 재학습 스케줄 설정 (주말 APScheduler cron)
- 성능 저하 알림 조건 확정 및 구현

### 2-8. 뉴스 감성 분석 (선택, Phase 2 중 결정)

- 네이버 뉴스 검색 API 도입 여부 결정 ([PRD 7.4절](PRD.md#74-기타-외부-api))
- 도입 결정 시: KB-BERT/KB-ALBERT (한국), FinBERT (미국) 통합
- GDELT 도입 여부 결정

### 완료 기준 (Phase 2)

[PRD 3절 Phase 2 성공 지표](PRD.md#3-성공-지표-success-metrics) 충족:

- 장 마감 후 전 종목 등급 확정 < [TBD]분 (일봉 수집 완료 후, Phase 2 중 실측 후 확정)
- 백테스트 기준 단순 매수·보유 전략 대비 샤프 비율 향상 확인
- 신호 정확도(Precision) — 초기 백테스트 후 기준 확정 및 달성 확인
- `stream:signal:domestic/overseas`에 등급 + confidence가 정상 발행됨을 확인

---

## Phase 3: aaa-notifier (알림)

> **전제**: Phase 2 완료. `stream:signal:domestic/overseas` 이벤트 안정적으로 수신 가능한 상태
>
> **리소스 점검**: `docker stats`로 Phase 1+2 운영 중 메모리 사용량 측정 → 추가 서비스 수용 가능 여부 확인. 부족 시 RAM 증설 후 진행

[PRD 9절 알림 전략](PRD.md#9-알림-전략), [PRD 10절 장애/복구 전략](PRD.md#10-장애복구-전략) 구현.

### 3-1. 프로젝트 기반 설정

- Spring Boot 3.5.11, Java 21 Virtual Threads, Gradle Kotlin DSL 초기 설정
- KST 시간대 통일 설정
- 구조화 로그(JSON) + 민감 정보 마스킹
- Trace ID 수신 및 전파
- Spring Boot Actuator `health`만 노출 + 컨테이너 `healthcheck` 설정

### 3-2. DB 스키마 (Phase 3)

- 알림 이력 테이블: `notification_log` (INSERT-ONLY) ([TECHSPEC 4절](TECHSPEC.md#4-db-스키마))

### 3-3. 텔레그램 봇 설정

- 매매봇, 시스템봇 독립 토큰으로 분리 운영 ([TECHSPEC 1.4절](TECHSPEC.md#14-텔레그램-채널-아키텍처), [PRD 9.3절](PRD.md#93-알림-채널))
- 봇 토큰 유출 시 대응 절차 문서화 (BotFather 재발급 → 환경 변수 교체 → 서비스 재시작) ([TECHSPEC 12절](TECHSPEC.md#12-보안))

### 3-4. 알림 필터 파이프라인

- 히스테리시스 필터 구현 — 경계 신호 진동 제거 ([TECHSPEC 8.2절](TECHSPEC.md#82-히스테리시스))
- 확증 카운터 구현 — 방향 전환 유형별 확증 횟수 비대칭 ([TECHSPEC 8.3절](TECHSPEC.md#83-방향-전환-유형별-확증쿨다운))
- 쿨다운 구현 — 장 시작 시 리셋, Tier별 비대칭 ([TECHSPEC 8.3절](TECHSPEC.md#83-방향-전환-유형별-확증쿨다운))
- Confidence 방향성 검사 구현 — 강화/약화 추세 반영 ([TECHSPEC 8.4절](TECHSPEC.md#84-confidence-방향성-검사))
- Tier 분류 및 라우팅 ([TECHSPEC 8.5절](TECHSPEC.md#85-tier-분류-기준), [PRD 9.1절](PRD.md#91-알림-tier))
- 필터 상태 Redis 저장 (`filter:hysteresis:*`, `filter:confirm:*`, `filter:cooldown:*`, `filter:confidence:*`, `filter:timing:*`) ([TECHSPEC 8.1절](TECHSPEC.md#81-파이프라인-6단계))
- 필터 상태 TTL 관리: 모든 필터 키에 `EXPIREAT` 장 종료 시각 설정, TTL 자연 만료로 초기화 ([TECHSPEC 8.1절](TECHSPEC.md#81-파이프라인-6단계))
- 타이밍 평가 규칙 엔진 구현 — BUY/SELL 종목 대상, `stream:tick:domestic/overseas` 구독, `symbol` 필드로 종목 식별 후 조건 평가 ([TECHSPEC 8.1절](TECHSPEC.md#81-파이프라인-6단계))
- 타이밍 평가 상태 Redis 저장 (`filter:timing:{종목코드}`)

### 3-5. 알림 발송

- Tier 1 즉시 발송 (STRONG_BUY/STRONG_SELL + confidence 임계값)
- Tier 2 즉시 발송 (방향 전환 필터 통과 시)
- Tier 3 집계 알림 또는 일일 리포트 라우팅
- 시간외 이벤트 알림: 갭/비정상 거래량 주의 환기 발송 ([TECHSPEC 3.7절](TECHSPEC.md#37-시간외-데이터-수집-정책), [PRD 9.4절](PRD.md#94-시간외-알림-정책))
- 매수 타이밍 알림: "삼성전자 매수 추천 52,100원 (Buy 전환, 전일 종가 -1.2%)"
- 매도 타이밍 알림: "카카오 매도 추천 41,300원 (Sell 전환)"
- 알림 이력 `notification_log` INSERT
- Trace ID Redis Streams 헤더 전파

### 3-6. 일일 리포트

- 매매 신호 건수 및 등급 분포 포함 ([TECHSPEC 10.4절](TECHSPEC.md#104-모니터링-전략))
- 수집 누락률, 지연 p95, Fallback 내역, 자동 복구 횟수 요약
- Tier 3 집계 신호 요약 포함
- `@Scheduled` cron 정시 발송

### 3-7. 텔레그램 장애 큐잉

- 텔레그램 장애 시 Redis List(`queue:telegram:pending`) 큐잉 ([TECHSPEC 1.3절](TECHSPEC.md#13-안전-모드-safe-mode))
- 보존 기간 최대 24시간 (자동 삭제)
- 복구 후 FIFO 요약 메시지 발송 (최대 10건, 초과 시 건수만 표기)

### 3-8. 시스템 이벤트 구독

- `stream:system:{서비스명}` 전 서비스 이벤트 구독 ([TECHSPEC 5.1절](TECHSPEC.md#51-redis-streams-서비스-간-이벤트-버스))
- 시스템봇으로 텔레그램 발송
- notifier 자체 장애 시 직접 시스템봇 HTTP 호출 (예외 경로)
- Watchtower 배포 완료 시 텔레그램 알림 연동 ([TECHSPEC 10.2절](TECHSPEC.md#102-cicd-파이프라인))

### 완료 기준 (Phase 3)

[PRD 3절 Phase 3 성공 지표](PRD.md#3-성공-지표-success-metrics) 충족:

- 타이밍 조건 충족 → 텔레그램 발송 지연 < 60초
- 알림 필터 오작동 0건 (쿨다운·확증 필터 수동 검증)
- 일일 리포트 정시 발송 100%
- `stream:alert`에 발송 완료 이벤트가 정상 발행됨을 확인

---

## Phase 4: aaa-trader (반자동 주문)

> **전제**: Phase 3 완료. `stream:alert` 이벤트 안정적으로 수신 가능한 상태
>
> **리소스 점검**: `docker stats`로 Phase 1+2+3 운영 중 메모리 사용량 측정 → 추가 서비스 수용 가능 여부 확인. 부족 시 RAM 증설 후 진행

[PRD 11절 주문 실행](PRD.md#11-주문-실행-phase-4) 구현.

### 4-1. 프로젝트 기반 설정

- Spring Boot 3.5.11, Java 21 Virtual Threads, Gradle Kotlin DSL 초기 설정
- KST 시간대 통일 설정
- 구조화 로그(JSON) + 민감 정보 마스킹
- Trace ID 수신 및 전파
- Spring Boot Actuator `health`만 노출 + 컨테이너 `healthcheck` 설정

### 4-2. DB 스키마 (Phase 4)

- 주문 이력 테이블: `order_log` (INSERT-ONLY) ([TECHSPEC 4절](TECHSPEC.md#4-db-스키마))

### 4-3. 주문 권한 제어

- Telegram User ID 화이트리스트 검증 — trader 단독 수행 ([TECHSPEC 9.3절](TECHSPEC.md#93-권한-제어), [PRD 9.3절](PRD.md#93-알림-채널))
- 미등록 계정 처리: 명령 무시 + 시스템 채널 즉시 알림 (User ID 포함)
- 텔레그램 명령 입력값 검증: 종목코드/수량 형식 검사, 음수·비정상 값 거부 ([TECHSPEC 9.3절](TECHSPEC.md#93-권한-제어), [TECHSPEC 12절](TECHSPEC.md#12-보안))
- 2차 인증 메커니즘 검토 결정 (PIN/OTP 등) 및 적용 여부 ADR 기록

### 4-4. 텔레그램 명령 수신 (Long Polling)

- 매매봇 Long Polling 구현
- `/buy`, `/sell` 명령어 파싱 ([PRD 11.1절](PRD.md#111-주문-트리거))
- 종목 등급 수동 변경 명령어 처리 (C→A 상향/A→C 하향) ([PRD 6.2절](PRD.md#62-ml-매매-신호-생성-대상))

### 4-5. 주문 흐름 구현

- STRONG 등급 알림 인라인 버튼 [매수]/[매도] 처리 ([PRD 11.1절](PRD.md#111-주문-트리거))
- 주문 확인 2단계 구현 (1차 확인 → 2차 최종 확인 → 10분 미응답 시 자동 취소) ([TECHSPEC 9.1절](TECHSPEC.md#91-주문-흐름-7단계))
- 확인 만료된 인라인 버튼 비활성화
- KIS API 시장가/지정가 주문 실행 ([PRD 11.2절](PRD.md#112-주문-유형))
- 체결 완료/실패 텔레그램 알림
- 주문 결과 `order_log` INSERT
- 이중 주문 방지: 콜백 중복 필터 + 주문 멱등성 키 (Redis SET NX) ([TECHSPEC 5.4절](TECHSPEC.md#54-redis-주문-멱등성-phase-4), [TECHSPEC 9.1절](TECHSPEC.md#91-주문-흐름-7단계))

### 4-6. 알림 이벤트 연동

- `stream:alert` Consumer Group 구독 ([TECHSPEC 5.1절](TECHSPEC.md#51-redis-streams-서비스-간-이벤트-버스))
- `stream:system:trader` 장애 이벤트 발행

### 완료 기준 (Phase 4)

[PRD 3절 Phase 4 성공 지표](PRD.md#3-성공-지표-success-metrics) 충족:

- 텔레그램 주문 명령 처리 지연 < 3초
- 주문 실패 시 즉시 오류 알림 발송 확인
- 2단계 확인 흐름 + 10분 자동 취소 정상 동작 확인
- 주문 안전 한도 초과 시 거부 + 알림 정상 동작 확인
- 이중 주문 방지 정상 동작 확인 (동일 콜백 중복 탭)

---

## 운영 지속 (전체 Phase)

Phase 4 완료 후 지속적으로 수행하는 운영 항목.

- 주간 재학습 정상 수행 확인 — 성능 지표 추세 모니터링
- ML 수익률 범위 기준 튜닝 (운영 데이터 축적 후)
- 알림 필터 파라미터 튜닝 (Tier 임계값, 쿨다운, 확증 횟수) ([TECHSPEC 8절](TECHSPEC.md#8-알림-필터-파이프라인))
- 시간외 알림 임계값 확정 (갭 %, 비정상 거래량 배수) ([TECHSPEC 3.7절](TECHSPEC.md#37-시간외-데이터-수집-정책))
- MySQL 파티셔닝 검토 — 연간 1,000만 건 초과 시 ([TECHSPEC 4절](TECHSPEC.md#4-db-스키마))
- RAM 16GB 확장(선택 사항) 시 JVM 힙 상향 및 CatBoost 추가 검토 ([TECHSPEC 10.3절](TECHSPEC.md#103-docker-compose-구성), [TECHSPEC 6.1절](TECHSPEC.md#61-모델-구조))
- Docker Content Trust(이미지 서명 검증) 도입 여부 결정 ([TECHSPEC 10.2절](TECHSPEC.md#102-cicd-파이프라인))

---

*최초 작성: 2026-02-24*
