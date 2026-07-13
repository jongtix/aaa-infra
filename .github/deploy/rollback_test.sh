#!/usr/bin/env bash
# =============================================================================
# rollback.sh 유닛테스트 — 순수 bash assert 하네스 (lib_test.sh/reflect_test.sh/
# verify_test.sh와 동일 컨벤션)
# =============================================================================
# 사용:
#   ./rollback_test.sh
#
# 검증 대상 (SPEC-INFRA-CICD-001 T-005):
#   - restore_backup_files: 백업 디렉토리 파일을 원위치로 복원(nas_target_path 역매핑)
#   - rollback_deploy: 복원+재시작 전부 성공 시 "자동 복원됨" 통지 / 복원 실패 시
#     "수동 개입 필요" 통지(REQ-CD-019)
#   - notify_pending_items: reflect_deploy의 NOTIFY: 라인을 전부 telegram_notify로
#     전달(REQ-CD-020)
#
# _docker_cmd(reflect.sh)를 재정의해 실제 docker 데몬을 전혀 호출하지 않는다.
# telegram_notify는 TELEGRAM_CURL_CMD를 페이크 curl로 오버라이드해 검증한다.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=./reflect.sh
source "$SCRIPT_DIR/reflect.sh"
# shellcheck source=./rollback.sh
source "$SCRIPT_DIR/rollback.sh"

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

_make_fake_curl() {
  # $1=fake_curl_path $2=capture_path — stdin(-K config)과 인자($@) 둘 다 capture에 기록.
  local fake_curl="$1" capture="$2"
  cat > "$fake_curl" <<CURLEOF
#!/usr/bin/env bash
cat - >> "$capture"
printf '%s\n' "\$@" >> "$capture"
echo "fake-curl-ok"
CURLEOF
  chmod +x "$fake_curl"
}

# -----------------------------------------------------------------------------
# restore_backup_files
# -----------------------------------------------------------------------------

test_restore_backup_files_restores_config_file_to_ssd_base() {
  local infra ssd backup_dir
  infra=$(mktemp -d) ssd=$(mktemp -d) backup_dir=$(mktemp -d)

  mkdir -p "$backup_dir/config/vmalert" "$ssd/config/vmalert"
  echo "rules-v1-good" > "$backup_dir/config/vmalert/rules.yml"
  echo "rules-v2-bad" > "$ssd/config/vmalert/rules.yml"

  local rc=0
  restore_backup_files "$backup_dir" "$infra" "$ssd" || rc=$?
  assert_eq "0" "$rc"

  local restored
  restored=$(cat "$ssd/config/vmalert/rules.yml")
  assert_eq "rules-v1-good" "$restored" "백업 내용으로 복원되어야 함"

  rm -rf "$infra" "$ssd" "$backup_dir"
}

test_restore_backup_files_missing_backup_dir_fails() {
  local infra ssd
  infra=$(mktemp -d) ssd=$(mktemp -d)

  local rc=0
  restore_backup_files "$infra/does-not-exist" "$infra" "$ssd" || rc=$?
  assert_eq "1" "$rc" "백업 디렉토리 부재는 복원 실패로 처리되어야 함"

  rm -rf "$infra" "$ssd"
}

test_restore_backup_files_empty_backup_dir_is_noop_success() {
  # 빈 diff 배포 직후(백업 대상 자체가 없는 경우) 복원할 것이 없다는 의미이지 실패가 아니다.
  local infra ssd backup_dir
  infra=$(mktemp -d) ssd=$(mktemp -d) backup_dir=$(mktemp -d)

  local rc=0
  restore_backup_files "$backup_dir" "$infra" "$ssd" || rc=$?
  assert_eq "0" "$rc"

  rm -rf "$infra" "$ssd" "$backup_dir"
}

# -----------------------------------------------------------------------------
# rollback_deploy (REQ-CD-019)
# -----------------------------------------------------------------------------

test_rollback_deploy_restores_backup_restarts_and_notifies_auto_recovered() {
  local infra ssd backup_dir log fake_curl capture
  infra=$(mktemp -d) ssd=$(mktemp -d) backup_dir=$(mktemp -d)
  log=$(mktemp)
  fake_curl=$(mktemp) capture=$(mktemp)

  mkdir -p "$backup_dir/config/vmalert" "$ssd/config/vmalert"
  echo "rules-v1-good" > "$backup_dir/config/vmalert/rules.yml"
  echo "rules-v2-bad" > "$ssd/config/vmalert/rules.yml"

  _make_fake_curl "$fake_curl" "$capture"

  local rc=0
  REFLECT_CALL_LOG="$log" TELEGRAM_CURL_CMD="$fake_curl" \
    rollback_deploy "$backup_dir" "$infra" "$ssd" "TOKEN" "CHAT" "aaa-vmalert" || rc=$?
  assert_eq "0" "$rc" "복원+재시작 전부 성공이면 rollback_deploy는 0을 반환해야 함"

  local restored
  restored=$(cat "$ssd/config/vmalert/rules.yml")
  assert_eq "rules-v1-good" "$restored" "backup_file 호출로 원본 내용이 복원되어야 함"

  local log_content
  log_content=$(cat "$log")
  assert_contains "$log_content" "DOCKER:restart aaa-vmalert" "영향받은 서비스가 원상 재시작되어야 함(REQ-CD-019)"

  local captured
  captured=$(cat "$capture")
  assert_contains "$captured" "자동 복원됨" "복원+재시작 성공 시 '자동 복원됨' 통지가 발생해야 함"

  rm -rf "$infra" "$ssd" "$backup_dir"
  rm -f "$log" "$fake_curl" "$capture"
}

