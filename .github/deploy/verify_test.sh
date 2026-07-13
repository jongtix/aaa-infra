#!/usr/bin/env bash
# =============================================================================
# verify.sh 유닛테스트 — 순수 bash assert 하네스 (lib_test.sh/reflect_test.sh와
# 동일 컨벤션)
# =============================================================================
# 사용:
#   ./verify_test.sh
#
# 검증 대상 (SPEC-INFRA-CICD-001 T-005):
#   - poll_health_status: healthy 즉시 도달 시 조기 종료(REQ-CD-018A) / 타임아웃
#     내 미도달 시 실패
#   - poll_running_status: grace period 내 running 도달 시 PASS(경계 포함) /
#     크래시루프(running 미도달) 시 FAIL(REQ-CD-018B 부정절, AC-CD-006B)
#   - verify_reflect_result: UP: 라인은 별도 inspect 호출 없음(REQ-CD-018,
#     AC-CD-010) / RESTART: 라인은 컨테이너별 전략(health-status vs running+grace)
#     분기 / 실패 컨테이너를 VERIFY_FAILED_CONTAINERS에 채움(rollback.sh 소비용)
#
# _docker_inspect를 재정의해 실제 docker 데몬을 전혀 호출하지 않는다.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=./verify.sh
source "$SCRIPT_DIR/verify.sh"

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
# poll_health_status (REQ-CD-018A)
# -----------------------------------------------------------------------------

test_poll_health_status_healthy_immediately_terminates_early() {
  local call_log
  call_log=$(mktemp)
  _docker_inspect() {
    echo "call" >> "$call_log"
    printf 'healthy'
  }
  local rc=0
  poll_health_status "aaa-vmalert" 180 5 || rc=$?
  assert_eq "0" "$rc" "vmalert 즉시 healthy면 PASS해야 함"
  local calls
  calls=$(wc -l < "$call_log" | tr -d ' ')
  assert_eq "1" "$calls" "healthy 도달 즉시 종료해야 함(전체 타임아웃까지 폴링하면 안 됨)"
  rm -f "$call_log"
}

test_poll_health_status_timeout_returns_failure() {
  # vmalert가 healthy 도달 못하고 타임아웃 → FAIL
  _docker_inspect() { printf 'starting'; }
  _verify_sleep() { :; }
  local rc=0
  poll_health_status "aaa-vmalert" 10 5 || rc=$?
  assert_eq "1" "$rc" "타임아웃 내 healthy 미도달이면 FAIL이어야 함"
}

# -----------------------------------------------------------------------------
# poll_running_status (REQ-CD-018B, vector 전용)
# -----------------------------------------------------------------------------

test_poll_running_status_reaches_running_within_grace_passes() {
  local seq_file idx_file
  seq_file=$(mktemp)
  idx_file=$(mktemp)
  printf 'starting\nstarting\nrunning\n' > "$seq_file"
  echo 0 > "$idx_file"
  _docker_inspect() {
    local i line
    i=$(cat "$idx_file")
    line=$(sed -n "$((i + 1))p" "$seq_file")
    echo $((i + 1)) > "$idx_file"
    printf '%s' "$line"
  }
  _verify_sleep() { :; }
  local rc=0
  poll_running_status "aaa-vector" 30 5 || rc=$?
  assert_eq "0" "$rc" "grace period 내 running 도달이면 PASS해야 함"
  rm -f "$seq_file" "$idx_file"
}

test_poll_running_status_crash_loop_never_running_fails() {
  # vector가 grace period 내 crash loop(running 미도달) → FAIL(AC-CD-006B)
  _docker_inspect() { printf 'exited'; }
  _verify_sleep() { :; }
  local rc=0
  poll_running_status "aaa-vector" 15 5 || rc=$?
  assert_eq "1" "$rc" "crash loop로 running에 도달 못하면 FAIL이어야 함(REQ-CD-018B 부정절)"
}

test_poll_running_status_boundary_last_moment_still_passes() {
  # acceptance.md 엣지 케이스: grace period 마지막 순간 running 도달 → 성공(경계 포함).
  local seq_file idx_file
  seq_file=$(mktemp)
  idx_file=$(mktemp)
  # grace=10, interval=5 → 루프 내 체크는 elapsed=0,5에서 발생하고 elapsed=10은
  # 루프 종료 후 경계값 최종 확인에서 커버된다.
  printf 'starting\nstarting\nrunning\n' > "$seq_file"
  echo 0 > "$idx_file"
  _docker_inspect() {
    local i line
    i=$(cat "$idx_file")
    line=$(sed -n "$((i + 1))p" "$seq_file")
    echo $((i + 1)) > "$idx_file"
    printf '%s' "$line"
  }
  _verify_sleep() { :; }
  local rc=0
  poll_running_status "aaa-vector" 10 5 || rc=$?
  assert_eq "0" "$rc" "grace period 마지막 순간 running 도달도 PASS(경계 포함)여야 함"
  rm -f "$seq_file" "$idx_file"
}

# -----------------------------------------------------------------------------
# verify_reflect_result (REQ-CD-018/018A/018B, AC-CD-010)
# -----------------------------------------------------------------------------

