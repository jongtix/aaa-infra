#!/usr/bin/env bash
# =============================================================================
# CD 서비스별 최소 반영 로직 — SPEC-INFRA-CICD-001 T-004 (최고위험 마일스톤)
# =============================================================================
# `.github/deploy/`에 배치한다(`scripts/`가 아님 — plan.md §1.3, lib.sh와 동일 원칙).
# 이 파일은 `deploy.yml`에서 `lib.sh`와 함께 `source`로 불러 쓰는 함수 모음이다.
# 직접 실행 대상이 아니다.
#
# [HARD] 불변식(REQ-CD-014/016/017, REQ-CD-013A):
#   - mysql·redis 컨테이너는 이 파일의 어떤 함수를 통해서도 restart/up/kill 대상이
#     되지 않는다. compose_classify는 mysql·redis 서비스 블록 변경을 감지해도
#     UP: 라인을 절대 내지 않는다(NOTIFY:만 낸다) — OBSERVED_SERVICES 화이트리스트에
#     mysql·redis가 없으므로 구조적으로 불가능하다.
#   - config/redis/users.acl 경로는 이 파일 어디에도 등장하지 않는다(읽기/쓰기/비교
#     전부 없음). DB 런타임 config(my.cnf/redis.conf) 파일도 동기화하지 않고
#     detect_db_config_diff로 감지해 통지만 한다(REQ-CD-015).
#   - collector·analyzer 서비스명은 compose-up 호출 인자(_docker_cmd compose up ...)에
#     절대 등장하지 않는다 — OBSERVED_SERVICES 화이트리스트 밖이고, 두 서비스 블록이
#     변경되면 compose_classify가 전체를 NOTIFY-only로 조기 반환(blocking)한다.
#
# 실행 순서(V-5, spec.md §5): compose diff 분류(구 vs 신, 부작용 없음) →
#   전체 config 파일 동기화(fixed 4종 + scripts/ + docker-compose.yml, blocked 아닐 때만) →
#   단순 restart/SIGHUP(V-5 dedup 적용) → compose-up(항상 마지막).
#
# 테스트 시딩 포인트(reflect_test.sh):
#   - _docker_cmd: 실제 docker를 호출하는 유일한 함수. 테스트는 source 이후 이 함수를
#     재정의해 실제 docker 대신 REFLECT_CALL_LOG에 기록만 하도록 오버라이드한다.
#   - REFLECT_CALL_LOG: 설정 시 SYNC:/DOCKER: 이벤트가 순서대로 append된다(V-5 순서 검증용).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

# 관측 서비스 목록(REQ-CD-013) — compose 자동 반영(`docker compose up`) 대상 화이트리스트.
# mysql·redis·collector·analyzer는 절대 포함하지 않는다([HARD]).
OBSERVED_SERVICES=(vmalert alertmanager victoriametrics victorialogs vector node-exporter)

# docker-compose.yml 안에 정의된 전체 서비스 이름(블록 diff 분류용). mysql/redis/
# collector/analyzer도 포함하지만, 이는 그 블록이 변경됐을 때 "관측 서비스가 아니므로
# up 대상에서 제외 + notify"로 올바르게 분류하기 위함이지 up 대상으로 삼기 위함이 아니다.
_ALL_KNOWN_SERVICES=(mysql redis collector analyzer victoriametrics vmalert alertmanager victorialogs vector node-exporter)

# -----------------------------------------------------------------------------
# docker 명령 실행 간접화 — 이 파일에서 실제 `docker ...`를 호출하는 유일한 지점.
# -----------------------------------------------------------------------------
# 테스트는 source 이후 이 함수를 재정의(오버라이드)해 실제 docker 대신 호출을
# 캡처한다. 프로덕션 경로(deploy.yml)에서는 기본 동작(실제 docker 실행)을 사용한다.
_docker_cmd() {
  _call_log_append "DOCKER:$*"
  docker "$@"
}

