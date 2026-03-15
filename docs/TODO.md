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
- ~[ ] GitHub Actions 워크플로우 — Docker 이미지 빌드~ → Phase 1 이월 (빌드 대상 앱 서비스 없음)
- ~[ ] GHCR 이미지 푸시 설정~ → Phase 1 이월 (빌드 대상 앱 서비스 없음)
- [x] Watchtower GHCR 폴링 — `docker-compose.yml` opt-in 라벨 모드 설정 완료. 앱 서비스 추가 시 라벨 부여로 활성화
- [x] Dependabot 설정 — `docker-compose` + `github-actions` 에코시스템 (weekly, 월요일 15:00 KST)
- [x] Docker 이미지 태그 전략 수립 — TECHSPEC 10.2절 + ADR-005 확정 (semver + latest + sha 3중 태그)

### 완료 기준
- [x] Docker Compose `up` 시 MySQL, Redis, Watchtower 정상 기동
- ~[ ] GitHub Push → GHCR 빌드 → Watchtower 자동 업데이트 동작 확인~ → Phase 1 이월
- [x] `.env.*` 파일이 git 커밋에 포함되지 않음을 pre-commit hook으로 검증
