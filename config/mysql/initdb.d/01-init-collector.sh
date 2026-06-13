#!/usr/bin/env bash
# =============================================================================
# MySQL 초기화 스크립트 — 서비스별 전용 사용자 생성
# =============================================================================
# 마운트: ${AAA_SSD_BASE}/config/mysql/initdb.d/ → /docker-entrypoint-initdb.d/:ro
# MySQL 컨테이너 최초 기동 시 1회 실행된다 (데이터 디렉토리 최초 초기화 시점).
#
# 환경변수 (.env.mysql에서 주입):
#   MYSQL_ROOT_PASSWORD, MYSQL_DATABASE
#   MYSQL_FLYWAY_PASSWORD (Phase 1 — DDL 전용)
#   MYSQL_COLLECTOR_PASSWORD (Phase 1 — DML 전용)
#
# 권한 모델: collector 테이블 단위 2-tier (ADR-026)
#   - Tier-1 (INSERT 전용): 시계열·이벤트·로그. SELECT, INSERT on aaa.* 로 일괄 부여.
#   - Tier-2 (UPDATE 허용): 마스터/상태 테이블. 테이블 단위 UPDATE.
#
# [중요] 이 스크립트는 Tier-2 테이블 단위 UPDATE를 부여하지 않는다.
#   initdb.d는 MySQL 최초 init 시점(= Flyway가 스키마를 만들기 전)에 실행되며,
#   MySQL 8.4는 존재하지 않는 테이블에 대한 테이블 단위 GRANT를 거부한다(ERROR 1146).
#   따라서 Tier-2 UPDATE는 스키마 생성 이후 별도로 적용한다:
#     config/mysql/grants/collector-tier2-grants.sql
#   (collector 최초 부팅으로 Flyway 마이그레이션이 끝난 뒤 root로 1회 실행)
# =============================================================================

# Phase 1: flyway 사용자 생성 (ADR-016 결정 3)
# Flyway 마이그레이션 전용 — DDL + flyway_schema_history 관리에 필요한 최소 권한
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<-EOSQL
    CREATE USER IF NOT EXISTS 'flyway'@'%' IDENTIFIED BY '${MYSQL_FLYWAY_PASSWORD}';
    GRANT SELECT, INSERT, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES ON ${MYSQL_DATABASE}.* TO 'flyway'@'%';
    FLUSH PRIVILEGES;
EOSQL

# Phase 1: collector 사용자 생성
# 런타임 DML 전용 — DELETE/DDL 없음 (TECHSPEC 4절, ADR-016, ADR-026)
# Tier-1 db 단위 권한만 여기서 부여. Tier-2 UPDATE는 collector-tier2-grants.sql 참조.
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<-EOSQL
    CREATE USER IF NOT EXISTS 'collector'@'%' IDENTIFIED BY '${MYSQL_COLLECTOR_PASSWORD}';
    GRANT SELECT, INSERT ON ${MYSQL_DATABASE}.* TO 'collector'@'%';
    FLUSH PRIVILEGES;
EOSQL
