# MySQL 설정 (config/mysql)

MySQL 사용자·권한 부트스트랩 스크립트. `docker-compose.yml`이 `initdb.d/`를
`/docker-entrypoint-initdb.d/:ro`로 마운트한다 (`${AAA_SSD_BASE}/config/mysql/initdb.d`).

## 권한 모델 (ADR-026)

collector 권한은 테이블 단위 2-tier로 관리한다. 컬럼 단위 GRANT는 쓰지 않는다.

| Tier | 성격 | 권한 | 대상 |
|------|------|------|------|
| Tier-1 | 한 번 쓰면 불변(시계열·이벤트·로그) | `SELECT, INSERT` (db 단위) | `daily_ohlcv` 등 12개 |
| Tier-2 | 제자리 갱신이 본질(마스터·상태) | `SELECT, INSERT` + 테이블 `UPDATE` | `stocks`, `stock_grades`, `short_sale_overseas`, `etf_metadata`, `backfill_status` |

collector는 어떤 테이블에도 `DELETE`/DDL을 갖지 않는다(소프트 삭제 — ADR-022 / ADR-026 결정 4).

## 파일

| 파일 | 실행 시점 | 내용 |
|------|-----------|------|
| `my.cnf` | 컨테이너 기동 시 마운트 (`/etc/mysql/conf.d/my.cnf:ro`) | 서버 커스텀 설정 — 문자셋(utf8mb4)·KST·InnoDB 버퍼풀·binlog·로그. **변경 반영에 MySQL 재기동 필요(수동, 자동 배포 대상 아님)** |
| `initdb.d/01-init-collector.sh` | MySQL 데이터 디렉토리 **최초 init** (자동) | `flyway`·`collector` 유저 생성 + **db 단위** 권한 (flyway 전체 DDL / collector `SELECT,INSERT`) |
| `grants/collector-tier2-grants.sql` | 스키마 생성 **이후** (수동/런북, 1회) | collector **테이블 단위 UPDATE** 4종 |

### 왜 Tier-2가 별도 파일인가

`initdb.d`는 MySQL 최초 init 시점, 즉 collector 부팅으로 Flyway가 스키마를 만들기
**전에** 실행된다. MySQL 8.4는 존재하지 않는 테이블에 대한 테이블 단위 GRANT를
`ERROR 1146`으로 거부하므로(실증 확인), Tier-2 UPDATE는 `01-init-collector.sh`에
넣을 수 없다. 스키마가 존재한 뒤 `collector-tier2-grants.sql`로 적용한다.

## 적용 절차

### 신규/복구 DB
1. 컨테이너 최초 기동 → `01-init-collector.sh` 자동 실행 (유저 + db 단위 권한).
2. collector 최초 부팅 → Flyway 마이그레이션으로 스키마 생성.
3. Flyway 완료 후 root로 Tier-2 적용:
   ```bash
   docker exec -i aaa-mysql sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' \
     < config/mysql/grants/collector-tier2-grants.sql
   ```

### 기존 라이브 DB (GRANT 표류 복원)
이미 스키마가 존재하므로 3번만 실행한다. `initdb.d`는 기존 DB에 재실행되지 않으므로
`01-init-collector.sh` 수정만으로는 라이브에 반영되지 않는다.

### 검증
```sql
SHOW GRANTS FOR 'collector'@'%';
```

## NAS 동기화

레포가 GRANT 선언의 단일 소스다. NAS의 `${AAA_SSD_BASE}/config/mysql/`로 동기화하여
`docker-compose.yml` 마운트 경로와 일치시킨다. GRANT 변경은 항상 이 파일들을 통한다
(ad-hoc `GRANT` 금지 — ADR-026 결정 3).

## 보안

스크립트에 비밀번호 평문을 넣지 않는다. 모든 비밀번호는 컨테이너 env 변수
(`MYSQL_ROOT_PASSWORD`, `MYSQL_FLYWAY_PASSWORD`, `MYSQL_COLLECTOR_PASSWORD`) 치환으로만
참조한다 (REQ-GRANT-024/031).