# 호출 이력 — 테스트가 순서(V-5: config 동기화가 compose-up보다 항상 먼저)와
# 부재(예: mysql/redis 관련 DOCKER: 라인이 전혀 없음)를 검증하는 데 쓴다.
# REFLECT_CALL_LOG 미설정 시 아무 것도 기록하지 않는다(프로덕션 기본값).
_call_log_append() {
  [ -n "${REFLECT_CALL_LOG:-}" ] || return 0
  printf '%s\n' "$1" >> "$REFLECT_CALL_LOG"
}

# -----------------------------------------------------------------------------
# docker-compose.yml 블록 추출/diff 분류 (REQ-CD-013/013A/017)
# -----------------------------------------------------------------------------

# _extract_block <file> <header_regex> <sibling_regex>
# header_regex에 매치하는 첫 줄부터, sibling_regex에 매치하는 다음 줄 직전까지 출력.
# header를 못 찾으면(블록 자체가 없음) 빈 문자열 출력.
_extract_block() {
  local file="$1" header="$2" sibling="$3"
  [ -f "$file" ] || return 0
  awk -v header="$header" -v sibling="$sibling" '
    BEGIN { capture=0 }
    $0 ~ header { capture=1; print; next }
    capture && $0 ~ sibling { exit }
    capture { print }
  ' "$file"
}

# compose_top_level_shared_changed <old_file> <new_file>
# REQ-CD-013A(a): x-logging 앵커 + networks: 블록. 둘 중 하나라도 다르면 0(true).
compose_top_level_shared_changed() {
  local old="$1" new="$2" key old_block new_block
  for key in 'x-logging' 'networks'; do
    old_block=$(_extract_block "$old" "^${key}:" '^[A-Za-z]')
    new_block=$(_extract_block "$new" "^${key}:" '^[A-Za-z]')
    if [ "$old_block" != "$new_block" ]; then
      return 0
    fi
  done
  return 1
}

# compose_changed_service_blocks <old_file> <new_file>
# _ALL_KNOWN_SERVICES 중 자기 2-space 블록이 old/new 사이에 달라진 서비스명을 한 줄씩 출력.
compose_changed_service_blocks() {
  local old="$1" new="$2" svc old_block new_block
  for svc in "${_ALL_KNOWN_SERVICES[@]}"; do
    old_block=$(_extract_block "$old" "^  ${svc}:" '^  [A-Za-z0-9_-]\{1,\}:')
    new_block=$(_extract_block "$new" "^  ${svc}:" '^  [A-Za-z0-9_-]\{1,\}:')
    if [ "$old_block" != "$new_block" ]; then
      printf '%s\n' "$svc"
    fi
  done
}

_is_observed_service() {
  local svc="$1" o
  for o in "${OBSERVED_SERVICES[@]}"; do
    [ "$svc" = "$o" ] && return 0
  done
  return 1
}

# compose_classify <old_file> <new_file>
# 부작용 없음(파일 동기화·docker 호출 전혀 없음) — 순수 분류 함수.
# stdout: UP:<service> (관측 서비스 자기 블록만 변경 → compose-up 대상) /
#         NOTIFY:<reason> (blocking 또는 mysql/redis 블록 변경) 라인만 출력.
# [HARD] mysql·redis·collector·analyzer에 대해서는 UP: 라인을 절대 내지 않는다.
compose_classify() {
  local old="$1" new="$2"
  local changed_services=()
  local svc

  if [ "$(cat "$old" 2>/dev/null)" = "$(cat "$new" 2>/dev/null)" ]; then
    return 0
  fi

  while IFS= read -r svc; do
    [ -n "$svc" ] && changed_services+=("$svc")
  done < <(compose_changed_service_blocks "$old" "$new")

  local blocking=0
  if compose_top_level_shared_changed "$old" "$new"; then
    blocking=1
  fi
  if [ "${#changed_services[@]}" -gt 0 ]; then
    for svc in "${changed_services[@]}"; do
      case "$svc" in
        collector|analyzer) blocking=1 ;;
      esac
    done
  fi

  if [ "$blocking" -eq 1 ]; then
    printf 'NOTIFY:compose 변경 감지 — 수동 검토 필요(공유 top-level 또는 collector/analyzer)\n'
    return 0
  fi

  local mysql_redis_hit=0
  if [ "${#changed_services[@]}" -gt 0 ]; then
    for svc in "${changed_services[@]}"; do
      case "$svc" in
        mysql|redis) mysql_redis_hit=1 ;;
        *)
          if _is_observed_service "$svc"; then
            printf 'UP:%s\n' "$svc"
          fi
          ;;
      esac
    done
  fi

  if [ "$mysql_redis_hit" -eq 1 ]; then
    printf 'NOTIFY:mysql/redis 서비스 정의 변경 감지 — up 대상에서 제외(재시작 없음)\n'
  fi

  return 0
}

