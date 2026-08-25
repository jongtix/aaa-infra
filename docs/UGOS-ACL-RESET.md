# UGOS ACL 리셋 — 부팅 후 점검 절차

관련 이슈: aaa-infra#118

## 배경

UGOS 소프트웨어 업데이트가 공유폴더(SSD_1/HDD_1)에 UGOS 전용 ACL을 재적용하면,
NAS에 등록되지 않은 컨테이너 uid(999/1004/1005/1006/65534)의 파일 open이 커널
레벨에서 거부된다. 영향받는 컨테이너: `aaa-mysql`, `aaa-redis`,
`aaa-alertmanager`, `aaa-vector` (전부 비루트 uid로 로그·상태 파일을 씀).

2026-07-25 실측(#118)에서 확인된 사실:
- ACL 재적용은 업데이트 설치·재부팅 시점이 아니라 **그 이전 단계에서 이미 적용**되어 있었다.
  이미 열려 있던 fd로 쓰던 프로세스는 재부팅 전까지 생존하다가, 재부팅으로 재오픈이
  강제되는 순간 한꺼번에 사망했다.
- `data/mysql`, `data/redis`는 이 ACL 재적용 대상이 아니었다(무손상 확인). 재발 시에도
  이 두 디렉토리는 리셋 대상에서 제외한다 — 라이브 DB 파일에 불필요한 재귀 chown을
  가하지 않기 위함이다.
- 기존 `init-nas.sh`의 Step 3 chown은 **디렉토리 자체만** 리셋하고 비재귀라, 이미 ACL이
  걸린 기존 파일(`redis.log` 등)은 리셋되지 않는다. 이번 문서가 다루는 `--reset-acl`
  모드는 이 갭을 메운다.

## 즉시 복구 — `--reset-acl` 모드

```bash
sudo bash scripts/init-nas.sh --reset-acl
docker compose up -d
```

`logs/mysql`, `logs/redis`, `logs/aaa-collector`, `logs/aaa-analyzer`,
`logs/aaa-notifier`, `data/alertmanager`, `data/vector`를 하위 파일까지
재귀로 `chown` + `chmod`(디렉토리 750 / 파일 640) 리셋한다. `data/mysql`,
`data/redis`는 대상에서 제외된다.

## 재발 방지 — 부팅 시 자동 실행

`scripts/aaa-reset-acl.service`를 systemd에 등록하면 도커 기동 전에
매 부팅마다 자동으로 리셋을 수행한다.

```bash
sudo cp scripts/aaa-reset-acl.service /etc/systemd/system/
# ExecStart/WorkingDirectory 경로가 실제 배포 경로와 일치하는지 확인
sudo systemctl daemon-reload
sudo systemctl enable aaa-reset-acl.service
```

검증:

```bash
sudo systemctl status aaa-reset-acl.service
sudo journalctl -u aaa-reset-acl.service -b
```

**순서 지정 실측 (UGREEN DXP2800, 2026-07-26)**: `docker.service`는
`UnitFileState=disabled`이고 `docker.socket` 소켓 활성화로만 뜬다 — 부팅
체인에 정적으로 편입되지 않으므로 `Before=docker.service` 단독으로는 순서가
보장되지 않는다. 실제 부팅 체인은
`multi-user.target → docker_serv.service(enabled, WantedBy=multi-user.target)
→ docker.socket(WantedBy=docker_serv.service) → docker.service`이며,
`docker_serv.service`(UGOS 자체 도커 관리자)의 시작 시각이 2026-07-25 장애
당시 재부팅 시각(19:18:40 KST)과 정확히 일치해 실제 진입점으로 확인됐다.
유닛은 이를 반영해 `Before=docker_serv.service docker.socket docker.service`,
`After=local-fs.target storage_serv.service filemgr_serv.service`로 지정돼
있다. **다른 NAS 모델·UGOS 버전에 설치할 때는 반드시 재확인**:

```bash
systemctl list-units --type=service --all | grep -i docker
systemctl show docker_serv.service -p WantedBy,After   # (또는 실제 도커 관리 유닛명)
```

유닛명이 다르면 `aaa-reset-acl.service`의 `Before=`/`After=`를 그에 맞게
수정해야 순서 보장이 성립한다.

## 이 유닛으로 해결되지 않는 경우

`docker_serv.service`(또는 대상 NAS의 실제 도커 관리 유닛) 자체나 systemd가
UGOS 업데이트로 손상되는 경우(예: GitHub Actions self-hosted runner 유닛이
`203/EXEC`로 죽은 전례)는 이 훅 자체가 실행되지 않는다. 이 훅은 "ACL만
재적용되고 나머지는 정상"인 케이스를 자동 복구하는 것이 목적이며,
컨테이너 스택 전체가 죽는 상황을 외부에서 감지하는 별도 경로(호스트 cron
하트비트 등)는 이 훅과 무관하게 갖춰야 한다.

## 부팅 후 수동 점검 체크리스트

UGOS 업데이트 직후에는 자동 훅과 별개로 아래를 확인한다.

1. `docker ps` — 11개 컨테이너 전부 `Up`, healthcheck 있는 컨테이너는
   전부 `healthy`인지 확인
2. `docker exec aaa-mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot -e "SELECT 1"'`
   로 mysql 응답 확인 — 이 명령은 사람이 직접 실행하는 수동 root 1회성 점검이므로
   기존 `MYSQL_PWD` 관례를 그대로 유지한다. SPEC-INFRA-DB-BACKUP-001 M8부터 프로젝트의
   자동화/스크립트 경로(CI 워크플로, ops 스크립트)는 별도로 `--defaults-extra-file`
   방식을 사용하며, 두 관례는 병행 유지된다(REQ-MIG-002(b)).
3. `aaa-victoriametrics`는 `restart: unless-stopped`이어도 재부팅 전
   정상 종료 상태였다면 자동 기동되지 않을 수 있다 — `docker compose up -d`
   로 명시적으로 기동 상태를 맞춘다
