# Changelog

이 프로젝트의 주요 변경사항을 기록한다. 형식은 [Keep a Changelog](https://keepachangelog.com/ko/1.1.0/)를 따른다.

## [Unreleased]

### Added

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
