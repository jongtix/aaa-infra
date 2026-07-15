#!/usr/bin/env bash
# =============================================================================
# reflect.sh 유닛테스트 — 순수 bash assert 하네스 (lib_test.sh와 동일 컨벤션)
# =============================================================================
# 사용:
#   ./reflect_test.sh
#
# 검증 대상 (SPEC-INFRA-CICD-001 T-004, 최고위험 마일스톤):
#   - compose_classify: 관측 서비스 자기 블록만 변경 → UP만 / 공유 top-level·
#     collector·analyzer·notifier 변경 → 전체 NOTIFY-only(blocking) / mysql·redis 블록
#     변경 → 절대 UP 없이 NOTIFY-only
#   - reflect_deploy: 단순 config→restart/SIGHUP, V-5 dedup(동일 서비스 restart+
#     compose-up 동시 대상이면 restart 드롭), config 동기화가 compose-up보다 항상
#     먼저 실행됨(순서), DB runtime config는 절대 동기화되지 않고 통지만 발생
#   - [HARD] 어떤 시나리오에서도 mysql/redis/users.acl/collector/analyzer/notifier가
#     DOCKER: 호출 로그에 등장하지 않음(가장 중요한 테스트 그룹)
#
# _docker_cmd를 재정의해 실제 docker 대신 REFLECT_CALL_LOG에만 기록한다 —
# 이 테스트 스위트는 실제 docker 데몬을 전혀 호출하지 않는다.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=./reflect.sh
source "$SCRIPT_DIR/reflect.sh"

# --- 테스트 전용 오버라이드: 실제 docker 호출 완전 차단 ---
_docker_cmd() {
  _call_log_append "DOCKER:$*"
}

PASS=0
FAIL=0
CURRENT_TEST=""

fail() {
  echo "  [FAIL] $CURRENT_TEST: $1"
  FAIL=$((FAIL + 1))
}

pass() {
  echo "  [PASS] $CURRENT_TEST"
  PASS=$((PASS + 1))
}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  if [ "$expected" = "$actual" ]; then
    return 0
  fi
  fail "expected [$expected] got [$actual] $msg"
  return 1
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  case "$haystack" in
    *"$needle"*) return 0 ;;
  esac
  fail "expected haystack to contain [$needle] $msg :: haystack=[$haystack]"
  return 1
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  case "$haystack" in
    *"$needle"*)
      fail "expected haystack NOT to contain [$needle] $msg"
      return 1
      ;;
  esac
  return 0
}

run_test() {
  CURRENT_TEST="$1"
  local before_fail=$FAIL
  "$1"
  if [ "$FAIL" -eq "$before_fail" ]; then
    pass
  fi
}

# -----------------------------------------------------------------------------
# 공통 픽스처: 최소 docker-compose.yml (x-logging/networks + 10개 서비스 블록)
# -----------------------------------------------------------------------------

_write_base_compose() {
  # $1=path $2=vmalert_image_tag(변형 포인트) $3=collector_image_tag $4=mysql_image_tag
  # $5=x_logging_max_size(변형 포인트) $6=notifier_image_tag(변형 포인트)
  local path="$1" vmalert_tag="${2:-v1}" collector_tag="${3:-latest}" mysql_tag="${4:-8.4}" max_size="${5:-10m}" notifier_tag="${6:-latest}"
  cat > "$path" <<EOF
x-logging: &default-logging
  driver: json-file
  options:
    max-size: "${max_size}"
    max-file: "5"

networks:
  aaa-network:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/24

services:

  mysql:
    image: mysql:${mysql_tag}
    restart: unless-stopped

  redis:
    image: redis:8.8
    restart: unless-stopped

  collector:
    image: ghcr.io/jongtix/aaa-collector:${collector_tag}
    restart: unless-stopped

  analyzer:
    image: ghcr.io/jongtix/aaa-analyzer:latest
    restart: unless-stopped

  notifier:
    image: ghcr.io/jongtix/aaa-notifier:${notifier_tag}
    restart: unless-stopped

  victoriametrics:
    image: victoriametrics/victoria-metrics:v1.146.0
    restart: unless-stopped

  vmalert:
    image: victoriametrics/vmalert:${vmalert_tag}
    restart: unless-stopped

  alertmanager:
    image: prom/alertmanager:v0.33.1
    restart: unless-stopped

  victorialogs:
    image: victoriametrics/victoria-logs:v1.51.0
    restart: unless-stopped

  vector:
    image: timberio/vector:0.56.0-debian
    restart: unless-stopped

  node-exporter:
    image: prom/node-exporter:v1.11.1
    restart: unless-stopped
EOF
}

