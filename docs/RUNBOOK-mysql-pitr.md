# MySQL PITR(Point-In-Time Recovery) 복구 런북

관련: SPEC-INFRA-DB-BACKUP-001 (REQ-DOC-002, AC-DOC-002 [HARD])

이 문서는 `aaa-mysql` 데이터베이스 사고 발생 시, 매일 자정 05:00 KST 풀
덤프(`scripts/backup-mysql.sh --mode=full`)와 매시 5분 binlog 아카이브
(`scripts/backup-mysql.sh --mode=binlog`)를 조합해 특정 시점으로 데이터를
복구하는 절차를 기술한다.

**월 1회 자동 복원 드릴**(`scripts/aaa-backup-restore-drill.sh`,
`aaa-backup-restore-drill.timer`)은 풀 덤프 복원만 검증하며 이 런북의
binlog 재생(mysqlbinlog 온디맨드 확보 포함) 절차는 드릴 범위 밖이다 —
드릴은 "복원 가능성"만 확인하고, 실제 PITR(특정 시점 복구)이 필요할 때는
이 문서의 절차를 사람이 직접 수행해야 한다.

---

## ⚠️ 필독 — 두 가지 함정

### 함정 1: `mysqlbinlog`가 `aaa-mysql` 컨테이너에 없다

`aaa-mysql`(`mysql:8.4` 공식 이미지)은 `mysql-community-server-minimal`
패키지만 설치하며, `mysqlbinlog`는 별도 패키지(`mysql-community-client`)에
포함되어 있어 **컨테이너 내부에 존재하지 않는다**. 이는 MySQL 8.0.30+
공식 이미지의 알려진 업스트림 패턴(`docker-library/mysql#903`·`#907`)이며,
현재(2026-08-24 기준) 9.7 Dockerfile까지 동일하다 — 버전 업으로도 해소되지
않는다.

```bash
docker exec aaa-mysql mysqlbinlog --version
# → 실패(command not found) — 이 명령은 시도하지 말 것, 실패가 확정되어 있다.
```

`mysql-community-client`를 `mysql:8.4` 기반 컨테이너에 **직접 설치**하는
시도도 실패한다 — `mysql-community-server-minimal`이 이미 소유한
`/usr/bin/mysql` 등 경로에서 RPM 파일소유권 충돌이 발생한다(NAS에서 실제
시도해 확인, 2026-08-24).

**해법**: `aaa-mysql`과는 별개의 **throwaway `oraclelinux:9-slim` 컨테이너**에
`mysql-8.4-community` yum 레포를 추가해, PITR 실행 시점에 온디맨드로
`mysqlbinlog`를 확보한다. 자세한 절차는 아래 "3단계: mysqlbinlog 확보"
참조.

### 함정 2: `--stop-datetime`의 시간대(TZ) 해석

`mysqlbinlog`의 `--start-datetime`/`--stop-datetime` 옵션은 값을
**mysqlbinlog 프로세스 자신의 OS 시간대**로 해석한다. `aaa-mysql`의
`default_time_zone=+09:00`(KST, mysqld 설정)과 이 프로세스 OS 시간대는
전혀 다른 개념이다 — 컨테이너 기본 OS 시간대는 보통 UTC이므로, `-e
TZ=Asia/Seoul` 없이 KST 벽시계 값을 그대로 넣으면 **9시간 오차**가
발생한다.

```bash
# 잘못된 예 — 컨테이너 OS 시간대(보통 UTC)로 해석되어 9시간 어긋남
docker exec <container> mysqlbinlog --stop-datetime="2026-08-24 14:30:00" ...

# 올바른 예 — TZ를 명시해 KST로 정확히 해석
docker exec -e TZ=Asia/Seoul <container> mysqlbinlog --stop-datetime="2026-08-24 14:30:00" ...
```

이 TZ 함정은 mysqlbinlog가 어느 컨테이너에서 실행되든(과거 가정이던
`aaa-mysql`이든, 현재의 throwaway `oraclelinux:9-slim`이든) **동일하게
적용된다** — 기준은 항상 mysqlbinlog 프로세스 자신의 OS 시간대다.
`--start-datetime`/`--stop-datetime`은 사고 시점 탐색(2단계 위치 확인)
용도로만 사용하고, 실제 재생(3단계)은 정확한 `--start-position`/
`--stop-position`으로 수행해야 한다(아래 절차 참조).

### 함정 3: 동시성 안전 실패는 의도된 동작(REQ-BK-021)

