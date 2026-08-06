-- =============================================================================
-- collector Tier-2 (UPDATE) GRANT — ADR-026 / SPEC-INFRA-DBGRANT-001
-- =============================================================================
-- Tier-2 = 제자리 갱신(in-place UPDATE)이 본질인 마스터/상태 테이블.
-- Tier-1(시계열·로그) 테이블에는 UPDATE를 부여하지 않는다(DB 수준 불변성 강제).
--
--   stocks               마스터 — 종목명·active·watchlist_removed_at 갱신 (ADR-022)
--   stock_grades         상태 — 재등급 시 갱신
--   short_sale_overseas  FINRA Daily/Short Interest 이중 소스 UPSERT 병합 (ADR-017)
--   etf_metadata         메타 upsert (EtfMetadataWriter.upsert)
--   backfill_status      상태 — 백필 진행점 전진(UPDATE). 시딩은 INSERT IGNORE(Tier-1)이나
--                        진행점(last_collected_date/attempt_count) 전진은 UPDATE (SPEC-COLLECTOR-BACKFILL-001)
--   market_calendar      상태 — 일일 갱신 배치가 소스 우선순위 판정 후 기존 행을 in-place UPDATE
--                        (SPEC-COLLECTOR-CALENDAR-001 REQ-CAL-004/-020/-021, aaa-infra#120)
--   short_sale_domestic  정정 대상 — short_sell_vol_rate/short_sell_qty/acml_vol/vol_rate_verified_at를
--                        평이한 UPDATE ... WHERE로 in-place 정정 (SPEC-COLLECTOR-SHORTSALE-VOLRATE-CORRECTION-001,
--                        aaa-infra#61 분할·병합 왜곡 상시 정정 + aaa-infra#133 T+0 예비치 리비전 소급 정정,
--                        ADR-026 2026-08-06 개정 — daily_ohlcv/investor_trend는 포함하지 않음)
--
-- [WHY 별도 파일] initdb.d(01-init-collector.sh)는 MySQL 최초 init 시점,
--   즉 Flyway가 스키마를 만들기 전에 실행된다. MySQL 8.4는 존재하지 않는
--   테이블에 대한 테이블 단위 GRANT를 거부하므로(ERROR 1146), Tier-2 UPDATE는
--   스키마 생성 이후 이 스크립트로 별도 적용한다.
--
-- [WHEN] (1) 신규/복구 DB: collector 최초 부팅(Flyway 완료) 직후 root로 1회 실행.
--        (2) 기존 라이브 DB: GRANT 표류 복원을 위해 1회 실행.
--
-- [APPLY] MySQL 호스트(NAS)에서 — DB명은 aaa 고정(MYSQL_DATABASE=aaa):
--   docker exec -i aaa-mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' \
--     < config/mysql/grants/collector-tier2-grants.sql
--
-- [VERIFY] SHOW GRANTS FOR 'collector'@'%';
-- [REVERT] REVOKE UPDATE ON aaa.<table> FROM 'collector'@'%';
-- =============================================================================

GRANT UPDATE ON aaa.stocks TO 'collector'@'%';
GRANT UPDATE ON aaa.stock_grades TO 'collector'@'%';
GRANT UPDATE ON aaa.short_sale_overseas TO 'collector'@'%';
GRANT UPDATE ON aaa.etf_metadata TO 'collector'@'%';
GRANT UPDATE ON aaa.backfill_status TO 'collector'@'%';
GRANT UPDATE ON aaa.market_calendar TO 'collector'@'%';
GRANT UPDATE ON aaa.short_sale_domestic TO 'collector'@'%';
FLUSH PRIVILEGES;
