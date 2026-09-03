# ADR-035: aaa-analyzer(Python) 구조화 로깅 전략 — 파일 sink 회전 상수의 총량 상한 등가성 판단 (ADR-011 Phase 2 공백 해소)

- **상태**: 승인
- **일자**: 2026-09-03
- **범위**: aaa-analyzer (ADR-011이 "Phase 2에서 별도 ADR로 결정한다"고 남긴 항목의 이행)

---

## 맥락

ADR-011은 aaa-collector·aaa-notifier·aaa-trader(Java/logback)의 구조화 로깅 전략(ECS JSON + SafeMdc)을 확정하면서, 본문 마지막 줄에 "aaa-analyzer(Python)의 구조화 로깅 및 trace_id 전파 전략은 Phase 2에서 별도 ADR로 결정한다"고 명시했다. 그러나 Phase 2 진행 중 그 후속 ADR은 작성되지 않았고, analyzer의 로깅은 SPEC-ANALYZER-FOUNDATION-001(구조화 JSON + KST + trace_id)과 SPEC-OBSV-LOGS-002(stdout 병행 파일 sink)에서 SPEC 단위로 결정됐다. 본 ADR은 그 공백을 사후에 메우되, 특히 **한 번도 명시적으로 판단된 적 없는 항목** — collector/notifier가 갖춘 `total-size-cap` 안전망에 대응하는 판단 — 을 기록하는 데 초점을 둔다.

### 현재 사실

- **analyzer 파일 sink**: `common/logging.py`의 `get_logger()`가 stdout `StreamHandler`와 함께 stdlib `RotatingFileHandler(maxBytes=10 * 1024 * 1024, backupCount=5)`를 부착한다(코드 상수 `_MAX_BYTES` / `_BACKUP_COUNT`, SPEC-OBSV-LOGS-002 확정값). 회전본은 `aaa-analyzer.log.N` 접미사로 남으며 gzip 압축은 없다.
- **collector/notifier 회전 정책**(ADR-011 결정 1, 양 서비스 `application.yml` 동일 블록): logback `rollingpolicy`로 `max-file-size: 1GB` + `max-history: 30`(연령 상한) + `total-size-cap: 50GB`(총량 상한) + gzip 압축. 연령과 총량의 **이중** 안전망이며, 둘 중 먼저 도달하는 쪽이 발동한다.
- **Python 표준 라이브러리 제약**: stdlib `RotatingFileHandler` / `TimedRotatingFileHandler`, 서드파티 `loguru`의 `retention=` 어디에도 logback `total-size-cap`("전체 회전본 총량 상한")의 직접 대응물이 없다.
- **컨테이너 제약**: `aaa-analyzer` 컨테이너는 마운트된 로그 볼륨을 제외하면 `read_only: true`이고 `cap_drop: [ALL]`이라 내부에 OS `cron`이 없다 — `logrotate`/cron 기반 보완 메커니즘은 배제된다.

---

## 결정

**analyzer는 `total-size-cap`에 대응하는 신규 코드 메커니즘을 도입하지 않는다.** 기존 회전 상수(`maxBytes=10 MiB`, `backupCount=5`)의 산술적 성질이 collector/notifier 안전망의 **의도 중 하나** — 디스크 사용량 무한 증가 방지 — 를 이미 충족한다고 판단하고, 그 판단 근거와 한계를 문서로만 기록한다(SPEC-OBSV-LOGS-003 DP-2 채택안).

### 1. 회전 상수의 결정론적 총량 상한

`RotatingFileHandler(maxBytes=10 MiB, backupCount=5)`는 **기록량과 무관하게** 활성 파일 1개 + 회전본 최대 5개(총 6개)만 항상 유지한다. 따라서 `aaa-analyzer.log` 파일군의 총 디스크 사용량은 항상 **결정론적으로 약 60 MiB 이하**로 유계(bounded)다. 이 상한은 로그 볼륨·실행 시간·재시작 횟수 어느 것에도 의존하지 않는다.

