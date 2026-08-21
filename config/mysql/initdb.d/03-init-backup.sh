#!/usr/bin/env bash
# =============================================================================
# MySQL 초기화 스크립트 — backup 전용 계정 (SPEC-INFRA-DB-BACKUP-001)
# =============================================================================
# 마운트: ${AAA_SSD_BASE}/config/mysql/initdb.d/ → /docker-entrypoint-initdb.d/:ro
# MySQL 컨테이너 최초 기동 시(데이터 디렉토리 최초 초기화 시점) 1회만 실행된다.
#   → 이미 초기화된 라이브 NAS DB에는 이 파일만으로 계정이 생성되지 않는다.
#     라이브 계정 생성은 root 수동 SQL로 별도 수행한다(analyzer/trainer 계정과
#     동일한 관례 — 02-init-analyzer.sh 서문 참조).
#
# 환경변수 (.env.mysql에서 주입, aaa-infra/.env.example 참조 — 사용자가 NAS
# 측 env 파일에 MYSQL_BACKUP_PASSWORD를 직접 추가해야 한다. 기존
# MYSQL_ANALYZER_PASSWORD 등과 동일한 방식이며, 이 초기화 스크립트나 어떤
# 에이전트도 .env/.env.example 파일 자체를 수정하지 않는다):
#   MYSQL_ROOT_PASSWORD, MYSQL_BACKUP_PASSWORD
#
# 권한 모델(REQ-SEC-001[HARD]):
#   mysqldump --single-transaction --source-data=2 --routines --events
#   --triggers --no-tablespaces --all-databases(REQ-BK-001) + FLUSH BINARY
#   LOGS(REQ-BK-010) 실행에 필요한 최소 권한만 부여한다. 전 권한이 글로벌
#   (*.*) 대상이므로 — collector/analyzer의 Tier-2 테이블 단위 GRANT와 달리
#   —  Flyway 스키마 생성 여부와 무관하게 이 초기화 스크립트 단계에서 CREATE
#   USER + GRANT를 한 번에 적용할 수 있다(ERROR 1146 대상 없음).
#     SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES  — 전 DB 대상(*.*)
#     RELOAD, REPLICATION CLIENT                        — 글로벌
#   PROCESS는 절대 부여하지 않는다(mysqldump --no-tablespaces로 대체).
#
# [라이브 DB GRANT 재적용] 계정이 이미 존재하는 라이브 DB에서 권한만
# 재적용/복구해야 하는 경우(GRANT 표류 등)는 이 파일이 아니라
# config/mysql/grants/backup-grants.sql(GRANT 문만, CREATE USER 없음)을
# 사용한다 — analyzer-grants.sql/collector-tier2-grants.sql과 동일 관례.
# =============================================================================

mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<-EOSQL
    CREATE USER IF NOT EXISTS 'backup'@'%' IDENTIFIED BY '${MYSQL_BACKUP_PASSWORD}';
    GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES ON *.* TO 'backup'@'%';
    GRANT RELOAD, REPLICATION CLIENT ON *.* TO 'backup'@'%';
    FLUSH PRIVILEGES;
EOSQL
