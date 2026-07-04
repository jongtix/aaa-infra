#!/usr/bin/env bash
# =============================================================================
# MySQL 초기화 스크립트 — analyzer/trainer 계정 (Phase 2, 선행 참조 스크립트)
# =============================================================================
# [비활성] 이 파일은 전체 주석 처리 상태다. 정식 활성화(주석 해제)는
#   SPEC-COLLECTOR-SCHEMA-001 구현 시점으로 이연되어 있다
#   (SPEC-ANALYZER-FOUNDATION-001 §4 Exclusions 근거: 계정 생성에 시크릿 발급이
#   필요하고, grants 정합 범위가 이미 SCHEMA-001 로드맵에 있으며, 골격 SPEC은
#   DB에 접속하지 않는다).
#   trainer 계정만 D-19(2026-07-04) 선행 수동 생성 작업의 재현 가능성 확보를
#   위해 내용을 먼저 기록해 둔다 — SCHEMA-001 착수 전까지 주석 해제 금지.
#
# [완료] trainer 계정은 2026-07-05 root로 수동 생성 완료(이 스크립트 미경유 — 직접 SQL).
#   host='172.20.0.1'(브리지 게이트웨이, information_schema.processlist 실측 확정).
#   SCHEMA-001에서 아래 블록을 활성화할 때 CREATE USER IF NOT EXISTS라 재실행은 안전하나,
#   host가 위 실측값과 다르면 별도 계정으로 추가 생성되니 <TRAINER_HOST_TBD>를
#   반드시 '172.20.0.1'로 맞출 것(또는 재실측 후 갱신). GRANT/MAX_USER_CONNECTIONS는
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

# --- Phase 2: analyzer 런타임 사용자 (SCHEMA-001에서 활성화) ---
# mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<-EOSQL
#     CREATE USER IF NOT EXISTS 'analyzer'@'%' IDENTIFIED BY '${MYSQL_ANALYZER_PASSWORD}';
#     GRANT SELECT, INSERT ON ${MYSQL_DATABASE}.* TO 'analyzer'@'%';
#     FLUSH PRIVILEGES;
# EOSQL

# --- Phase 2: trainer 계정 (MacBook 학습 조회 전용, D-19 — SCHEMA-001에서 활성화) ---
# host는 2026-07-05 실측 확정값('172.20.0.1') 반영 완료. 재실측 시에만 갱신할 것.
# mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<-EOSQL
#     CREATE USER IF NOT EXISTS 'trainer'@'172.20.0.1' IDENTIFIED BY '${MYSQL_TRAINER_PASSWORD}';
#     GRANT SELECT ON ${MYSQL_DATABASE}.* TO 'trainer'@'172.20.0.1';
#     ALTER USER 'trainer'@'172.20.0.1' WITH MAX_USER_CONNECTIONS 3;
#     FLUSH PRIVILEGES;
# EOSQL