# -----------------------------------------------------------------------------
# compose_classify — 순수 분류 함수
# -----------------------------------------------------------------------------

test_compose_classify_vmalert_block_only_emits_up_vmalert_only() {
  local old new
  old=$(mktemp) new=$(mktemp)
  _write_base_compose "$old" "v1.146.0"
  _write_base_compose "$new" "v1.147.0"   # vmalert 블록만 변경

  local out
  out=$(compose_classify "$old" "$new")
  assert_contains "$out" "UP:vmalert"
  assert_not_contains "$out" "UP:alertmanager"
  assert_not_contains "$out" "UP:victoriametrics"
  assert_not_contains "$out" "NOTIFY:"
  rm -f "$old" "$new"
}

test_compose_classify_shared_anchor_change_blocks_everything() {
  local old new
  old=$(mktemp) new=$(mktemp)
  _write_base_compose "$old" "v1" "latest" "8.4" "10m"
  _write_base_compose "$new" "v1" "latest" "8.4" "50m"   # x-logging max-size만 변경

  local out
  out=$(compose_classify "$old" "$new")
  assert_contains "$out" "NOTIFY:"
  assert_contains "$out" "수동 검토"
  assert_not_contains "$out" "UP:" "shared top-level 변경 시 어떤 UP:도 나오면 안 됨"
  rm -f "$old" "$new"
}

test_compose_classify_collector_block_change_blocks_and_never_emits_collector() {
  local old new
  old=$(mktemp) new=$(mktemp)
  _write_base_compose "$old" "v1" "1.40.0"
  _write_base_compose "$new" "v1" "1.41.0"   # collector 블록만 변경

  local out
  out=$(compose_classify "$old" "$new")
  assert_contains "$out" "NOTIFY:"
  assert_not_contains "$out" "UP:collector" "collector가 UP: 대상으로 등장하면 안 됨"
  assert_not_contains "$out" "UP:"
  rm -f "$old" "$new"
}

test_compose_classify_notifier_block_change_blocks_and_never_emits_notifier() {
  local old new
  old=$(mktemp) new=$(mktemp)
  _write_base_compose "$old" "v1" "latest" "8.4" "10m" "1.0.0"
  _write_base_compose "$new" "v1" "latest" "8.4" "10m" "1.1.0"   # notifier 블록만 변경

  local out
  out=$(compose_classify "$old" "$new")
  assert_contains "$out" "NOTIFY:"
  assert_not_contains "$out" "UP:notifier" "notifier가 UP: 대상으로 등장하면 안 됨"
  assert_not_contains "$out" "UP:"
  rm -f "$old" "$new"
}

test_compose_classify_mysql_block_change_never_emits_up_mysql() {
  local old new
  old=$(mktemp) new=$(mktemp)
  _write_base_compose "$old" "v1" "latest" "8.4"
  _write_base_compose "$new" "v1" "latest" "8.5"   # mysql 블록만 변경 (가장 중요)

  local out
  out=$(compose_classify "$old" "$new")
  assert_not_contains "$out" "UP:mysql" "[HARD] mysql은 어떤 경우에도 UP: 대상이 되면 안 됨"
  assert_not_contains "$out" "mysql:up" # 방어적 체크
  assert_contains "$out" "NOTIFY:" "mysql 블록 변경은 통지되어야 함"
  # 다른 서비스(vmalert 등)는 안 건드렸으므로 UP: 자체가 전혀 없어야 함(mysql만 변경)
  assert_not_contains "$out" "UP:"
  rm -f "$old" "$new"
}

test_compose_classify_vmalert_and_mysql_both_changed_ups_vmalert_excludes_mysql() {
  # AC-CD-009A: 관측 서비스(vmalert)와 mysql이 동일 커밋에서 동시에 변경되면
  # vmalert는 정상 반영되고 mysql만 제외된다(전체 배포 중단이 아님).
  local old new
  old=$(mktemp) new=$(mktemp)
  _write_base_compose "$old" "v1.146.0" "latest" "8.4"
  _write_base_compose "$new" "v1.147.0" "latest" "8.5"   # vmalert + mysql 동시 변경

  local out
  out=$(compose_classify "$old" "$new")
  assert_contains "$out" "UP:vmalert"
  assert_not_contains "$out" "UP:mysql"
  assert_contains "$out" "NOTIFY:"
  rm -f "$old" "$new"
}

