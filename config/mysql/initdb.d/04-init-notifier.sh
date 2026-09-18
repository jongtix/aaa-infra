#!/usr/bin/env bash
# =============================================================================
# MySQL 초기화 스크립트 — notifier 계정 (SPEC-NOTIFIER-SCHEMA-001)
# =============================================================================
# [주의] 이 스크립트는 MySQL 데이터 볼륨 최초 초기화 시점에만 실행된다. 이미
#   초기화된 라이브 NAS DB에는 이 파일만으로 계정이 생성되지 않는다 — 라이브
#   계정 생성은 root 수동 SQL로 별도 수행한다(REQ-NOTIFIER-SCHEMA-025,
#   SPEC-ANALYZER-SCHEMA-001 REQ-ASCH-032/036과 동일한 caveat).
#
# 마운트: ${AAA_SSD_BASE}/config/mysql/initdb.d/ → /docker-entrypoint-initdb.d/:ro
#
# 환경변수 (.env.mysql에서 주입, aaa-infra/.env.example 참조):
#   MYSQL_ROOT_PASSWORD, MYSQL_DATABASE
#   MYSQL_NOTIFIER_PASSWORD — 런타임 서비스 계정 (SELECT + notification_log INSERT)
#
# 권한 모델(REQ-NOTIFIER-SCHEMA-021~023):
#   - notifier: 런타임 서비스 계정. host='%'. 계정 생성 시점에는 SELECT ON aaa.*만
#     부여한다. notification_log에 대한 INSERT는 이 스크립트가 부여하지 않는다 —
#     MySQL 8.4는 존재하지 않는 테이블에 대한 테이블 단위 GRANT를 ERROR 1146으로
#     거부하므로, notification_log 마이그레이션(V49)이 flyway_schema_history로
#     배포 완료된 것을 확인한 **이후에만** config/mysql/grants/notifier-grants.sql로
#     별도 적용한다(REQ-NOTIFIER-SCHEMA-022, SPEC-ANALYZER-SCHEMA-001
#     REQ-ASCH-034와 동일 시퀀싱 위험).
#   - UPDATE/DELETE/DDL 권한은 부여하지 않는다(REQ-NOTIFIER-SCHEMA-023).
# =============================================================================

# --- notifier 런타임 사용자 (SPEC-NOTIFIER-SCHEMA-001) ---
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<-EOSQL
    CREATE USER IF NOT EXISTS 'notifier'@'%' IDENTIFIED BY '${MYSQL_NOTIFIER_PASSWORD}';
    GRANT SELECT ON ${MYSQL_DATABASE}.* TO 'notifier'@'%';
    FLUSH PRIVILEGES;
EOSQL