### 2. "동등한 의도" 주장의 범위 한정 — 무한 증가 방지에 한함

위 상한이 logback `total-size-cap: 50GB`와 "동등하다"는 비교는 **디스크 사용량이 무한정 증가하지 않는다는 의도 하나에 대해서만** 성립한다. **이 비교는 사고 조사(incident investigation)용 보존 기간의 동등성을 함의하지 않는다.**

logback 정책에서 `total-size-cap`은 드물게 발동하는 백스톱이고, 실질적 1차 보존 메커니즘은 `max-history: 30`(연령 상한)이다 — 그 목적은 사고 조사를 위해 넉넉한 30일 보존 창을 확보하는 것이다. `RotatingFileHandler`에는 이에 대응하는 **연령 기반 보존 메커니즘이 전혀 없으며**, 약 60 MiB 상한(logback 50GB 대비 약 850배 작음)이 실제로 보존하는 기간은 로그 볼륨에 따라 달라진다. analyzer의 회전은 **크기 기준**이지 **경과 시간 기준**이 아니므로, 보존 기간은 고정값이 아니라 로그 발생 속도의 함수다. analyzer 전체 메커니즘을 logback 이중 정책의 백스톱 절반하고만 비교하는 것은 진정한 패리티 비교가 아니며, 본 ADR은 그런 주장을 하지 않는다.

### 3. 현재 관측 볼륨 기준 보존 기간 — 정성적 추정(정밀 산정 아님)

2026-09-03 라이브 NAS 실측(`docker exec aaa-analyzer`)에서 활성 파일 `aaa-analyzer.log`는 **81KB**로, 단일 회전 파일 상한(10 MiB)의 **약 0.8%**에 불과했다. 현재의 저볼륨 스캐폴딩 단계 로깅 속도에서는 회전이 자주 발생하지 않으며 상한 도달까지 상당한 여유가 있는 것으로 관측된다.

다만 **이 값은 단일 시점 스냅샷이며 정밀 산정이 아니다** — 관측 시점 기준으로 그 파일이 누적된 기간(마지막 재시작/배포 시점)을 알 수 없으므로, 이 관측만으로 실제 보존 기간이 며칠인지 몇 주인지 몇 개월인지를 확정할 수 없다. 정확한 보존 기간은 배포·재시작 이력과 향후 로그 볼륨에 따라 달라지며, 본 ADR 시점에 정밀 산정되지 않았다.

### 4. 재검토 조건

다음 중 하나가 관측되면 본 결정을 새 SPEC으로 재검토한다.

- analyzer 로그 볼륨이 크게 증가해(예: 회전 주기가 분 단위로 짧아짐) 약 60 MiB 상한이 관측 가능한 히스토리를 과도하게 짧게 만드는 경우 — 커스텀 총량 관리 또는 `backupCount` 상향을 검토한다.
- 위 3항의 보존 기간 추정이 단일 시점 스냅샷 기반이라는 한계 자체도 재검토 트리거다 — 다시점 관측으로 실제 회전 주기가 측정되면 그 값으로 판단을 갱신한다.
- 사고 조사에서 필요한 보존 창이 실제로 확인되어(즉, 연령 기반 보존이 요구사항이 되어) 크기 기반 회전만으로 불충분해지는 경우.

향후 재검토를 거쳐 코드 메커니즘이 도입되는 경우에도, 그 메커니즘의 실패는 analyzer의 stdout/파일 로깅을 중단시켜서는 안 된다(fail-open — SPEC-OBSV-LOGS-002 REQ-LOGS-006이 확립한 원칙을 계승한다).

---

## 검토한 대안

### 대안 1 — 회전 후처리 커스텀 총량 관리 코드 신설 — 기각

| 항목 | 내용 |
|------|------|
| 장점 | logback `total-size-cap`과 형태적으로 대응하는 메커니즘 확보, 향후 볼륨 증가 시에도 총량 정책을 명시적으로 조정 가능 |
| 단점 | analyzer가 여전히 저볼륨 스캐폴딩 단계이며 기존 산술 상한이 이미 무조건적으로 유계 보장을 제공, 회전 후처리 훅은 stdlib 표준 경로 밖이라 fail-open 처리·테스트 부담이 추가 |