test_compose_classify_unchanged_file_emits_nothing() {
  local old new
  old=$(mktemp) new=$(mktemp)
  _write_base_compose "$old"
  _write_base_compose "$new"

  local out
  out=$(compose_classify "$old" "$new")
  assert_eq "" "$out"
  rm -f "$old" "$new"
}

# -----------------------------------------------------------------------------
# reflect_deploy — 시나리오별 통합 (call log로 부작용 캡처)
# -----------------------------------------------------------------------------

test_reflect_deploy_rules_yml_only_restarts_vmalert_only() {
  local checkout infra ssd log
  checkout=$(mktemp -d) infra=$(mktemp -d) ssd=$(mktemp -d)
  log=$(mktemp)

  mkdir -p "$checkout/config/vmalert" "$ssd/config/vmalert"
  echo "rules-v2" > "$checkout/config/vmalert/rules.yml"
  echo "rules-v1" > "$ssd/config/vmalert/rules.yml"
  _write_base_compose "$checkout/docker-compose.yml"
  _write_base_compose "$infra/docker-compose.yml"   # compose 미변경

  REFLECT_CALL_LOG="$log" reflect_deploy "config/vmalert/rules.yml" "$checkout" "$infra" "$ssd" > /tmp/reflect_out.$$
  local out
  out=$(cat /tmp/reflect_out.$$)
  assert_contains "$out" "RESTART:aaa-vmalert"

  local log_content
  log_content=$(cat "$log")
  assert_contains "$log_content" "DOCKER:restart aaa-vmalert"
  assert_not_contains "$log_content" "DOCKER:compose up" "다른 서비스의 compose-up이 호출되면 안 됨"
  assert_not_contains "$log_content" "alertmanager"
  assert_not_contains "$log_content" "vector"

  rm -f /tmp/reflect_out.$$ "$log"
  rm -rf "$checkout" "$infra" "$ssd"
}

test_reflect_deploy_compose_vmalert_block_only_ups_vmalert_only() {
  local checkout infra ssd log
  checkout=$(mktemp -d) infra=$(mktemp -d) ssd=$(mktemp -d)
  log=$(mktemp)

  _write_base_compose "$infra/docker-compose.yml" "v1.146.0"
  _write_base_compose "$checkout/docker-compose.yml" "v1.147.0"   # vmalert 블록만 변경

  REFLECT_CALL_LOG="$log" reflect_deploy "docker-compose.yml" "$checkout" "$infra" "$ssd" > /tmp/reflect_out.$$
  local out
  out=$(cat /tmp/reflect_out.$$)
  assert_contains "$out" "UP:vmalert"

  local log_content
  log_content=$(cat "$log")
  assert_contains "$log_content" "DOCKER:compose up -d --wait --wait-timeout 180 --no-deps vmalert"
  assert_not_contains "$log_content" "DOCKER:restart" "compose-up 경로에서 별도 restart가 중복 호출되면 안 됨"
  assert_not_contains "$log_content" "alertmanager"
  assert_not_contains "$log_content" "collector"
  assert_not_contains "$log_content" "mysql"

  rm -f /tmp/reflect_out.$$ "$log"
  rm -rf "$checkout" "$infra" "$ssd"
}

test_reflect_deploy_shared_anchor_change_skips_all_compose_up_and_notifies() {
  local checkout infra ssd log
  checkout=$(mktemp -d) infra=$(mktemp -d) ssd=$(mktemp -d)
  log=$(mktemp)

  _write_base_compose "$infra/docker-compose.yml" "v1" "latest" "8.4" "10m"
  _write_base_compose "$checkout/docker-compose.yml" "v1" "latest" "8.4" "50m"   # x-logging만 변경

  REFLECT_CALL_LOG="$log" reflect_deploy "docker-compose.yml" "$checkout" "$infra" "$ssd" > /tmp/reflect_out.$$
  local out
  out=$(cat /tmp/reflect_out.$$)
  assert_contains "$out" "NOTIFY:"
  assert_not_contains "$out" "UP:"

  local log_content
  log_content=$(cat "$log")
  assert_not_contains "$log_content" "DOCKER:compose up" "shared top-level 변경 시 어떤 compose up도 호출되면 안 됨"
  assert_not_contains "$log_content" "SYNC:" "blocking 시 docker-compose.yml 자체도 동기화되면 안 됨"

  rm -f /tmp/reflect_out.$$ "$log"
  rm -rf "$checkout" "$infra" "$ssd"
}

