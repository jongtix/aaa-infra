# sshd db_tunnel Match 블록 복구 — 부팅 후 점검 절차

관련: SPEC-ANALYZER-TRAIN-AUTOMATION-001, aaa-infra#118(동일 재부팅 시각에
함께 발생한 것으로 추정되는 자매 결함)

## 배경

`db_tunnel` 계정은 맥북에서 나스 MySQL로 접근하는 유일한 통로다(D-19,
2026-07-05). 두 가지 용도를 공유한다:

- **IDE 접근**: DataGrip 등에서 사용자가 온디맨드로 여는 SSH 로컬
  포트포워딩(`-L 3306:127.0.0.1:3306`)
- **학습 자동화**: `SPEC-ANALYZER-TRAIN-AUTOMATION-001`의 원격 학습 CLI가
  같은 인프라를 재사용(REQ-ATA-093, 신규 프로비저닝 금지)

2026-07-05 구성 당시 `/etc/ssh/sshd_config`에 `Match User db_tunnel` 블록
(`AllowTcpForwarding yes` + `PermitOpen 127.0.0.1:3306` + `PermitTTY no` +
`ForceCommand nologin` + `PasswordAuthentication no`)을 추가해 DataGrip
접속을 실측 검증했다.

## 2026-08-13 실측 — 블록 소실 발견

`SPEC-ANALYZER-TRAIN-AUTOMATION-001` 수동 학습 실행 검증 중 `db_tunnel`
터널이 로컬 바인딩(리스닝)까지는 성공하지만 실제 연결 시 즉시 0바이트로
끊기는 증상을 발견했다:

```
paramiko.ssh_exception.SSHException: ... (실제로는 TCP는 붙지만 recv()가 0바이트)
```

원인 확인: `/etc/ssh/sshd_config`에 `Match` 블록이 **하나도 없고** 전역
`AllowTcpForwarding no`만 남아 있었다. 파일 수정 시각(`stat`)이
`2026-07-26 19:09:42`로, **#118 UGOS ACL 장애 복구 재부팅 시각과 정확히
일치**한다 — UGOS가 그 이벤트에서 공유폴더 ACL뿐 아니라 `sshd_config`도
함께 재생성한 것으로 추정된다. MySQL 자체는 나스 루프백에서 직접 접속 시
정상 응답했다(핸드셰이크 패킷 정상 수신) — 문제는 SSH 포워딩 계층에만
있었다.

## 즉시 복구

```bash
sudo bash scripts/restore-sshd-db-tunnel.sh
```

`Match User db_tunnel` 블록이 없으면 파일 끝에 추가하고 `sshd -t`로 문법
검증한 뒤 `systemctl reload ssh.service`(또는 `sshd.service`)로 재적용한다.
이미 블록이 있으면 아무 것도 하지 않는다(멱등).

## 재발 방지 — 부팅 시 자동 실행

```bash
sudo cp scripts/aaa-restore-sshd-tunnel.service /etc/systemd/system/
# ExecStart/WorkingDirectory 경로가 실제 배포 경로와 일치하는지 확인
sudo systemctl daemon-reload
sudo systemctl enable aaa-restore-sshd-tunnel.service
```

검증:

```bash
sudo systemctl status aaa-restore-sshd-tunnel.service
sudo journalctl -u aaa-restore-sshd-tunnel.service -b
```

`Before=ssh.service`로 지정돼 있어 sshd 자체가 기동하기 전에 블록을 파일에
써 넣는다 — `aaa-reset-acl.service`(사후 리셋)와 달리 사후 reload에
의존하지 않고 첫 기동부터 올바른 설정으로 뜬다. 다른 NAS 모델·UGOS
버전에 설치할 때는 반드시 실제 서비스명을 재확인한다:

```bash
systemctl list-units --type=service | grep -i ssh
```

유닛명이 `ssh.service`가 아니면 `aaa-restore-sshd-tunnel.service`의
`Before=`와 `restore-sshd-db-tunnel.sh`의 reload 대상 서비스명을 그에 맞게
수정해야 한다.

