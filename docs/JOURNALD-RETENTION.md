# journald 보존 기간 확장 — 호스트 수동 절차

관련 SPEC: SPEC-OBSV-LOGS-004

## 배경

SPEC-OBSV-LOGS-004(M2/M4)로 `victoriametrics`/`vmalert`/`alertmanager`/
`victorialogs`/`vector`/`node-exporter`/`cadvisor` 7개 컨테이너의 로그
드라이버를 `json-file`에서 `journald`로 전환하고, vector가 이 중 6개
컨테이너(vector 자신은 제외 — 자기증폭 루프 방지)의 journald 로그를
VictoriaLogs로 재수집한다.

journald의 기본 보존량(`SystemMaxUse`)은 이 NAS(UGREEN DXP2800)에서
50M로 낮게 설정되어 있어, 로그 유입량이 늘면 오래된 로그가 빠르게
삭제(rotate)된다. vector가 재수집하기 전에 journald가 로그를 밀어내면
그 구간은 VictoriaLogs에도 도달하지 못하고 영구히 손실된다(REQ-015).

**이 절차는 호스트(NAS) systemd 설정 변경이며, 이 레포의 IaC(docker-compose.yml/
vector.yaml)로 자동화되지 않는다.** `SystemMaxUse`는 컨테이너 스택과 무관한
호스트 전역 설정이라 compose로 관리할 수 없고, 의도적으로 자동화하지 않는다
(plan.md §G 배제 항목).

## 대상 파일

`/etc/systemd/journald.conf` (NAS 호스트, 이 레포 바깥)

## 현재값 → 목표값

| 설정 | 현재값(베이스라인) | 목표값 |
|------|---------------------|--------|
| `SystemMaxUse` | `50M` | `512M` |

## 적용 절차

1. `/etc/systemd/journald.conf`를 열어 `SystemMaxUse=` 라인을 찾아
   `512M`로 수정한다(주석 처리(`#SystemMaxUse=`)된 상태라면 주석을
   해제하고 값을 채운다).

   ```bash
   sudo vi /etc/systemd/journald.conf
   ```

2. journald를 재시작해 변경을 적용한다.

   ```bash
   sudo systemctl restart systemd-journald
   ```

## 검증

```bash
systemd-analyze cat-config systemd/journald.conf | grep -i SystemMaxUse
```

`SystemMaxUse=512M`이 출력되어야 한다. 재시작 직후 journald가 기존
저널 파일을 새 상한 기준으로 재평가하므로, 곧바로 아래 보존 윈도우
측정도 함께 수행한다.

## 보존 윈도우 재확인 및 재-에스컬레이션 기준

```bash
journalctl --disk-usage
journalctl -o short-iso -n 1 --no-pager   # 가장 오래된 항목 시각 확인엔 --reverse 마지막 줄 참고
```

512M 적용 후 측정한 보존 윈도우(가장 오래된 유효 항목의 타임스탬프 ~
현재 시각)가 **60분 미만**이면, `512M`는 이 NAS의 실제 로그 유입량 대비
부족하다는 뜻이다. 이 경우:

- `512M`를 더 올리는 것은 **별도의 변경**으로 제안한다(이 절차를 반복
  적용하지 않고, 유입량 재측정 후 새 목표값을 정해 다시 이 문서의
  적용 절차를 따른다).
- 자동으로 값을 더 올리지 않는다 — 재-에스컬레이션은 항상 사람이
  측정값을 보고 결정한다.

## 이 절차로 해결되지 않는 경우

`SystemMaxUse`를 올려도 보존 윈도우가 늘지 않는다면, 디스크 자체의
여유 공간이 부족해 journald가 더 낮은 실제 상한(디스크 잔여 용량
기준)에 걸려 있을 가능성이 있다 — `df -h /var/log/journal`로 디스크
여유 공간을 먼저 확인한다. 디스크 공간 확보(별도 절차)가 선행돼야
`SystemMaxUse` 상향이 실제로 효과를 낸다.