test_reflect_deploy_collector_block_change_never_names_collector_in_compose_up_args() {
  local checkout infra ssd log
  checkout=$(mktemp -d) infra=$(mktemp -d) ssd=$(mktemp -d)
  log=$(mktemp)

  _write_base_compose "$infra/docker-compose.yml" "v1" "1.40.0"
  _write_base_compose "$checkout/docker-compose.yml" "v1" "1.41.0"   # collector 블록만 변경

  REFLECT_CALL_LOG="$log" reflect_deploy "docker-compose.yml" "$checkout" "$infra" "$ssd" > /tmp/reflect_out.$$
  local out
  out=$(cat /tmp/reflect_out.$$)
  assert_contains "$out" "NOTIFY:"

  local log_content
  log_content=$(cat "$log")
  assert_not_contains "$log_content" "collector" "[HARD] collector가 compose-up 호출 인자에 절대 등장하면 안 됨"
  assert_not_contains "$log_content" "DOCKER:compose up"

  rm -f /tmp/reflect_out.$$ "$log"
  rm -rf "$checkout" "$infra" "$ssd"
}

test_reflect_deploy_notifier_block_change_never_names_notifier_in_compose_up_args() {
  local checkout infra ssd log
  checkout=$(mktemp -d) infra=$(mktemp -d) ssd=$(mktemp -d)
  log=$(mktemp)

  _write_base_compose "$infra/docker-compose.yml" "v1" "latest" "8.4" "10m" "1.0.0"
  _write_base_compose "$checkout/docker-compose.yml" "v1" "latest" "8.4" "10m" "1.1.0"   # notifier 블록만 변경

  REFLECT_CALL_LOG="$log" reflect_deploy "docker-compose.yml" "$checkout" "$infra" "$ssd" > /tmp/reflect_out.$$
  local out
  out=$(cat /tmp/reflect_out.$$)
  assert_contains "$out" "NOTIFY:"

  local log_content
  log_content=$(cat "$log")
  assert_not_contains "$log_content" "notifier" "[HARD] notifier가 compose-up 호출 인자에 절대 등장하면 안 됨"
  assert_not_contains "$log_content" "DOCKER:compose up"

  rm -f /tmp/reflect_out.$$ "$log"
  rm -rf "$checkout" "$infra" "$ssd"
}

test_reflect_deploy_mysql_block_change_never_names_mysql_in_any_docker_call() {
  local checkout infra ssd log
  checkout=$(mktemp -d) infra=$(mktemp -d) ssd=$(mktemp -d)
  log=$(mktemp)

  _write_base_compose "$infra/docker-compose.yml" "v1" "latest" "8.4"
  _write_base_compose "$checkout/docker-compose.yml" "v1" "latest" "8.5"   # mysql 블록만 변경

  REFLECT_CALL_LOG="$log" reflect_deploy "docker-compose.yml" "$checkout" "$infra" "$ssd" > /tmp/reflect_out.$$
  local out
  out=$(cat /tmp/reflect_out.$$)
  assert_contains "$out" "NOTIFY:"

  local log_content
  log_content=$(cat "$log")
  # [HARD] 가장 중요한 단일 검증: 이 로그에 "mysql"이 담긴 DOCKER: 라인이 절대 없어야 함
  assert_not_contains "$log_content" "DOCKER:restart aaa-mysql"
  assert_not_contains "$log_content" "DOCKER:compose up -d --wait --wait-timeout 180 --no-deps mysql"
  assert_not_contains "$log_content" "kill -s HUP aaa-mysql"
  # 아예 어떤 DOCKER: 호출도 없어야 함(다른 파일 변경 없음, mysql은 up 대상 아님)
  assert_not_contains "$log_content" "DOCKER:"

  rm -f /tmp/reflect_out.$$ "$log"
  rm -rf "$checkout" "$infra" "$ssd"
}