test_rollback_deploy_restore_failure_notifies_manual_intervention() {
  local infra ssd backup_dir fake_curl capture
  infra=$(mktemp -d) ssd=$(mktemp -d)
  backup_dir="$(mktemp -d)/does-not-exist"   # backup_dir 자체가 없음 → 복원 실패
  fake_curl=$(mktemp) capture=$(mktemp)

  _make_fake_curl "$fake_curl" "$capture"

  local rc=0
  TELEGRAM_CURL_CMD="$fake_curl" \
    rollback_deploy "$backup_dir" "$infra" "$ssd" "TOKEN" "CHAT" || rc=$?
  assert_eq "1" "$rc" "복원 자체가 실패하면 rollback_deploy는 1을 반환해야 함"

  local captured
  captured=$(cat "$capture")
  assert_contains "$captured" "수동 개입 필요" "백업 복원 실패 시 '수동 개입 필요' 통지가 발생해야 함"
  assert_not_contains "$captured" "자동 복원됨"

  rm -rf "$infra" "$ssd"
  rm -f "$fake_curl" "$capture"
}

test_rollback_deploy_restart_failure_notifies_manual_intervention() {
  # 복원은 성공하지만 서비스 재시작이 실패하는 경우도 "수동 개입 필요"로 처리되어야 함.
  local infra ssd backup_dir fake_curl capture
  infra=$(mktemp -d) ssd=$(mktemp -d) backup_dir=$(mktemp -d)
  fake_curl=$(mktemp) capture=$(mktemp)

  mkdir -p "$backup_dir/config/vmalert" "$ssd/config/vmalert"
  echo "rules-v1-good" > "$backup_dir/config/vmalert/rules.yml"
  echo "rules-v2-bad" > "$ssd/config/vmalert/rules.yml"

  _make_fake_curl "$fake_curl" "$capture"

  # restart_container(→ _docker_cmd)를 이 테스트에서만 실패하도록 오버라이드.
  _docker_cmd() { return 1; }

  local rc=0
  TELEGRAM_CURL_CMD="$fake_curl" \
    rollback_deploy "$backup_dir" "$infra" "$ssd" "TOKEN" "CHAT" "aaa-vmalert" || rc=$?
  assert_eq "1" "$rc"

  local captured
  captured=$(cat "$capture")
  assert_contains "$captured" "수동 개입 필요"

  # 원상 복구: 이후 테스트에 영향 없도록 원래 오버라이드로 되돌림.
  _docker_cmd() { _call_log_append "DOCKER:$*"; }

  rm -rf "$infra" "$ssd" "$backup_dir"
  rm -f "$fake_curl" "$capture"
}

# -----------------------------------------------------------------------------
# notify_pending_items (REQ-CD-020)
# -----------------------------------------------------------------------------

test_notify_pending_items_forwards_notify_lines_to_telegram() {
  local fake_curl capture
  fake_curl=$(mktemp) capture=$(mktemp)
  _make_fake_curl "$fake_curl" "$capture"

  local result
  result=$(printf 'UP:vmalert\nNOTIFY:config/mysql/my.cnf — 수동 적용 필요\n')

  TELEGRAM_CURL_CMD="$fake_curl" notify_pending_items "$result" "TOKEN" "CHAT"

  local captured
  captured=$(cat "$capture")
  assert_contains "$captured" "my.cnf"
  assert_contains "$captured" "수동 적용 필요"

  rm -f "$fake_curl" "$capture"
}

test_notify_pending_items_no_notify_lines_is_noop() {
  local fake_curl capture
  fake_curl=$(mktemp) capture=$(mktemp)
  _make_fake_curl "$fake_curl" "$capture"

  TELEGRAM_CURL_CMD="$fake_curl" notify_pending_items "UP:vmalert" "TOKEN" "CHAT"

  local captured
  captured=$(cat "$capture")
  assert_eq "" "$captured" "NOTIFY: 라인이 없으면 telegram_notify가 호출되면 안 됨"

  rm -f "$fake_curl" "$capture"
}

# -----------------------------------------------------------------------------
# Run all tests
# -----------------------------------------------------------------------------

run_test test_restore_backup_files_restores_config_file_to_ssd_base
run_test test_restore_backup_files_missing_backup_dir_fails
run_test test_restore_backup_files_empty_backup_dir_is_noop_success

run_test test_rollback_deploy_restores_backup_restarts_and_notifies_auto_recovered
run_test test_rollback_deploy_restore_failure_notifies_manual_intervention
run_test test_rollback_deploy_restart_failure_notifies_manual_intervention

run_test test_notify_pending_items_forwards_notify_lines_to_telegram
run_test test_notify_pending_items_no_notify_lines_is_noop

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