`backup-mysql.sh --mode=full`은 `--single-transaction`을 사용하므로,
Flyway DDL 마이그레이션이 백업과 동시에 실행 중이면 스냅샷 정합성이 깨져
mysqldump가 0이 아닌 종료 코드로 **안전하게 실패**할 수 있다. 이 실패는
`telegram_notify` 즉시 알림으로 드러나며, 배포 스케줄과 백업 스케줄을
겹치지 않도록 별도 조정하는 것으로 은폐·우회해서는 안 된다(spec.md
REQ-BK-021, plan.md §D). 이런 실패가 관찰되면 다음 회차(다음날 05:00 KST)
정상 백업을 기다리거나 수동으로 `backup-mysql.sh --mode=full`을 재실행한다.

---

## 복구 절차 (6단계)

### 1단계: 최신 덤프 헤더에서 시작 좌표 확인

`mysqldump --source-data=2`가 기록한 좌표 주석을 확인한다:

```bash
zstd -dc "${AAA_HDD_BASE}/backups/mysql/dump-<YYYYMMDD>.sql.zst" | head -50 \
  | grep -A1 "CHANGE REPLICATION SOURCE TO"
```

`SOURCE_LOG_FILE='...', SOURCE_LOG_POS=...` 형태의 주석을 확인·기록해 둔다
— 이 좌표가 "이 덤프가 만들어진 시점의 binlog 위치"이며, PITR 재생은 이
좌표 이후부터 시작한다.

### 2단계: 복원 대상 컨테이너에 풀 덤프 적용

`aaa-backup-restore-drill.sh`와 동일한 throwaway `mysql:8.4` 컨테이너
패턴을 사용한다(사전 빌드 이미지·CI 자산 없음, 매번 새로 기동):

```bash
docker run -d --name pitr-restore-target -e MYSQL_ALLOW_EMPTY_PASSWORD=yes mysql:8.4
# 준비될 때까지 대기
until docker exec pitr-restore-target mysqladmin ping --silent; do sleep 2; done

zstd -dc "${AAA_HDD_BASE}/backups/mysql/dump-<YYYYMMDD>.sql.zst" \
  | docker exec -i pitr-restore-target mysql --user=root
```

풀 덤프에는 `mysql` 시스템 스키마(사용자·권한 테이블)도 포함되어 있어
복원 도중 root 인증 정보가 덮어써질 수 있다 — 이후 단계(5단계)에서 이
**동일 커넥션**을 계속 사용하거나, 재접속이 필요하면 `MYSQL_ALLOW_EMPTY_
PASSWORD` 컨테이너를 새로 기동해 순서를 재조정한다(`aaa-backup-restore-
drill.sh`의 "단일 커넥션 전략" 주석 참조).

### 3단계: mysqlbinlog 확보용 throwaway 컨테이너 준비

`aaa-mysql`(2단계의 `mysql:8.4` 컨테이너)과는 **별개의** throwaway
`oraclelinux:9-slim` 컨테이너를 기동한다 — mysql 계열 이미지가 아닌 클린
베이스를 사용해야 `mysql-community-server-minimal`이 선점한 경로가 없다.

```bash
docker run -d --name pitr-mysqlbinlog-tool oraclelinux:9-slim sleep infinity

docker exec pitr-mysqlbinlog-tool bash -c '
  rpm -ivh https://repo.mysql.com/mysql84-community-release-el9.rpm && \
  microdnf install -y --disablerepo="mysql-9.7-lts-community" \
    --enablerepo="mysql-8.4-lts-community" mysql-community-client && \
  mysqlbinlog --version
'
# 실측 출력(2026-08-24, oraclelinux:9-slim, aarch64):
#   mysqlbinlog  Ver 8.4.11 for Linux on aarch64 (MySQL Community Server - GPL)
```