test_reflect_deploy_mysql_config_change_does_not_sync_file_and_notifies() {
  local checkout infra ssd log
  checkout=$(mktemp -d) infra=$(mktemp -d) ssd=$(mktemp -d)
  log=$(mktemp)

  mkdir -p "$checkout/config/mysql" "$ssd/config/mysql"
  echo "my-cnf-v2" > "$checkout/config/mysql/my.cnf"
  echo "my-cnf-v1" > "$ssd/config/mysql/my.cnf"
  _write_base_compose "$checkout/docker-compose.yml"
  _write_base_compose "$infra/docker-compose.yml"

  # my.cnf는 lib.sh compute_deploy_diff의 제외목록이라 diff_files에 절대 포함되지
  # 않는다(REQ-CD-007) — reflect_deploy가 이를 별도(Phase D)로 감지하는지 검증.
  REFLECT_CALL_LOG="$log" reflect_deploy "" "$checkout" "$infra" "$ssd" > /tmp/reflect_out.$$
  local out
  out=$(cat /tmp/reflect_out.$$)
  assert_contains "$out" "config/mysql/my.cnf"
  assert_contains "$out" "NOTIFY:"

  # 실제 파일이 절대 덮어써지지 않아야 함(NAS 파일 == 실행 중 설정 불변식)
  local ssd_content
  ssd_content=$(cat "$ssd/config/mysql/my.cnf")
  assert_eq "my-cnf-v1" "$ssd_content" "REQ-CD-015: my.cnf는 절대 동기화되면 안 됨"

  local log_content
  log_content=$(cat "$log")
  assert_not_contains "$log_content" "SYNC:" "my.cnf가 동기화 로그에 나타나면 안 됨"

  rm -f /tmp/reflect_out.$$ "$log"
  rm -rf "$checkout" "$infra" "$ssd"
}

test_reflect_deploy_never_touches_users_acl() {
  # users.acl 경로 문자열이 reflect.sh 소스 어디에도 등장하지 않아야 한다(REQ-CD-016).
  # 런타임 동작으로도 재확인: users.acl이 존재해도 detect_db_config_diff가 절대 언급하지 않음.
  local checkout ssd
  checkout=$(mktemp -d) ssd=$(mktemp -d)
  mkdir -p "$checkout/config/redis" "$ssd/config/redis"
  echo "acl-v2" > "$checkout/config/redis/users.acl"
  echo "acl-v1" > "$ssd/config/redis/users.acl"

  local out
  out=$(detect_db_config_diff "$checkout" "$ssd")
  assert_not_contains "$out" "users.acl"

  rm -rf "$checkout" "$ssd"
}

test_reflect_deploy_dedup_drops_restart_when_same_service_is_compose_up_target() {
  local checkout infra ssd log
  checkout=$(mktemp -d) infra=$(mktemp -d) ssd=$(mktemp -d)
  log=$(mktemp)

  # 동일 커밋에서 rules.yml과 compose의 vmalert 블록이 동시에 변경(V-5 시나리오).
  mkdir -p "$checkout/config/vmalert" "$ssd/config/vmalert"
  echo "rules-v2" > "$checkout/config/vmalert/rules.yml"
  echo "rules-v1" > "$ssd/config/vmalert/rules.yml"
  _write_base_compose "$infra/docker-compose.yml" "v1.146.0"
  _write_base_compose "$checkout/docker-compose.yml" "v1.147.0"

  local diff_files
  diff_files=$(printf 'config/vmalert/rules.yml\ndocker-compose.yml\n')

  REFLECT_CALL_LOG="$log" reflect_deploy "$diff_files" "$checkout" "$infra" "$ssd" > /tmp/reflect_out.$$
  local out
  out=$(cat /tmp/reflect_out.$$)
  assert_contains "$out" "DEDUP_DROPPED_RESTART:vmalert"
  assert_contains "$out" "UP:vmalert"
  assert_not_contains "$out" "RESTART:aaa-vmalert" "dedup되면 RESTART: 라인 자체가 나오면 안 됨"

  local log_content
  log_content=$(cat "$log")
  assert_not_contains "$log_content" "DOCKER:restart aaa-vmalert" "V-5: restart는 드롭되고 compose-up만 실행되어야 함"
  assert_contains "$log_content" "DOCKER:compose up -d --wait --wait-timeout 180 --no-deps vmalert"

  rm -f /tmp/reflect_out.$$ "$log"
  rm -rf "$checkout" "$infra" "$ssd"
}