# -----------------------------------------------------------------------------
# 단순 config-restart / SIGHUP 매핑 (REQ-CD-009~012)
# -----------------------------------------------------------------------------

# _config_restart_target <repo_rel> → "container_name:compose_service_name"
# compose_service_name은 V-5 dedup(같은 서비스가 compose-up 대상이면 restart 드롭) 판별용.
_config_restart_target() {
  case "$1" in
    config/vmalert/rules.yml) printf 'aaa-vmalert:vmalert\n' ;;
    config/alertmanager/alertmanager.yml) printf 'aaa-alertmanager:alertmanager\n' ;;
    config/vector/vector.yaml) printf 'aaa-vector:vector\n' ;;
    *) return 1 ;;
  esac
}

# _config_sighup_target <repo_rel> → container_name. REQ-CD-012: 컨테이너 재시작 없음(SIGHUP만).
_config_sighup_target() {
  case "$1" in
    config/victoriametrics/scrape.yml) printf 'aaa-victoriametrics\n' ;;
    *) return 1 ;;
  esac
}

restart_container() {
  # $1=container_name
  _docker_cmd restart "$1"
}

sighup_container() {
  # $1=container_name — REQ-CD-012: 컨테이너 재시작이 아닌 SIGHUP hot reload.
  _docker_cmd kill -s HUP "$1"
}

# sync_config_file <src(checkout)> <target(nas path)>
# 덮어쓰기 전 백업은 deploy.yml의 별도 스텝(T-003, lib.sh backup_file)에서 이미 수행됨 —
# 이 함수는 순수 동기화(복사)만 담당한다.
sync_config_file() {
  local src="$1" target="$2"
  _call_log_append "SYNC:$target"
  mkdir -p "$(dirname "$target")"
  cp -p "$src" "$target"
}

# -----------------------------------------------------------------------------
# DB 서비스 config 무동기화 불변식 (REQ-CD-015, [HARD] REQ-CD-016)
# -----------------------------------------------------------------------------
# users.acl은 어떤 이유로도 이 목록에 포함하지 않는다 — 절대 읽지도 접근하지도 않는다.
_DB_CONFIG_FILES=(
  "config/mysql/my.cnf"
  "config/redis/redis.conf"
)

# detect_db_config_diff <checkout_dir> <ssd_base>
# repo-NAS 간 diff가 있는 DB runtime config 파일의 repo-relative 경로를 한 줄씩 출력.
# 이 함수는 동기화를 절대 수행하지 않는다(호출측이 NOTIFY 용도로만 소비).
detect_db_config_diff() {
  local checkout_dir="$1" ssd_base="$2" rel src target
  for rel in "${_DB_CONFIG_FILES[@]}"; do
    src="$checkout_dir/$rel"
    target="$ssd_base/$rel"
    [ -f "$src" ] || continue
    if [ ! -f "$target" ] || ! cmp -s "$src" "$target"; then
      printf '%s\n' "$rel"
    fi
  done
}

# -----------------------------------------------------------------------------
# 최상위 오케스트레이션 (deploy.yml T-004 스텝에서 호출)
# -----------------------------------------------------------------------------

