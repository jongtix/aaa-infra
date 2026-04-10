# ADR-018: GitHub Actions self-hosted runner 기반 CD 채택

- **상태**: 승인
- **일자**: 2026-04-06

---

## 맥락

기존 CD 파이프라인은 GitHub Actions가 GHCR에 이미지를 푸시하면, NAS에서 실행 중인 Watchtower가 1시간 주기로 GHCR을 폴링하여 새 이미지를 감지·배포하는 방식이었다.

이 방식에는 다음 한계가 있다.

- **배포 가시성 없음**: 배포 성공/실패 여부가 GitHub Actions UI에서 확인되지 않는다. 헬스체크 결과도 파악할 수 없어, 배포 직후 서비스 상태를 별도로 확인해야 한다.
- **race condition 위험**: GitHub Actions와 Watchtower가 독립적으로 동작하므로, 빌드 완료 직후 Watchtower가 동시에 컨테이너 교체를 시도하면 충돌 가능성이 있다.
- **폴링 지연**: 최대 1시간 지연이 발생한다. 긴급 패치 배포 시 즉시 반영이 불가능하다.
- **MAC 주소 충돌**: Watchtower는 `docker run`으로 단일 컨테이너를 교체한다. Docker Compose의 IPAM을 거치지 않으므로, 기존 컨테이너(MySQL 등)가 보유한 MAC 주소를 신규 컨테이너에 중복 할당하는 버그가 실제로 발생했다. 동일 네트워크에 MAC 주소가 중복된 컨테이너가 공존하면 ARP 충돌로 컨테이너 간 통신이 불가능해진다. collector 단독 배포 시 MySQL에 연결하지 못해 서비스가 기동되지 않았다.
- **Watchtower 아카이브**: containrrr/watchtower는 2025-12-17 아카이브됨. nicholas-fedor 포크([ADR-004](ADR-004-watchtower-fork.md))를 사용 중이나, 폴링 기반 CD 자체의 구조적 한계는 유지된다.

---

## 결정

GitHub Actions self-hosted runner(NAS)가 직접 배포를 실행하는 방식으로 전환한다.

배포 파이프라인:
```
main 푸시
  → Release (semantic-release)
  → Docker (GHCR 빌드 + 푸시)
  → Deploy (self-hosted runner에서 docker compose up 실행)
```

Deploy 단계에서 실행하는 명령:
```bash
docker compose --project-directory "$AAA_INFRA_DIR" up -d --wait --wait-timeout 180 collector
```

- `--wait`: healthcheck가 `healthy` 상태가 될 때까지 블로킹.
- `--wait-timeout 180`: 180초 이내에 healthy 상태가 되지 않으면 실패로 처리.
- 성공/실패가 GitHub Actions UI에서 즉시 확인된다.

Watchtower는 CD 역할에서 제거된다.

---

## 검토한 대안

### 대안 1: Watchtower 유지 — 기각

| 항목 | 내용 |
|------|------|
| 장점 | 별도 runner 설정 불필요, 현재 운영 중 |
| 단점 | 배포 결과 가시성 없음, race condition 위험, 폴링 지연, MAC 주소 충돌(실증), 구조적 한계 해결 불가 |

기각.

### 대안 2: Argo CD 등 GitOps 도구 — 기각

| 항목 | 내용 |
|------|------|
| 장점 | GitOps 표준 방식, 선언적 배포 상태 관리 |
| 단점 | Kubernetes 환경을 전제로 설계됨. Docker Compose 기반 NAS 환경에 도입 시 불필요한 복잡도 추가. 1인 소규모 프로젝트에 과도한 인프라 |

기각.

### 대안 3: GitHub Actions self-hosted runner (채택)

| 항목 | 내용 |
|------|------|
| 장점 | 배포 성공/실패 즉시 확인, `--wait`로 healthcheck 블로킹, race condition 제거, push 즉시 배포 |
| 단점 | NAS에 self-hosted runner 상시 실행 필요 |

채택.

---

## 결과

- 배포 성공/실패가 GitHub Actions UI에서 즉시 확인된다.
- `--wait` 옵션으로 healthcheck가 `healthy`가 될 때까지 블로킹하여, 배포 완료 시점에 서비스 정상 기동이 보장된다.
- GitHub Actions → Deploy 단계가 배포의 유일한 트리거가 되어 race condition이 제거된다.
- 폴링 지연이 없어 main 푸시 직후 배포가 완료된다.
- `docker compose up`은 Compose IPAM을 통해 네트워크 주소를 할당하므로, Watchtower 단독 교체 시 발생한 MAC 주소 중복 문제가 해소된다.

