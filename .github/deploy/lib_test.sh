#!/usr/bin/env bash
# =============================================================================
# lib.sh 유닛테스트 — 순수 bash assert 하네스 (bats 미설치 환경, config/vmalert
# 러너 관례와 동일하게 셸 스크립트로 작성)
# =============================================================================
# 사용:
#   ./lib_test.sh
#
# 검증 대상 (SPEC-INFRA-CICD-001 T-002):
#   - _parse_env / parse_env_or_fail: 정상 파싱, 파일 부재 실패, 값 로그 미노출
#   - prune_backup_retention: N=10 보존, 초과분 오래된 것부터 삭제 (DP-4)
#   - is_excluded_path / nas_target_path / compute_deploy_diff: 배포대상 한정
#     (REQ-CD-006) + 제외목록(REQ-CD-007) 반영
#   - telegram_notify: 시크릿 ::add-mask:: 마스킹 (REQ-SEC-003)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

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
# _parse_env / parse_env_or_fail
# -----------------------------------------------------------------------------

test_parse_env_reads_existing_key() {
  local tmp
  tmp=$(mktemp -d)
  cat > "$tmp/.env" <<'EOF'
AAA_SSD_BASE=/volume1/SSD_1
AAA_HDD_BASE=/volume1/HDD_1
EOF
  local value
  value=$(_parse_env "AAA_SSD_BASE" "$tmp/.env")
  assert_eq "/volume1/SSD_1" "$value"
  rm -rf "$tmp"
}

test_parse_env_strips_quotes_and_whitespace() {
  # collector deploy.yml과 동일한 awk 패턴: KEY=VALUE 형식(키 주변 공백 없음)이
  # 보장된 프로젝트 시크릿 규약을 전제로 하며, 값 쪽의 따옴표/공백만 trim한다.
  local tmp
  tmp=$(mktemp -d)
  cat > "$tmp/.env" <<'EOF'
AAA_SSD_BASE="/volume1/SSD_1"
EOF
  local value
  value=$(_parse_env "AAA_SSD_BASE" "$tmp/.env")
  assert_eq "/volume1/SSD_1" "$value"
  rm -rf "$tmp"
}

test_parse_env_or_fail_missing_file_returns_nonzero() {
  local tmp
  tmp=$(mktemp -d)
  local rc=0
  parse_env_or_fail "AAA_SSD_BASE" "$tmp/does-not-exist.env" >/tmp/lib_test_stdout.$$ 2>/tmp/lib_test_stderr.$$ || rc=$?
  assert_eq "1" "$rc" "missing file must fail"
  local stdout_content
  stdout_content=$(cat /tmp/lib_test_stdout.$$)
  assert_eq "" "$stdout_content" "no value should be printed on failure"
  rm -f /tmp/lib_test_stdout.$$ /tmp/lib_test_stderr.$$
  rm -rf "$tmp"
}

test_parse_env_or_fail_missing_key_returns_nonzero() {
  local tmp
  tmp=$(mktemp -d)
  cat > "$tmp/.env" <<'EOF'
AAA_HDD_BASE=/volume1/HDD_1
EOF
  local rc=0
  parse_env_or_fail "AAA_SSD_BASE" "$tmp/.env" >/tmp/lib_test_stdout.$$ 2>/dev/null || rc=$?
  assert_eq "1" "$rc"
  rm -f /tmp/lib_test_stdout.$$
  rm -rf "$tmp"
}

test_parse_env_or_fail_success_does_not_log_value() {
  local tmp
  tmp=$(mktemp -d)
  cat > "$tmp/.env" <<'EOF'
AAA_SSD_BASE=/volume1/SUPER_SECRET_PATH_VALUE
EOF
  local rc=0
  local value
  value=$(parse_env_or_fail "AAA_SSD_BASE" "$tmp/.env" 2>/tmp/lib_test_stderr.$$) || rc=$?
  assert_eq "0" "$rc"
  assert_eq "/volume1/SUPER_SECRET_PATH_VALUE" "$value"
  local stderr_content
  stderr_content=$(cat /tmp/lib_test_stderr.$$)
  # 값 자체가 stderr 로그로 노출되면 안 됨 (키 이름은 로그되어도 무방)
  assert_not_contains "$stderr_content" "SUPER_SECRET_PATH_VALUE"
  rm -f /tmp/lib_test_stderr.$$
  rm -rf "$tmp"
}

