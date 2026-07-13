#!/usr/bin/env bash
# =============================================================================
# CD 배포 후 헬스 검증 — SPEC-INFRA-CICD-001 T-005
# =============================================================================
# `.github/deploy/`에 배치한다(`scripts/`가 아님 — plan.md §1.3, lib.sh/reflect.sh와
# 동일 원칙). `deploy.yml`에서 `lib.sh`(및 필요 시 `reflect.sh`)와 함께 `source`로
# 불러 쓰는 함수 모음이다. 직접 실행 대상이 아니다.
#
# reflect.sh(reflect_deploy)의 출력(UP:/RESTART:/SIGHUP:/DEDUP_DROPPED_RESTART:/
# NOTIFY:)을 입력으로 받아, 경로별로 다른 검증 전략을 적용한다:
#
#   - UP:<service>        (REQ-CD-013 compose --wait 경로) → REQ-CD-018:
#     compose 자체의 `--wait` 게이팅이 이미 헬스 검증을 수행했으므로 별도
#     `docker inspect` 호출을 하지 않는다(AC-CD-010, 중복 검증 금지).
#   - RESTART:<container> (REQ-CD-009/010, vmalert·alertmanager) → REQ-CD-018A:
#     `.State.Health.Status`가 healthy가 될 때까지 폴링, 타임아웃 시 실패.
#   - RESTART:<container> (REQ-CD-011, vector) → REQ-CD-018B:
#     vector는 compose·이미지 모두 healthcheck가 없다(V-4 실측:
#     `docker inspect timberio/vector:0.56.0-debian` → `Config.Healthcheck=null`).
#     `.State.Status`가 running이 될 때까지 grace period 동안 폴링, 미도달 시
#     실패(REQ-CD-018B 부정절, AC-CD-006B — 크래시루프·즉시 종료 포함).
#   - SIGHUP:/DEDUP_DROPPED_RESTART:/NOTIFY: → 검증 대상 아님(컨테이너 재시작 자체가
#     없거나(SIGHUP, REQ-CD-012), 이미 다른 라인에서 커버됨(DEDUP), 통지 전용(NOTIFY)).
#   - victoriametrics(SIGHUP 경로)는 애초에 검증 대상이 아니다 — 재시작이 아니므로
#     헬스 상태 변화 자체가 없다(§8 DP-3, plan.md 4.2 7단계).
#
# 테스트 시딩 포인트(verify_test.sh):
#   - _docker_inspect: 실제 `docker inspect`를 호출하는 유일한 함수. 테스트는
#     source 이후 이 함수를 재정의해 canned 상태값을 순서대로 반환한다.
#   - _verify_sleep: 폴링 간 대기를 담당하는 유일한 함수. 테스트는 이를 no-op으로
#     재정의해 실시간 대기 없이 폴링 루프를 검증한다.
#   - REFLECT_CALL_LOG(reflect.sh와 공유하는 파이프라인 호출 로그): 설정 시
#     INSPECT: 이벤트가 순서대로 append된다(AC-CD-010: UP: 경로에 INSPECT: 부재 검증용).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

# REQ-CD-018A 경로(단순 docker restart 후 health-status 폴링) 대상 컨테이너.
HEALTH_STATUS_CONTAINERS=(aaa-vmalert aaa-alertmanager)

# REQ-CD-018B 경로(vector 전용, healthcheck 없음 → running+grace period) 대상 컨테이너.
RUNNING_GRACE_CONTAINERS=(aaa-vector)

# reflect.sh가 이미 _call_log_append를 정의했다면 재정의하지 않는다(동일 로직,
# REFLECT_CALL_LOG 하나를 reflect.sh/verify.sh/rollback.sh가 공유하는 파이프라인
# 호출 로그로 사용). verify.sh 단독 source(verify_test.sh)에서도 동작하도록
# 미정의 시에만 자체 정의한다.
if ! declare -F _call_log_append > /dev/null 2>&1; then
  _call_log_append() {
    [ -n "${REFLECT_CALL_LOG:-}" ] || return 0
    printf '%s\n' "$1" >> "$REFLECT_CALL_LOG"
  }
fi

# -----------------------------------------------------------------------------
# docker inspect 실행 간접화 — 이 파일에서 실제 `docker inspect`를 호출하는
# 유일한 지점. 테스트는 source 이후 이 함수를 재정의해 canned 상태를 반환한다.
# -----------------------------------------------------------------------------
_docker_inspect() {
  # $1=container $2=go-template format
  _call_log_append "INSPECT:$1 $2"
  docker inspect --format="$2" "$1" 2>/dev/null
}