**트레이드오프**: NAS에 GitHub Actions self-hosted runner가 상시 실행되어야 한다. runner 프로세스가 중단되면 Deploy 단계가 실패한다. 단, 이 실패는 GitHub Actions UI에서 즉시 감지 가능하다.

**롤백 전략**:

배포 실패 시 처리 방식은 마이그레이션 포함 여부에 따라 갈린다.

마이그레이션 포함 여부는 `flyway_schema_history` DB 직접 조회로 감지한다. DB에 기록된 최신 성공 마이그레이션 버전(`version`)과 이미지에 포함된 최대 V번호를 비교하여, 이미지 버전이 더 크면 마이그레이션 포함으로 판단한다. DB 조회 실패(연결 불가, 버전 조회 오류) 또는 마이그레이션 파일 탐색 실패 시에는 안전을 위해 마이그레이션 있음으로 처리한다(fail-closed).

- **마이그레이션 없는 배포 실패**: deploy.yml이 자동으로 처리한다. Deploy 단계 시작 전에 현재 컨테이너의 이미지 digest(`RepoDigests`)를 저장해 두고, `--wait` 타임아웃 등으로 배포가 실패하면 이전 digest로 이미지를 pull한 뒤 `COLLECTOR_IMAGE` 환경변수로 주입하여 재기동한다. 이전 digest가 없는 경우(최초 배포)에는 롤백을 스킵한다.

  ```bash
  # 배포 전: 현재 실행 중인 컨테이너의 이미지 digest 저장
  PREV_DIGEST=$(docker inspect collector --format='{{index .RepoDigests 0}}' 2>/dev/null || echo "")

  # 배포 실패 시 (PREV_DIGEST가 존재하고 마이그레이션 없는 경우에만 실행):
  docker pull "$PREV_DIGEST"
  COLLECTOR_IMAGE="$PREV_DIGEST" \
    docker compose --project-directory "$AAA_INFRA_DIR" up -d --wait --wait-timeout 180 collector
  ```

- **마이그레이션 포함 배포 실패**: 자동 롤백이 불가능하다. 컨테이너 롤백 시점에 DB 스키마는 이미 변경된 상태이므로, 이전 이미지를 기동하면 스키마 불일치로 서비스가 정상 동작하지 않는다. deploy.yml은 이 케이스를 감지하여 텔레그램으로 "배포 실패 + 마이그레이션 포함 → 수동 롤백 필요" 알림을 발송한다. DB 스키마 롤백은 수동으로 처리해야 한다.

**Telegram 알림 케이스**:

배포 실패 시 알림은 세 케이스로 분기한다.

| 케이스 | 조건 | 알림 내용 |
|--------|------|-----------|
| 마이그레이션 포함 실패 | `has_migrations=true` | 🚨 배포 실패 + 수동 롤백 필요 |
| 자동 롤백 성공 | `rollback.outcome=success` | ⚠️ 배포 실패 + 자동 롤백 완료. Redis·캐시 포맷 변경 여부 수동 확인 요청 |
| 자동 롤백도 실패 | 그 외 | 🚨 배포 실패 + 자동 롤백도 실패 + 수동 개입 필요 |

  **Telegram 토큰 관리 방식**:

  - 봇 토큰(`TELEGRAM_BOT_TOKEN`)과 채팅 ID(`TELEGRAM_CHAT_ID`)는 GitHub Actions repo secret으로 관리한다.
  - Deploy job의 `env:` 블록을 통해서만 주입한다. 스텝 단위 env 선언이나 인라인 참조는 사용하지 않는다.
  - `echo "::add-mask::$BOT_TOKEN"` / `echo "::add-mask::$CHAT_ID"`로 명시적 마스킹을 적용하고, `set +x`로 명령어 echo를 비활성화하여 로그에 값이 출력되지 않도록 한다.
  - `curl -K -` 패턴으로 토큰을 URL에 직접 삽입하지 않고 stdin으로 전달하여, curl의 verbose 로그나 프로세스 목록에서도 토큰이 노출되지 않는다.
