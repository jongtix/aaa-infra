-- =============================================================================
-- analyzer INSERT GRANT — ADR-026 / SPEC-ANALYZER-SCHEMA-001
-- =============================================================================
-- analyzer 런타임 서비스 계정에 신규 시계열 2테이블 INSERT 권한만 부여한다.
-- SELECT ON aaa.*는 계정 생성 시점(root 수동 SQL, CREATE USER + GRANT SELECT)에
-- 이미 부여되므로 이 파일에서 재부여하지 않는다. DELETE/UPDATE/DDL은 절대 부여하지
-- 않는다(ADR-026 2-tier 모델, REQ-ASCH-015 — signal_price_bands 무기한 보관 결정을
-- 이유로 나중에 DELETE grant를 추가하지 않는다).
--
--   trading_signals      시계열 — analyzer 배치가 추론 결과를 INSERT
--   signal_price_bands   시계열 — analyzer 배치가 가격 밴드 스윕 결과를 INSERT
--
-- [WHY 별도 파일] initdb.d(02-init-analyzer.sh)는 MySQL 최초 init 시점,
--   즉 Flyway가 스키마를 만들기 전에 실행된다. MySQL 8.4는 존재하지 않는
--   테이블에 대한 테이블 단위 GRANT를 거부하므로(ERROR 1146), trading_signals/
--   signal_price_bands에 대한 INSERT grant는 V43/V44 마이그레이션 배포 완료
--   이후 이 스크립트로 별도 적용한다.
--
-- [WHEN] V43__analyzer_create_trading_signals.sql,
--        V44__analyzer_create_signal_price_bands.sql이 collector 기동을 통해
--        배포 완료된 것을 flyway_schema_history로 확인한 **이후에만** 실행한다.
--        순서 위반 시 ERROR 1146 (42S02)로 즉시 실패한다.
--
-- [APPLY] MySQL 호스트(NAS)에서 — DB명은 aaa 고정(MYSQL_DATABASE=aaa):
--   docker exec -i aaa-mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' \
--     < config/mysql/grants/analyzer-grants.sql
--
-- [VERIFY] SHOW GRANTS FOR 'analyzer'@'%';
--   → SELECT ON aaa.*, INSERT ON aaa.trading_signals, INSERT ON aaa.signal_price_bands
--     정확히 3개 권한 행만 존재해야 한다(그 외 UPDATE/DELETE/DDL 0건).
-- [REVERT] REVOKE INSERT ON aaa.<table> FROM 'analyzer'@'%';
-- =============================================================================

GRANT INSERT ON aaa.trading_signals TO 'analyzer'@'%';
GRANT INSERT ON aaa.signal_price_bands TO 'analyzer'@'%';
FLUSH PRIVILEGES;