기각. 이미 결정론적으로 유계인 대상에 총량 관리 코드를 얹는 것은 과잉 엔지니어링이다. 재검토 조건(위 4항)이 발동하면 그때 별도 SPEC으로 도입한다.

### 대안 2 — `TimedRotatingFileHandler`로 전환해 연령 기반 보존 확보 — 기각

| 항목 | 내용 |
|------|------|
| 장점 | logback `max-history: 30`에 대응하는 연령 상한을 직접 얻는다 |
| 단점 | 크기 상한이 사라져 단일 기간 내 폭증 시 무한 증가 방지 보장을 잃는다(현 결정이 확보한 유일한 강한 성질을 포기), 두 축을 동시에 얻으려면 결국 커스텀 코드가 필요해 대안 1과 같은 비용으로 수렴 |

기각. 지금 확보된 성질(무조건적 유계)을 아직 요구사항이 아닌 성질(30일 보존 창)과 맞바꾸는 거래다.

### 대안 3 — 호스트 `logrotate`/cron으로 총량 관리 — 기각

컨테이너 `read_only: true` + `cap_drop: [ALL]`로 내부 cron이 없고, 호스트 측 스케줄러를 새로 도입하면 신규 운영 부담이 생긴다(SPEC-OBSV-LOGS-002 DP-1 B안 기각 사유와 동일). 또한 vector가 `/var/log/aaa-analyzer/*.log`를 inode 기반 체크포인트로 실시간 tail 중이라 외부 도구의 rename/truncate가 수집을 깨뜨릴 위험이 있다.

### 대안 4 — v0.1.0 표현 "오히려 더 강한 보장" 유지 — 기각

약 60 MiB 결정론적 상한이 logback 50GB cap보다 "더 강하다"는 서술은 logback 이중 안전망의 백스톱 절반만 비교한 일면적 주장이다. 연령 상한(`max-history: 30`)에 대응물이 없다는 사실을 감춘다. 범위를 "디스크 사용량 무한 증가 방지"로 명시적으로 한정하는 위 2항 서술로 대체했다.

---

## 결과

- `aaa-analyzer.log` 파일군은 코드 변경 없이 약 60 MiB 이하로 유계이며, 이 성질은 로그 볼륨과 무관하게 성립한다.
- collector/notifier(ADR-011)와 analyzer(본 ADR)의 로깅 정책은 "디스크 무한 증가를 막는다"는 의도를 공유하되 **보존 기간 특성은 다르다** — Java 서비스는 30일 연령 창을 보장하고, analyzer는 크기 기준 회전이라 보존 기간이 볼륨에 따라 변동한다. 사고 조사 시 analyzer 로그의 소급 가능 범위가 collector/notifier보다 짧을 수 있다는 점을 운영상 인지해야 한다. 다만 analyzer 로그는 vector → VictoriaLogs로도 수집되며(ADR-029), 디스크 파일은 로컬 백업 sink 성격이다.
- ADR-011 본문의 "Phase 2에서 별도 ADR로 결정한다" 항목은 본 ADR로 이행 완료됐다. 구조화 JSON 포맷·KST 타임스탬프·trace_id 전파의 구체 사항은 SPEC-ANALYZER-FOUNDATION-001 / SPEC-OBSV-LOGS-002에 이미 확정되어 있으며, analyzer는 Java(logback ECS 스키마)와 스키마를 강제로 맞추지 않는다(SPEC-OBSV-LOGS-002 §3 Exclusion #1 — 필드 정합은 vector in-flight transform이 담당).
- 회전 상수(`maxBytes=10 MiB`, `backupCount=5`)는 SPEC-OBSV-LOGS-002 확정값 그대로 유지되며 본 ADR은 이를 변경하지 않는다. 동일한 판단 근거가 `common/logging.py` 모듈 docstring에도 기록된다(SPEC-OBSV-LOGS-003 M3).