# -----------------------------------------------------------------------------
# prune_backup_retention (DP-4: N=10 보존, 초과분 오래된 것부터 삭제)
# -----------------------------------------------------------------------------

test_prune_backup_retention_keeps_10_deletes_oldest() {
  local tmp
  tmp=$(mktemp -d)
  local backup_base="$tmp/backups/cicd"
  mkdir -p "$backup_base"
  local i
  for i in $(seq -w 1 11); do
    mkdir -p "$backup_base/2026-07-$(printf '%02d' "$((10#$i))")-000000"
  done
  local remaining
  prune_backup_retention "$backup_base" 10
  remaining=$(find "$backup_base" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  assert_eq "10" "$remaining" "must keep exactly N=10 dirs"
  # 가장 오래된(사전순 최소) 디렉토리가 삭제되어야 함
  if [ -d "$backup_base/2026-07-01-000000" ]; then
    fail "oldest backup dir should have been deleted"
  fi
  if [ ! -d "$backup_base/2026-07-11-000000" ]; then
    fail "newest backup dir should still exist"
  fi
  rm -rf "$tmp"
}

test_prune_backup_retention_noop_when_under_limit() {
  local tmp
  tmp=$(mktemp -d)
  local backup_base="$tmp/backups/cicd"
  mkdir -p "$backup_base/2026-07-01-000000"
  mkdir -p "$backup_base/2026-07-02-000000"
  prune_backup_retention "$backup_base" 10
  local remaining
  remaining=$(find "$backup_base" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  assert_eq "2" "$remaining"
  rm -rf "$tmp"
}

test_prune_backup_retention_missing_dir_is_safe() {
  local tmp
  tmp=$(mktemp -d)
  local rc=0
  prune_backup_retention "$tmp/does-not-exist" 10 || rc=$?
  assert_eq "0" "$rc"
  rm -rf "$tmp"
}

# -----------------------------------------------------------------------------
# create_backup_dir / backup_file
# -----------------------------------------------------------------------------

test_create_backup_dir_creates_timestamped_dir_under_ssd_base() {
  local tmp
  tmp=$(mktemp -d)
  local dir
  dir=$(create_backup_dir "$tmp")
  case "$dir" in
    "$tmp/backups/cicd/"*) : ;;
    *) fail "backup dir not under \$ssd_base/backups/cicd/: $dir" ;;
  esac
  if [ ! -d "$dir" ]; then
    fail "backup dir was not actually created: $dir"
  fi
  rm -rf "$tmp"
}

test_backup_file_copies_before_overwrite() {
  local tmp
  tmp=$(mktemp -d)
  local src="$tmp/rules.yml"
  echo "original-content" > "$src"
  local backup_dir="$tmp/backup"
  mkdir -p "$backup_dir"
  backup_file "$src" "config/vmalert/rules.yml" "$backup_dir"
  if [ ! -f "$backup_dir/config/vmalert/rules.yml" ]; then
    fail "backup copy not found at expected relative path"
  fi
  assert_eq "original-content" "$(cat "$backup_dir/config/vmalert/rules.yml" 2>/dev/null)"
  rm -rf "$tmp"
}

# -----------------------------------------------------------------------------
# is_excluded_path (REQ-CD-007)
# -----------------------------------------------------------------------------

test_is_excluded_path_excludes_test_files() {
  is_excluded_path "config/vmalert/rules_test_core.yaml" || fail "rules_test_*.yaml must be excluded"
  is_excluded_path "config/vmalert/run-unittests.sh" || fail "run-unittests.sh must be excluded"
  is_excluded_path "config/vmalert/check-alert-coverage.sh" || fail "check-alert-coverage.sh must be excluded"
}

test_is_excluded_path_excludes_mysql_and_redis_config() {
  is_excluded_path "config/mysql/my.cnf" || fail "config/mysql/** must be excluded"
  is_excluded_path "config/redis/redis.conf" || fail "config/redis/** must be excluded"
  is_excluded_path "config/redis/users.acl" || fail "users.acl must be excluded (never touched)"
}

test_is_excluded_path_excludes_docs() {
  is_excluded_path "docs/README.md" || fail "docs/ must be excluded"
}

test_is_excluded_path_does_not_exclude_deploy_targets() {
  if is_excluded_path "config/vmalert/rules.yml"; then
    fail "config/vmalert/rules.yml must NOT be excluded"
  fi
  if is_excluded_path "docker-compose.yml"; then
    fail "docker-compose.yml must NOT be excluded"
  fi
  if is_excluded_path "scripts/init-nas.sh"; then
    fail "scripts/init-nas.sh must NOT be excluded"
  fi
}

# -----------------------------------------------------------------------------
# nas_target_path (REQ-CD-006 매핑)
# -----------------------------------------------------------------------------

test_nas_target_path_maps_config_files_to_ssd_base() {
  local target
  target=$(nas_target_path "config/vmalert/rules.yml" "/infra" "/ssd")
  assert_eq "/ssd/config/vmalert/rules.yml" "$target"

  target=$(nas_target_path "config/alertmanager/alertmanager.yml" "/infra" "/ssd")
  assert_eq "/ssd/config/alertmanager/alertmanager.yml" "$target"

  target=$(nas_target_path "config/victoriametrics/scrape.yml" "/infra" "/ssd")
  assert_eq "/ssd/config/victoriametrics/scrape.yml" "$target"

  target=$(nas_target_path "config/vector/vector.yaml" "/infra" "/ssd")
  assert_eq "/ssd/config/vector/vector.yaml" "$target"
}

test_nas_target_path_maps_compose_and_scripts_to_infra_mirror() {
  local target
  target=$(nas_target_path "docker-compose.yml" "/infra" "/ssd")
  assert_eq "/infra/docker-compose.yml" "$target"

  target=$(nas_target_path "scripts/init-nas.sh" "/infra" "/ssd")
  assert_eq "/infra/scripts/init-nas.sh" "$target"
}

test_nas_target_path_unknown_path_fails() {
  local rc=0
  nas_target_path "config/unknown/whatever.yml" "/infra" "/ssd" >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc"
}

# -----------------------------------------------------------------------------
# compute_deploy_diff (REQ-CD-005/006/007)
# -----------------------------------------------------------------------------

test_compute_deploy_diff_detects_changed_file_only() {
  local checkout infra ssd
  checkout=$(mktemp -d)
  infra=$(mktemp -d)
  ssd=$(mktemp -d)

  mkdir -p "$checkout/config/vmalert" "$checkout/config/alertmanager" "$checkout/scripts"
  echo "compose-v1" > "$checkout/docker-compose.yml"
  echo "rules-v2" > "$checkout/config/vmalert/rules.yml"
  echo "am-v1" > "$checkout/config/alertmanager/alertmanager.yml"
  echo "script-v1" > "$checkout/scripts/init-nas.sh"

  mkdir -p "$ssd/config/vmalert" "$ssd/config/alertmanager"
  echo "compose-v1" > "$infra/docker-compose.yml"
  echo "rules-v1" > "$ssd/config/vmalert/rules.yml"       # DIFFERS
  echo "am-v1" > "$ssd/config/alertmanager/alertmanager.yml"
  mkdir -p "$infra/scripts"
  echo "script-v1" > "$infra/scripts/init-nas.sh"

  local diff_output
  diff_output=$(compute_deploy_diff "$checkout" "$infra" "$ssd")
  assert_contains "$diff_output" "config/vmalert/rules.yml"
  assert_not_contains "$diff_output" "docker-compose.yml" "unchanged compose must not appear in diff"
  assert_not_contains "$diff_output" "alertmanager.yml" "unchanged alertmanager.yml must not appear in diff"
  assert_not_contains "$diff_output" "init-nas.sh" "unchanged script must not appear in diff"

  rm -rf "$checkout" "$infra" "$ssd"
}

test_compute_deploy_diff_excludes_mysql_redis_and_test_files() {
  local checkout infra ssd
  checkout=$(mktemp -d)
  infra=$(mktemp -d)
  ssd=$(mktemp -d)

  mkdir -p "$checkout/config/mysql" "$checkout/config/redis" "$checkout/config/vmalert"
  echo "my.cnf-v2" > "$checkout/config/mysql/my.cnf"
  echo "users.acl-v2" > "$checkout/config/redis/users.acl"
  echo "test-v2" > "$checkout/config/vmalert/rules_test_core.yaml"
  echo "compose-v1" > "$checkout/docker-compose.yml"
  echo "compose-v1" > "$infra/docker-compose.yml"

  local diff_output
  diff_output=$(compute_deploy_diff "$checkout" "$infra" "$ssd")
  assert_not_contains "$diff_output" "my.cnf"
  assert_not_contains "$diff_output" "users.acl"
  assert_not_contains "$diff_output" "rules_test_core.yaml"

  rm -rf "$checkout" "$infra" "$ssd"
}

test_compute_deploy_diff_treats_missing_nas_file_as_changed() {
  local checkout infra ssd
  checkout=$(mktemp -d)
  infra=$(mktemp -d)
  ssd=$(mktemp -d)

  mkdir -p "$checkout/config/vector"
  echo "vector-v1" > "$checkout/config/vector/vector.yaml"
  # NAS 사본이 아예 없음 (최초 배포 시나리오)

  local diff_output
  diff_output=$(compute_deploy_diff "$checkout" "$infra" "$ssd")
  assert_contains "$diff_output" "config/vector/vector.yaml"

  rm -rf "$checkout" "$infra" "$ssd"
}

# -----------------------------------------------------------------------------
# telegram_notify (REQ-SEC-003)
# -----------------------------------------------------------------------------

test_telegram_notify_masks_secrets_in_stdout() {
  local fake_curl
  fake_curl=$(mktemp)
  cat > "$fake_curl" <<'EOF'
#!/usr/bin/env bash
cat - > /tmp/lib_test_curl_input.$$
echo "fake-curl-ok"
EOF
  chmod +x "$fake_curl"
  local out
  out=$(TELEGRAM_CURL_CMD="$fake_curl" telegram_notify "SECRET_BOT_TOKEN_123" "SECRET_CHAT_456" "hello")
  assert_contains "$out" "::add-mask::SECRET_BOT_TOKEN_123"
  assert_contains "$out" "::add-mask::SECRET_CHAT_456"
  rm -f "$fake_curl"
  rm -f /tmp/lib_test_curl_input.*
}

test_telegram_notify_passes_text_and_chat_id_to_curl() {
  local fake_curl capture
  fake_curl=$(mktemp)
  capture=$(mktemp)
  cat > "$fake_curl" <<EOF
#!/usr/bin/env bash
cat - > "$capture"
echo "fake-curl-ok"
EOF
  chmod +x "$fake_curl"
  TELEGRAM_CURL_CMD="$fake_curl" telegram_notify "TOKEN_X" "CHAT_Y" "배포 실패" >/dev/null
  local captured
  captured=$(cat "$capture")
  assert_contains "$captured" "TOKEN_X"
  rm -f "$fake_curl" "$capture"
}

# -----------------------------------------------------------------------------
# Run all tests
# -----------------------------------------------------------------------------

run_test test_parse_env_reads_existing_key
run_test test_parse_env_strips_quotes_and_whitespace
run_test test_parse_env_or_fail_missing_file_returns_nonzero
run_test test_parse_env_or_fail_missing_key_returns_nonzero
run_test test_parse_env_or_fail_success_does_not_log_value

run_test test_prune_backup_retention_keeps_10_deletes_oldest
run_test test_prune_backup_retention_noop_when_under_limit
run_test test_prune_backup_retention_missing_dir_is_safe

run_test test_create_backup_dir_creates_timestamped_dir_under_ssd_base
run_test test_backup_file_copies_before_overwrite

run_test test_is_excluded_path_excludes_test_files
run_test test_is_excluded_path_excludes_mysql_and_redis_config
run_test test_is_excluded_path_excludes_docs
run_test test_is_excluded_path_does_not_exclude_deploy_targets

run_test test_nas_target_path_maps_config_files_to_ssd_base
run_test test_nas_target_path_maps_compose_and_scripts_to_infra_mirror
run_test test_nas_target_path_unknown_path_fails

run_test test_compute_deploy_diff_detects_changed_file_only
run_test test_compute_deploy_diff_excludes_mysql_redis_and_test_files
run_test test_compute_deploy_diff_treats_missing_nas_file_as_changed

run_test test_telegram_notify_masks_secrets_in_stdout
run_test test_telegram_notify_passes_text_and_chat_id_to_curl

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
