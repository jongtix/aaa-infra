# TODO: AAA (Algorithmic Alpha Advisor)

> 현재 Phase: **Phase 0**
>
> 전체 마일스톤은 [MILESTONE.md](MILESTONE.md) 참조

---

## Phase 0: 인프라 공통

### 0-1. Docker Compose 기본 구성
- [x] `docker-compose.yml` 작성 — MySQL 8.4, Redis 8.6, Watchtower
- [x] Docker 네트워크 `aaa-network` 구성
- [x] MySQL/Redis 포트 호스트 바인딩 금지 (`expose`만 사용)
- [x] `restart: unless-stopped` 정책 전 서비스 적용
- [x] MySQL/Redis 데이터 볼륨 마운트 경로 지정 확인

### 0-2. 환경 변수 및 시크릿 관리
- [x] `.env.common`, `.env.collector`, `.env.analyzer`, `.env.notifier`, `.env.trader` 파일 분리
- [x] `.env.example` 파일 작성
- [x] `.gitignore`에 `.env*` 패턴 등록 (`.env.example` 예외)
- [x] pre-commit hook — `.env*` 파일 커밋 방지
- [x] 모든 `.env.*` 파일 `chmod 600`
- [x] 인프라-앱 시크릿 격리 — `.env.mysql`, `.env.redis` 분리, `.env.common` 앱 전용으로 축소

### 0-3. MySQL 초기화
- [x] `my.cnf` 작성 — NAS 환경 메모리 설정 (`innodb_buffer_pool_size` 등)
- [x] `initdb.d/01-init.sh` 작성 — 서비스별 전용 사용자 생성 + 최소 권한 원칙
- [x] 서비스별 전용 사용자 생성 + 최소 권한 원칙 (DB 레벨 INSERT/SELECT)
- [x] root 계정 원격 접속 금지

### 0-4. Redis 초기화
- [x] `redis.conf` 작성 — `maxmemory`, AOF, RDB 비활성화
- [x] `users.acl` 작성 — `default` 비활성화, `admin`, `appuser` 권한 정의
- [x] ACL 기반 인증 (`aclfile`) — `default` 유저 비활성화, `admin` 유저(healthcheck·관리용), `appuser`에 `-@dangerous` 적용

### 0-5. CI/CD 파이프라인
- [x] GitHub Actions 워크플로우 — Release(semantic-release) + Docker(GHCR 빌드+푸시) + Deploy(self-hosted runner) 3단계 체인
- [x] GHCR 이미지 푸시 설정 — `docker.yml` 워크플로 + GHCR 패키지 권한 설정
- [x] Watchtower 서비스 제외 — GitHub Actions CD로 대체 (ADR-018)
- [x] Dependabot 설정 — `docker-compose` + `github-actions` 에코시스템 (weekly, 월요일 15:00 KST)
- [x] Docker 이미지 태그 전략 수립 — TECHSPEC 10.2절 + ADR-005 확정 (semver + latest + sha 3중 태그)

### 완료 기준
- [x] Docker Compose `up` 시 MySQL, Redis 정상 기동
- [x] GitHub Push → GHCR 빌드 → GitHub Actions Deploy 자동 배포 동작 확인
- [x] `.env.*` 파일이 git 커밋에 포함되지 않음을 pre-commit hook으로 검증

---

## Phase 1: 수집 관측성 (SPEC-COLLECTOR-OBSV-001)

### 1-O1. collector 계측 (M1+M3 — aaa-collector)
- [x] 틱 수집 메트릭 (`aaa_collector_batch_completeness_ratio`, `aaa_collector_batch_last_load_seconds`)
- [x] 시장 게이트 메트릭 (`aaa_collector_market_open`, `aaa_collector_market_gate_last_update_seconds`)
- [x] INSERT IGNORE 침묵 드롭 행별 캡처 (warning-count 관측성)
- [x] `/actuator/prometheus` 엔드포인트 노출

### 1-O2. 관측성 인프라 스택 (M2+M4 — aaa-infra, OBSV-001)
- [x] VictoriaMetrics 단노드 서비스 추가 + collector 스크랩 설정 (`scrape_interval: 30s`)
- [x] vmalert 서비스 추가 + 룰 5개 (`CollectorDown`/`CompletenessLow`/`BatchStale`/`GateStale`/`GateUnset`)
- [x] Alertmanager 서비스 추가 + 시스템봇 Telegram receiver (`bot_token_file`/`chat_id_file`)
- [x] compose 네이티브 `secrets:` 토큰 주입 (값-전용 파일, `chmod 644` 필수)
- [x] `read_only: true` + `tmpfs: /tmp` 전 OBSV 컨테이너 적용
- [x] `init-nas.sh` OBSV 디렉토리·토큰 파일 프로비저닝 안내 추가
- [x] NAS 수동 배포 완료 (SMB 복사, 2026-06-20)

### 완료 기준
- [x] VM → collector 스크랩 `up` 실측 (121 samples)
- [x] RAM 실사용 합 ~53M < limit 384M (TI-008)
- [x] vmalert-tool unittest 11/11 SUCCESS (`config/vmalert/rules_test.yaml`)
- [x] 라이브 CollectorDown firing → AM → 시스템봇 텔레그램 FIRING 수신·resolved 해소 (TI-009, 2026-06-20)