> **함정 4(2026-08-24 run-phase 실측 발견): `microdnf install -y <URL>`은 실패한다.**
> `mysql84-community-release-el9.rpm`을 `microdnf install -y <URL 또는 로컬
> 경로>`로 직접 설치하려는 시도(`error: No package matches '...'`)는
> `microdnf`가 rpm 파일 경로/URL을 패키지명 대상으로 취급하지 않기 때문에
> 실패한다. **`rpm -ivh <URL>`**로 release 패키지를 먼저 설치해야 한다.
>
> **함정 5: release 패키지가 기본 활성화하는 레포는 8.4가 아니다.**
> `mysql84-community-release-el9.rpm`이라는 파일명과 달리, 이 release
> 패키지는 `mysql-community.repo`에 8.0/8.4-lts/9.7-lts/innovation 등
> **여러 레포 정의를 동시에 등록**하며, 기본으로 활성화되는 것은
> 실측 시점(2026-08-24) 기준 **`mysql-9.7-lts-community`**(최신 GA
> 채널)다. 아무 플래그 없이 `microdnf install -y mysql-community-client`를
> 실행하면 `mysqlbinlog Ver 9.7.x`가 설치된다 — 서버(`aaa-mysql`, 8.4.x)
> 버전과 정확히 일치하지 않을 수 있으므로(9.7 클라이언트가 8.4 서버의
> binlog를 항상 읽을 수 있다는 보장은 없음), 반드시
> `--disablerepo="mysql-9.7-lts-community" --enablerepo="mysql-8.4-lts-community"`
> 로 8.4 계열을 명시적으로 고정해야 한다. 레포 ID 확인 방법:
> `cat /etc/yum.repos.d/mysql-community.repo | grep '^\['`.

이후 HDD binlog 아카이브 경로(`${AAA_HDD_BASE}/backups/mysql/binlog/`)를
이 컨테이너에서 읽을 수 있도록 연결한다(볼륨 마운트 또는 `docker cp`) —
정확한 마운트 문법은 사고 시점의 실제 배포 환경에 맞춰 조정한다.

### 4단계: 사고 시점(정지 지점) 탐색

`-e TZ=Asia/Seoul`을 반드시 지정한다(위 "함정 2" 참조):

```bash
docker exec -e TZ=Asia/Seoul pitr-mysqlbinlog-tool \
  mysqlbinlog --start-datetime="<KST 벽시계 값>" --stop-datetime="<KST 벽시계 값>" \
  /path/to/binlog-archive-file
```

이 단계는 **위치 확인 전용**이다 — 출력에서 사고 발생 직전 이벤트의 정확한
`# at <바이트오프셋>` 위치(`--start-position`/`--stop-position`에 넘길
값)를 찾아 기록한다. datetime 기반 재생은 동일 타임스탬프를 가진 여러
이벤트를 누락하거나 중복시킬 위험이 있으므로 실제 재생에는 사용하지
않는다.

### 5단계: 확인된 위치로 실제 적용

재현성 확보를 위해 datetime이 아닌 **position**으로 재생한다. 여러
binlog 파일에 걸쳐 있으면 1회 `mysqlbinlog` 호출에 파일을 순서대로
전부 나열해 단일 `mysql` 커넥션으로 스트리밍한다(파일별 개별 파이프는
임시 테이블 소실 위험이 있다):

```bash
docker exec -e TZ=Asia/Seoul pitr-mysqlbinlog-tool \
  mysqlbinlog --start-position=<N> --stop-position=<M> \
    --disable-log-bin --binary-mode \
    /path/to/binlog-file-1 /path/to/binlog-file-2 \
  | docker exec -i pitr-restore-target mysql --user=root
```

`--disable-log-bin`은 재생된 이벤트가 다시 binlog에 기록되어 무한 루프·
중복을 일으키지 않도록 한다.

### 6단계: 검증 + 폐기

테이블 수·핵심 테이블 행 수·`MAX(trade_date)` 신선도를 확인한다(
`aaa-backup-restore-drill.sh`의 검증 쿼리와 동일한 관점):

```bash
docker exec pitr-restore-target mysql --user=root -N -B -e "
  SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='aaa';
  SELECT COUNT(*) FROM aaa.stocks;
  SELECT COUNT(*) FROM aaa.daily_ohlcv;
  SELECT MAX(trade_date) FROM aaa.daily_ohlcv;
"
```

검증이 끝나면 두 throwaway 컨테이너를 모두 폐기한다:

```bash
docker rm -f pitr-restore-target pitr-mysqlbinlog-tool
```

---

## 참조

- design.md §4 PITR 복원 절차 설계 — 본 런북 절차의 근거 문서
- spec.md REQ-DOC-002, AC-DOC-002 [HARD]
- `scripts/aaa-backup-restore-drill.sh` — 월 1회 자동 풀 덤프 복원 검증(이 런북의 1~2단계 + 6단계와 동일 패턴, binlog 재생은 제외)
- `scripts/backup-mysql.sh` — 풀 덤프(`--mode=full`) + binlog 아카이브(`--mode=binlog`) 생성 스크립트
- `research.md` §5 — binlog PITR 설계 요지(단일 커넥션 원칙의 근거)
- `research.md` §7 — mysqlbinlog 부재 및 온디맨드 확보 방식 실측 기록