test_verify_reflect_result_compose_wait_path_never_calls_inspect() {
  # AC-CD-010: compose --wait 경로(UP: 라인)는 별도 inspect 호출이 발생하지 않음.
  local log
  log=$(mktemp)
  REFLECT_CALL_LOG="$log"
  local rc=0
  verify_reflect_result "UP:vmalert" 180 30 5 || rc=$?
  assert_eq "0" "$rc"
  local log_content
  log_content=$(cat "$log")
  assert_not_contains "$log_content" "INSPECT:" "compose --wait 경로는 중복 inspect 호출이 없어야 함(AC-CD-010)"
  rm -f "$log"
  unset REFLECT_CALL_LOG
}

test_verify_reflect_result_vmalert_healthy_restart_passes() {
  _docker_inspect() { printf 'healthy'; }
  local outfile rc=0
  outfile=$(mktemp)
  # NOTE: 반드시 stdout 리다이렉션으로 호출한다 — $(...) 커맨드 서브셸로 호출하면
  # VERIFY_FAILED_CONTAINERS 전역 배열 변경이 서브셸 안에서만 일어나 호출부에
  # 반영되지 않는다(bash 서브셸 변수 격리).
  verify_reflect_result "RESTART:aaa-vmalert" 180 30 5 > "$outfile" || rc=$?
  assert_eq "0" "$rc"
  assert_contains "$(cat "$outfile")" "VERIFY_PASS:aaa-vmalert"
  assert_eq "0" "${#VERIFY_FAILED_CONTAINERS[@]}"
  rm -f "$outfile"
}

test_verify_reflect_result_vmalert_timeout_fails_and_records_container() {
  # vmalert가 healthy 도달 못하고 타임아웃 → FAIL 캡처(VERIFY_FAILED_CONTAINERS) →
  # deploy.yml에서 rollback 트리거의 입력이 되는 지점.
  _docker_inspect() { printf 'unhealthy'; }
  _verify_sleep() { :; }
  local outfile rc=0
  outfile=$(mktemp)
  verify_reflect_result "RESTART:aaa-vmalert" 10 30 5 > "$outfile" || rc=$?
  assert_eq "1" "$rc"
  assert_contains "$(cat "$outfile")" "VERIFY_FAIL:aaa-vmalert"
  assert_eq "1" "${#VERIFY_FAILED_CONTAINERS[@]}"
  assert_eq "aaa-vmalert" "${VERIFY_FAILED_CONTAINERS[0]}"
  rm -f "$outfile"
}

test_verify_reflect_result_vector_grace_running_passes() {
  local seq_file idx_file outfile
  seq_file=$(mktemp)
  idx_file=$(mktemp)
  outfile=$(mktemp)
  printf 'starting\nrunning\n' > "$seq_file"
  echo 0 > "$idx_file"
  _docker_inspect() {
    local i line
    i=$(cat "$idx_file")
    line=$(sed -n "$((i + 1))p" "$seq_file")
    echo $((i + 1)) > "$idx_file"
    printf '%s' "$line"
  }
  _verify_sleep() { :; }
  local rc=0
  verify_reflect_result "RESTART:aaa-vector" 180 30 5 > "$outfile" || rc=$?
  assert_eq "0" "$rc"
  assert_contains "$(cat "$outfile")" "VERIFY_PASS:aaa-vector"
  rm -f "$seq_file" "$idx_file" "$outfile"
}

test_verify_reflect_result_mixed_pass_fail_populates_failed_containers() {
  _docker_inspect() {
    case "$1" in
      aaa-vmalert) printf 'healthy' ;;
      aaa-vector) printf 'exited' ;;
    esac
  }
  _verify_sleep() { :; }
  local outfile rc=0
  outfile=$(mktemp)
  verify_reflect_result "$(printf 'RESTART:aaa-vmalert\nRESTART:aaa-vector\n')" 10 10 5 > "$outfile" || rc=$?
  assert_eq "1" "$rc"
  local out
  out=$(cat "$outfile")
  assert_contains "$out" "VERIFY_PASS:aaa-vmalert"
  assert_contains "$out" "VERIFY_FAIL:aaa-vector"
  assert_eq "1" "${#VERIFY_FAILED_CONTAINERS[@]}"
  assert_eq "aaa-vector" "${VERIFY_FAILED_CONTAINERS[0]}"
  rm -f "$outfile"
}

# -----------------------------------------------------------------------------
# Run all tests
# -----------------------------------------------------------------------------

run_test test_poll_health_status_healthy_immediately_terminates_early
run_test test_poll_health_status_timeout_returns_failure

run_test test_poll_running_status_reaches_running_within_grace_passes
run_test test_poll_running_status_crash_loop_never_running_fails
run_test test_poll_running_status_boundary_last_moment_still_passes

run_test test_verify_reflect_result_compose_wait_path_never_calls_inspect
run_test test_verify_reflect_result_vmalert_healthy_restart_passes
run_test test_verify_reflect_result_vmalert_timeout_fails_and_records_container
run_test test_verify_reflect_result_vector_grace_running_passes
run_test test_verify_reflect_result_mixed_pass_fail_populates_failed_containers

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