## 2026-08-31 재발 — 부팅 순서 버그로 자동 복구 자체가 실패

`aaa-restore-sshd-tunnel.service`를 설치해 둔 상태에서도 2026-08-30 16:46
재부팅 후 `Match User db_tunnel` 블록이 다시 소실됐다(원격 학습 재트리거
시 `pymysql`/raw TCP 모두 `admin­istratively prohibited`로 재현, `docker
logs aaa-mysql`엔 흔적 없음 — MySQL 도달 전 sshd 포워딩 계층에서 즉시
거부). 원인은 서비스 자체가 매 부팅 실패하고 있었던 것:

```
systemctl status aaa-restore-sshd-tunnel.service
  Active: failed (Result: exit-code)
  Main PID: 467 (code=exited, status=200/CHDIR)
```

`status=200/CHDIR`은 `WorkingDirectory=/volume1/SSD_1/Development/aaa/aaa-infra`로
chdir이 실패했다는 뜻이다. 원래 유닛 파일이 `After=local-fs.target`만
지정했는데, 이 시점엔 UGOS의 `/volume1/SSD_1` 마운트가 아직 준비되지
않는다 — `aaa-reset-acl.service`(#118)가 이미 동일한 함정을 겪고
`storage_serv.service`/`filemgr_serv.service`를 `After=`에 병기해
고쳤던 것과 정확히 같은 원인이다. `aaa-restore-sshd-tunnel.service`는
그 교훈이 반영되지 않은 채 배포돼 있었다. `Before=ssh.service`로
순서가 보장돼 sshd 시작 전에 실행은 되지만, 그 실행 자체가 매번
chdir 단계에서 죽어 아무 것도 복구하지 못한 채 부팅이 끝났다.

수정: `After=local-fs.target storage_serv.service filemgr_serv.service`로
병기(`aaa-restore-sshd-tunnel.service` 최신본 반영). 기존 설치본을
쓰고 있다면 재배포 후 `systemctl daemon-reload`가 필요하다.

## 재발 방지 — 주기 재실행 (재부팅 없이 발생하는 케이스)

`aaa-reset-acl` 계열(#148)에서 이미 확인된 것처럼, UGOS는 재부팅 없이도
백그라운드로 관리 대상 설정 파일을 재생성할 수 있다. 부팅 훅만으로는
이 경로를 놓치므로, 동일한 서비스를 짧은 주기로 재실행하는 타이머를
함께 등록한다:

```bash
sudo cp scripts/aaa-restore-sshd-tunnel.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now aaa-restore-sshd-tunnel.timer
```

검증:

```bash
sudo systemctl list-timers aaa-restore-sshd-tunnel.timer
sudo journalctl -u aaa-restore-sshd-tunnel.service --since "1 hour ago"
```

`restore-sshd-db-tunnel.sh`는 멱등적이다 — 블록이 이미 있으면 파일 수정도
reload도 하지 않고 즉시 종료하므로, ssh.service가 정상 기동 중인 상태에서
주기 실행해도 안전하다.

## 이 훅으로 해결되지 않는 경우

`db_tunnel` 계정의 `authorized_keys`(`restrict,port-forwarding,
permitopen="127.0.0.1:3306"` 옵션 + 전용 Ed25519 키)가 같은 사고로
함께 소실된 경우는 이 훅의 대상이 아니다 — sshd_config가 아니라 계정
홈 디렉토리 파일이라 별도 확인이 필요하다.

## 부팅 후 수동 점검

UGOS 업데이트 직후에는 자동 훅과 별개로 아래를 확인한다.

1. 맥북에서 `ssh -L 3306:127.0.0.1:3306 -p 55522 db_tunnel@<나스IP> -i <db_tunnel 전용 키>`로 터널 개설
2. `nc -zv 127.0.0.1 3306` 또는 DataGrip 접속 테스트로 실제 데이터 릴레이 확인(리스닝 여부만으로는 불충분 — 이번 사고의 증상 자체가 "리스닝은 되지만 릴레이만 거부")