# reflect_deploy <diff_files(개행구분)> <checkout_dir> <infra_dir> <ssd_base> [wait_timeout=180]
#
# Phase A: compose diff 분류(구=infra_dir 현재 사본 vs 신=checkout) — 부작용 없음.
# Phase B: 전체 config 파일 동기화(compose가 blocking이 아니면 docker-compose.yml 포함).
#          compose-up 실행 전에 반드시 끝내 디스크에 신 config가 존재하도록 보장(V-5).
# Phase C: 단순 restart/SIGHUP(V-5 dedup 적용) → compose-up(항상 마지막).
# Phase D: DB runtime config diff 통지(동기화 없음, REQ-CD-015).
#
# stdout: UP:/RESTART:/SIGHUP:/DEDUP_DROPPED_RESTART:/NOTIFY: 라인(T-005가 소비 예정).
reflect_deploy() {
  local diff_files="$1" checkout_dir="$2" infra_dir="$3" ssd_base="$4" wait_timeout="${5:-180}"

  local compose_up_services=()
  local notify_lines=()
  local compose_blocked=0

  # --- Phase A: compose diff 분류 (부작용 없음) ---
  if printf '%s\n' "$diff_files" | grep -qx 'docker-compose.yml'; then
    local line
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      case "$line" in
        UP:*) compose_up_services+=("${line#UP:}") ;;
        NOTIFY:*)
          notify_lines+=("$line")
          case "$line" in
            *"수동 검토"*) compose_blocked=1 ;;
          esac
          ;;
      esac
    done < <(compose_classify "$infra_dir/docker-compose.yml" "$checkout_dir/docker-compose.yml")
  fi

  # --- Phase B: config 파일 동기화 (compose-up보다 항상 먼저, V-5) ---
  local rel
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    case "$rel" in
      docker-compose.yml)
        if [ "$compose_blocked" -eq 0 ]; then
          sync_config_file "$checkout_dir/$rel" "$infra_dir/$rel"
        fi
        ;;
      scripts/*)
        sync_config_file "$checkout_dir/$rel" "$infra_dir/$rel"
        ;;
      *)
        local target
        target=$(nas_target_path "$rel" "$infra_dir" "$ssd_base") || continue
        sync_config_file "$checkout_dir/$rel" "$target"
        ;;
    esac
  done < <(printf '%s\n' "$diff_files")

  # --- Phase C: 단순 restart/SIGHUP(V-5 dedup) → compose-up(항상 마지막) ---
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue

    local restart_info
    if restart_info=$(_config_restart_target "$rel"); then
      local container="${restart_info%%:*}" svc="${restart_info##*:}" dedup=0 s
      if [ "${#compose_up_services[@]}" -gt 0 ]; then
        for s in "${compose_up_services[@]}"; do
          [ "$s" = "$svc" ] && dedup=1
        done
      fi
      if [ "$dedup" -eq 1 ]; then
        printf 'DEDUP_DROPPED_RESTART:%s\n' "$svc"
      else
        printf 'RESTART:%s\n' "$container"
        restart_container "$container"
      fi
      continue
    fi

    local sighup_target
    if sighup_target=$(_config_sighup_target "$rel"); then
      printf 'SIGHUP:%s\n' "$sighup_target"
      sighup_container "$sighup_target"
    fi
  done < <(printf '%s\n' "$diff_files")

  if [ "${#compose_up_services[@]}" -gt 0 ]; then
    local s
    for s in "${compose_up_services[@]}"; do
      printf 'UP:%s\n' "$s"
      (cd "$infra_dir" && _docker_cmd compose up -d --wait --wait-timeout "$wait_timeout" --no-deps "$s")
    done
  fi

  if [ "${#notify_lines[@]}" -gt 0 ]; then
    local nl
    for nl in "${notify_lines[@]}"; do
      printf '%s\n' "$nl"
    done
  fi

  # --- Phase D: DB runtime config diff — 통지만, 동기화 없음(REQ-CD-015) ---
  local db_rel
  while IFS= read -r db_rel; do
    [ -z "$db_rel" ] && continue
    printf 'NOTIFY:%s — 수동 적용 필요\n' "$db_rel"
  done < <(detect_db_config_diff "$checkout_dir" "$ssd_base")

  return 0
}