test_reflect_deploy_config_sync_always_precedes_compose_up() {
  local checkout infra ssd log
  checkout=$(mktemp -d) infra=$(mktemp -d) ssd=$(mktemp -d)
  log=$(mktemp)

  mkdir -p "$checkout/config/vmalert" "$ssd/config/vmalert"
  echo "rules-v2" > "$checkout/config/vmalert/rules.yml"
  echo "rules-v1" > "$ssd/config/vmalert/rules.yml"
  _write_base_compose "$infra/docker-compose.yml" "v1.146.0"
  _write_base_compose "$checkout/docker-compose.yml" "v1.147.0"

  local diff_files
  diff_files=$(printf 'config/vmalert/rules.yml\ndocker-compose.yml\n')

  REFLECT_CALL_LOG="$log" reflect_deploy "$diff_files" "$checkout" "$infra" "$ssd" > /dev/null

  # 로그에서 첫 SYNC: 라인의 순번이 첫 DOCKER:compose up 라인의 순번보다 앞서야 한다.
  local sync_line_no up_line_no
  sync_line_no=$(grep -n '^SYNC:' "$log" | head -1 | cut -d: -f1)
  up_line_no=$(grep -n '^DOCKER:compose up' "$log" | head -1 | cut -d: -f1)

  if [ -z "$sync_line_no" ] || [ -z "$up_line_no" ]; then
    fail "expected both a SYNC: line and a DOCKER:compose up line in the call log"
  elif [ "$sync_line_no" -ge "$up_line_no" ]; then
    fail "SYNC (line $sync_line_no) must precede compose-up (line $up_line_no)"
  fi

  # 신규 rules.yml 내용이 실제로 vmalert 재시작(=compose-up) 전에 디스크에 반영됐는지도 확인.
  local synced_content
  synced_content=$(cat "$ssd/config/vmalert/rules.yml")
  assert_eq "rules-v2" "$synced_content"

  rm -f "$log"
  rm -rf "$checkout" "$infra" "$ssd"
}

test_reflect_deploy_scrape_yml_sends_sighup_not_restart() {
  local checkout infra ssd log
  checkout=$(mktemp -d) infra=$(mktemp -d) ssd=$(mktemp -d)
  log=$(mktemp)

  mkdir -p "$checkout/config/victoriametrics" "$ssd/config/victoriametrics"
  echo "scrape-v2" > "$checkout/config/victoriametrics/scrape.yml"
  echo "scrape-v1" > "$ssd/config/victoriametrics/scrape.yml"
  _write_base_compose "$checkout/docker-compose.yml"
  _write_base_compose "$infra/docker-compose.yml"

  REFLECT_CALL_LOG="$log" reflect_deploy "config/victoriametrics/scrape.yml" "$checkout" "$infra" "$ssd" > /tmp/reflect_out.$$
  local out
  out=$(cat /tmp/reflect_out.$$)
  assert_contains "$out" "SIGHUP:aaa-victoriametrics"

  local log_content
  log_content=$(cat "$log")
  assert_contains "$log_content" "DOCKER:kill -s HUP aaa-victoriametrics"
  assert_not_contains "$log_content" "DOCKER:restart aaa-victoriametrics" "SIGHUP 경로는 재시작이 아니어야 함(REQ-CD-012)"

  rm -f /tmp/reflect_out.$$ "$log"
  rm -rf "$checkout" "$infra" "$ssd"
}

# -----------------------------------------------------------------------------
# Run all tests
# -----------------------------------------------------------------------------

run_test test_compose_classify_vmalert_block_only_emits_up_vmalert_only
run_test test_compose_classify_shared_anchor_change_blocks_everything
run_test test_compose_classify_collector_block_change_blocks_and_never_emits_collector
run_test test_compose_classify_notifier_block_change_blocks_and_never_emits_notifier
run_test test_compose_classify_mysql_block_change_never_emits_up_mysql
run_test test_compose_classify_vmalert_and_mysql_both_changed_ups_vmalert_excludes_mysql
run_test test_compose_classify_unchanged_file_emits_nothing

run_test test_reflect_deploy_rules_yml_only_restarts_vmalert_only
run_test test_reflect_deploy_compose_vmalert_block_only_ups_vmalert_only
run_test test_reflect_deploy_shared_anchor_change_skips_all_compose_up_and_notifies
run_test test_reflect_deploy_collector_block_change_never_names_collector_in_compose_up_args
run_test test_reflect_deploy_notifier_block_change_never_names_notifier_in_compose_up_args
run_test test_reflect_deploy_mysql_block_change_never_names_mysql_in_any_docker_call
run_test test_reflect_deploy_mysql_config_change_does_not_sync_file_and_notifies
run_test test_reflect_deploy_never_touches_users_acl
run_test test_reflect_deploy_dedup_drops_restart_when_same_service_is_compose_up_target
run_test test_reflect_deploy_config_sync_always_precedes_compose_up
run_test test_reflect_deploy_scrape_yml_sends_sighup_not_restart

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
