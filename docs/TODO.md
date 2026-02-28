# TODO: AAA (Algorithmic Alpha Advisor)

> 현재 Phase: **Phase 0**
>
> 전체 마일스톤은 [MILESTONE.md](docs/MILESTONE.md) 참조

---

## Phase 0: 인프라 공통

### 0-1. Docker Compose 기본 구성
- [ ] `docker-compose.yml` 작성 — MySQL 8.4, Redis 8.4, Watchtower
- [ ] Docker 네트워크 `backend` 구성
- [ ] MySQL/Redis 포트 호스트 바인딩 금지 (`expose`만 사용)
- [ ] `restart: unless-stopped` 정책 전 서비스 적용
- [ ] MySQL/Redis 데이터 볼륨 마운트 경로 지정 확인

### 0-2. 환경 변수 및 시크릿 관리
- [ ] `.env.common`, `.env.collector`, `.env.analyzer`, `.env.notifier`, `.env.trader` 파일 분리
- [ ] `.env.example` 파일 작성
- [ ] `.gitignore`에 `.env*` 패턴 등록 (`.env.example` 예외)
- [ ] pre-commit hook — `.env*` 파일 커밋 방지
- [ ] 모든 `.env.*` 파일 `chmod 600`

### 0-3. MySQL 초기화
- [ ] 서비스별 전용 사용자 생성 + 최소 권한 원칙
- [ ] root 계정 원격 접속 금지
- [ ] `my.cnf` 커스터마이징 — NAS 환경 메모리 설정 (`innodb_buffer_pool_size` 등)

### 0-4. Redis 초기화
- [ ] `requirepass` 설정
- [ ] 위험 명령어 비활성화: `FLUSHALL`, `FLUSHDB`, `CONFIG`, `DEBUG`, `KEYS`

### 0-5. CI/CD 파이프라인
- [ ] GitHub Actions 워크플로우 — Docker 이미지 빌드
- [ ] GHCR 이미지 푸시 설정
- [ ] Watchtower GHCR 폴링 — 자동 컨테이너 업데이트

### 완료 기준
- [ ] Docker Compose `up` 시 MySQL, Redis, Watchtower 정상 기동
- [ ] GitHub Push → GHCR 빌드 → Watchtower 자동 업데이트 동작 확인
- [ ] `.env.*` 파일이 git 커밋에 포함되지 않음을 pre-commit hook으로 검증