# 폴링 간 대기 간접화 — 테스트는 no-op으로 재정의해 실시간 대기를 제거한다.
_verify_sleep() {
  sleep "$1"
}

_is_in_list() {
  local needle="$1" hay
  shift
  for hay in "$@"; do
    [ "$needle" = "$hay" ] && return 0
  done
  return 1
}

# poll_health_status <container> [timeout=180] [interval=5]
# REQ-CD-018A: `.State.Health.Status` == healthy 도달까지 폴링. 도달 즉시 종료
# (전체 timeout까지 대기하지 않음). 타임아웃 내 미도달 시 실패(return 1).
poll_health_status() {
  local container="$1" timeout="${2:-180}" interval="${3:-5}"
  local elapsed=0 status
  while [ "$elapsed" -lt "$timeout" ]; do
    status=$(_docker_inspect "$container" '{{.State.Health.Status}}')
    if [ "$status" = "healthy" ]; then
      return 0
    fi
    _verify_sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  return 1
}

# poll_running_status <container> [grace_period=30] [interval=5]
# REQ-CD-018B: vector 전용. health 필드가 없으므로(V-4) `.State.Status == running` +
# 고정 grace period로 검증한다. 도달 즉시 종료. grace period 마지막 순간에 도달한
# 경우도 성공으로 처리한다(acceptance.md 엣지 케이스 — 경계 포함). grace period
# 경과 후에도 running 미도달이면 실패(REQ-CD-018B 부정절, AC-CD-006B — 크래시루프·
# 즉시 종료 포함).
poll_running_status() {
  local container="$1" grace_period="${2:-30}" interval="${3:-5}"
  local elapsed=0 status
  while [ "$elapsed" -lt "$grace_period" ]; do
    status=$(_docker_inspect "$container" '{{.State.Status}}')
    if [ "$status" = "running" ]; then
      return 0
    fi
    _verify_sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  # grace period 마지막 순간(경계값) 최종 확인 — 위 루프는 elapsed==grace_period에서
  # 종료되어 그 시점의 상태를 아직 확인하지 않았으므로 한 번 더 확인한다.
  status=$(_docker_inspect "$container" '{{.State.Status}}')
  [ "$status" = "running" ]
}

# verify_reflect_result <reflect_result> [health_timeout=180] [vector_grace=30] [interval=5]
# reflect_deploy의 출력을 소비해 경로별 검증을 수행한다.
# stdout: VERIFY_PASS:<container> / VERIFY_FAIL:<container> / VERIFY_SKIP_COMPOSE_WAIT:<service> 라인.
# 전역 배열 VERIFY_FAILED_CONTAINERS에 실패한 컨테이너명을 채운다(rollback.sh 소비용).
# return: 0(전부 통과 또는 검증 대상 없음) / 1(하나 이상 실패).
VERIFY_FAILED_CONTAINERS=()
verify_reflect_result() {
  local result="$1" health_timeout="${2:-180}" vector_grace="${3:-30}" interval="${4:-5}"
  VERIFY_FAILED_CONTAINERS=()
  local line container overall=0

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      RESTART:*)
        container="${line#RESTART:}"
        if _is_in_list "$container" "${HEALTH_STATUS_CONTAINERS[@]}"; then
          if poll_health_status "$container" "$health_timeout" "$interval"; then
            printf 'VERIFY_PASS:%s\n' "$container"
          else
            printf 'VERIFY_FAIL:%s\n' "$container"
            VERIFY_FAILED_CONTAINERS+=("$container")
            overall=1
          fi
        elif _is_in_list "$container" "${RUNNING_GRACE_CONTAINERS[@]}"; then
          if poll_running_status "$container" "$vector_grace" "$interval"; then
            printf 'VERIFY_PASS:%s\n' "$container"
          else
            printf 'VERIFY_FAIL:%s\n' "$container"
            VERIFY_FAILED_CONTAINERS+=("$container")
            overall=1
          fi
        fi
        ;;
      UP:*)
        # REQ-CD-018/AC-CD-010: compose --wait 자체가 헬스 게이팅 — 중복 inspect 없음.
        printf 'VERIFY_SKIP_COMPOSE_WAIT:%s\n' "${line#UP:}"
        ;;
      *) ;;
    esac
  done < <(printf '%s\n' "$result")

  return "$overall"
}
