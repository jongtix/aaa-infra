#!/usr/bin/env bash
# =============================================================================
# MySQL 초기화 스크립트 — analyzer/trainer 계정 (SPEC-ANALYZER-SCHEMA-001)
# =============================================================================
# [활성화 완료] SPEC-ANALYZER-SCHEMA-001 구현으로 analyzer 블록 주석을 해제했다.
#   이 스크립트는 MySQL 데이터 볼륨 최초 초기화 시점에만 실행되므로, 이미
#   초기화된 라이브 NAS DB에는 이 파일만으로 계정이 생성되지 않는다 — 라이브
#   계정 생성은 root 수동 SQL로 별도 수행한다(REQ-ASCH-032, plan.md M2 배포 절차).
#
# [완료] trainer 계정은 2026-07-05 root로 수동 생성 완료(이 스크립트 미경유 — 직접 SQL).
#   host='172.20.0.1'(브리지 게이트웨이, information_schema.processlist 실측 확정).
#   신규/복구(fresh) DB 볼륨 재구축 시 아래 블록이 CREATE USER IF NOT EXISTS로
#   재현하며, host가 위 실측값과 다르면 별도 계정으로 추가 생성되니 host는
#   반드시 '172.20.0.1'로 유지할 것(또는 재실측 후 갱신). GRANT/MAX_USER_CONNECTIONS는
#   아래 블록과 이미 동일하게 적용됨(SELECT ONLY, 3커넥션).
#
# 마운트: ${AAA_SSD_BASE}/config/mysql/initdb.d/ → /docker-entrypoint-initdb.d/:ro
# MySQL 컨테이너 최초 기동 시(데이터 디렉토리 최초 초기화 시점) 1회만 실행된다.
#   → 현재 데이터 디렉토리는 이미 초기화된 상태이므로, 이 파일이 저장소에
#     추가되어도 다음 `docker compose up`에서 자동 실행되지 않는다(안전).
#
# 파일명 정정: SPEC-ANALYZER-FOUNDATION-001 히스토리 문서에는 "01-init-analyzer.sh"로
#   기재되어 있으나, 01-init-collector.sh와 lexical 실행 순서가 충돌하므로
#   02-init-analyzer.sh로 정정한다.
#
# 환경변수 (.env.mysql에서 주입 예정, aaa-infra/.env.example 참조):
#   MYSQL_ROOT_PASSWORD, MYSQL_DATABASE
#   MYSQL_ANALYZER_PASSWORD  — 런타임 서비스 계정 (SELECT+INSERT, trading_signals 등)
#   MYSQL_TRAINER_PASSWORD   — MacBook 학습 조회 전용 (SELECT ONLY, D-19)
#
# 권한 모델:
#   - analyzer: 런타임 서비스 계정. host='%'. SELECT + INSERT.
#   - trainer : MacBook → SSH 로컬 포트포워딩 터널 경유 학습 조회 전용. SELECT ONLY.
#               host는 반드시 실측으로 확정한다(추정치를 그대로 박지 말 것).
#               실측 절차: 터널 연결 후 root로
#                 SELECT host FROM information_schema.processlist WHERE user='root';
#               (docker-proxy 동작 특성상 브리지 게이트웨이 172.20.0.1로 보일 가능성이 높으나
#                버전/설정에 따라 달라질 수 있어 실측 없이 하드코딩하지 않는다)
# =============================================================================

# --- analyzer 런타임 사용자 (SPEC-ANALYZER-SCHEMA-001에서 활성화) ---
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<-EOSQL
    CREATE USER IF NOT EXISTS 'analyzer'@'%' IDENTIFIED BY '${MYSQL_ANALYZER_PASSWORD}';
    GRANT SELECT, INSERT ON ${MYSQL_DATABASE}.* TO 'analyzer'@'%';
    FLUSH PRIVILEGES;
EOSQL

# --- trainer 계정 (MacBook 학습 조회 전용, D-19 — SPEC-ANALYZER-SCHEMA-001에서 활성화) ---
# host는 2026-07-05 실측 확정값('172.20.0.1') 반영 완료. 재실측 시에만 갱신할 것.
# mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<-EOSQL
#     CREATE USER IF NOT EXISTS 'trainer'@'172.20.0.1' IDENTIFIED BY '${MYSQL_TRAINER_PASSWORD}';
#     GRANT SELECT ON ${MYSQL_DATABASE}.* TO 'trainer'@'172.20.0.1';
#     ALTER USER 'trainer'@'172.20.0.1' WITH MAX_USER_CONNECTIONS 3;
#     FLUSH PRIVILEGES;
# EOSQL
