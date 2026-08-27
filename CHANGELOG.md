# Changelog

이 프로젝트의 주요 변경사항을 기록한다. 형식은 [Keep a Changelog](https://keepachangelog.com/ko/1.1.0/)를 따른다.

## [Unreleased]

### Added

- aaa-analyzer 일일 모델 정체 감지 배선 — 컨테이너 모델 마운트 + 관측 경로 (SPEC-ANALYZER-TRAIN-STALENESS-001 M2/M6, REQ-ATD-*)
  - `docker-compose.yml` analyzer 서비스에 활성 모델 디렉토리 read-only 바인드 마운트 추가 — `${AAA_HDD_BASE}/models/active:/mnt/models:ro`(staging 제외). host 경로는 NAS 실측으로 확정(`docker inspect` + `find` + `getfacl`, 2026-08-27) — 트레이너 SMB 쓰기 프로세스(`train_smb`) 소유, 777 (AC-ATD-002)
  - `scripts/init-nas.sh`에 해당 디렉토리 group 읽기 권한 확보 로직 추가 — `chgrp $ANALYZER_UID` + `chmod g+rX`(소유권 비이전). 현재 777이라 즉시 필요하진 않으나 트레이너 측 권한 강화에 대비한 방어적 장치 (AC-ATD-004)
  - vmalert 신규 그룹 `analyzer-model-staleness`(기존 `analyzer-training-automation`과 분리) 알림 2종 — `AnalyzerModelStale`(`aaa_analyzer_model_stale == 1`, per-combo 정체 즉시 통지), `AnalyzerModelStaleScanSilent`(`absent_over_time(aaa_analyzer_model_stale[25h])`, 24h 케이던스 + 1h 여유 데드맨) (AC-ATD-011)
  - 유닛테스트는 기존 샤드 2개(`rules_test_analyzer.yaml` / `_slow.yaml`)에 케이스 추가 — GATE-001이 같은 파일명을 선점하고 있어 신규 파일 대신 확장. 11샤드 전체 `vmalert-tool unittest` SUCCESS, `check-alert-coverage.sh` 죽은 참조 0건. 25h 시뮬레이션 실측 1.9초 (AC-ATD-012)
  - 알려진 한계: `absent_over_time()`은 시계열 소실만 감지한다 — analyzer 프로세스가 살아있는 채로 cron만 조용히 멈추면 `prometheus_client` Gauge가 마지막 값을 계속 노출하므로 감지되지 않는다. 실제 감지 대상은 스크랩 타깃 완전 두절뿐(룰 YAML 주석에도 명시)
  - 배포: `rules.yml`은 CD 자동 반영(REQ-CD-006) — NAS vmalert에 2종 룰 로드 확인 완료. `docker-compose.yml`·`init-nas.sh`는 항상 수동 적용 대상이며 운영자 작업 대기 중
- CI/CD 룰셋 강화 — infra 스코프 (SPEC-INFRA-CICD-002)
  - `ci.yml`에 `pull_request` 트리거 추가 — PR에서 머지 전 실제 CI 검증(`status-check` job)
  - `main` 브랜치 룰셋(`main-protection`) 신설 — 선형 히스토리 강제, 강제 푸시/삭제 차단, `status-check` 상태 체크 필수, GitHub App(`aaa-ci-release-bot`)만 `bypass_actors`로 등재해 보호된 `main`을 우회
  - `tag-protection` 룰셋 신설(`refs/tags/v*`) — 릴리스 태그 삭제·재태그 차단
  - `dependabot-auto-merge.yml` 신규 — non-major Dependabot PR을 CI 통과 후 자동 머지(`dependabot/fetch-metadata` + `gh pr merge --auto --rebase`), `dependabot.yml`에 3일 쿨다운 추가
  - `aaa-collector`/`aaa-notifier`/`aaa-analyzer` 3개 서비스 레포에도 동일한 룰셋·App 우회·`workflow_run`→태그 트리거 전환·커밋백 제거·`concurrency` 그룹·`persist-credentials: false` 적용(레포별 상세는 각 레포 CHANGELOG 참조). 4개 레포 공통으로 "Allow auto-merge" 저장소 설정을 활성화(기본 비활성으로 확인되어, M6 자동 머지가 항상 실패했을 결함을 사전 수정)
- aaa-analyzer 주간 챌린저 게이트 관측 배선(SPEC-ANALYZER-TRAIN-GATE-001 M6) — 스크랩 + 알림 룰 2계층 (REQ-ATG-*)
  - VictoriaMetrics 스크랩 잡 신설 — `job_name: analyzer`, `/metrics`, `aaa-analyzer:8000` (AC-ATG-013)
  - vmalert 신규 그룹 `analyzer-training-automation`(30s interval) 알림 3종 — `AnalyzerTrainingWeeklySilent`(8일 무발화 데드맨), `AnalyzerTrainingRunFailed`, `AnalyzerTrainingHeldBack` (AC-ATG-014)
  - 신규 유닛테스트 샤드 2개(`rules_test_analyzer.yaml`/`_slow.yaml`) — 기존 8샤드 0 회귀 확인
- MySQL 백업 시스템 신설 — mysqldump 풀 덤프(매일 05:00 KST) + binlog 아카이브(매시 05분) 조합의 PITR(Point-In-Time Recovery) 체계 (SPEC-INFRA-DB-BACKUP-001, REQ-BK-*)
  - 전용 백업 계정(`backup@%`) 최소권한 GRANT 정의 — `config/mysql/grants/backup-grants.sql` (REQ-SEC-001)
  - `scripts/backup-mysql.sh --mode=full|binlog` — GFS 세대 보존(일간 7 / 주간 4 / 월간 6) 자동 등급 판정 + binlog 회전·복사·프루닝 (REQ-BK-001~012)
  - `aaa-backup-daily.timer` / `aaa-backup-binlog.timer` systemd USER 유닛(sudo 불요) — 매일 05:00:00 / 매시 05분 자동 발화, 백업 디렉토리는 컨테이너에 read-only 마운트 (REQ-BK-020, REQ-BK-021)
  - 데드맨 스위치 메트릭(`aaa_backup_last_success_timestamp_seconds{mode="full"|"binlog"}`) + vmalert 알림 룰 — 풀 덤프 28시간, binlog 6시간 초과 시 알림 (REQ-VF-001, REQ-VF-002, REQ-VF-005)
  - 월 1회 자동 복원 드릴(`aaa-backup-restore-drill.sh/.timer`, 매월 1일 05:30 KST) — throwaway 컨테이너에 최신 풀 덤프를 복원해 테이블 수·핵심 테이블 행 수·데이터 신선도 검증 (REQ-VF-004)
  - `docs/RUNBOOK-mysql-pitr.md` 신규 — PITR 복구 6단계 절차 + `mysqlbinlog` 온디맨드 확보 절차(throwaway `oraclelinux:9-slim` 경유) 문서화 (REQ-DOC-002)
  - `docs/TECHSPEC.md` §10.6 데이터 백업 정책 갱신 — 매일 05:00 KST + GFS 보존 반영 (REQ-DOC-001)
  - CI/CD 백업 저장 위치 SSD → HDD(`${AAA_HDD_BASE}/backups/mysql/`) 이전 (REQ-CD-*)

### Changed

- aaa-collector Flyway 자격증명 전달 방식을 `docker exec -e MYSQL_PWD=...`(프로세스 환경변수 노출)에서 `--defaults-extra-file`(ro 마운트 시크릿 파일) 방식으로 변경 — 이원 관례(자동화=defaults-extra-file / 수동 root 1회성=기존 관례) 문서화 (REQ-MIG-001, REQ-MIG-002)
