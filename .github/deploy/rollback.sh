#!/usr/bin/env bash
# =============================================================================
# CD 배포 실패 복원·통지 — SPEC-INFRA-CICD-001 T-005
# =============================================================================
# `.github/deploy/`에 배치한다(`scripts/`가 아님 — plan.md §1.3, lib.sh/reflect.sh/
# verify.sh와 동일 원칙). `deploy.yml`에서 함께 `source`로 불러 쓰는 함수 모음이다.
# 직접 실행 대상이 아니다.
#
# REQ-CD-019: 배포(verify.sh 검증) 실패 시 백업 복원 + 영향받은 서비스 원상
# 재시작 + Telegram 통지. 통지는 "자동 복원됨"과 "수동 개입 필요"를 구분한다.
# REQ-CD-020: 배포 성공 + DB notify-only 스킵 항목(REQ-CD-015/017 등)이 있으면
# reflect_deploy가 낸 NOTIFY: 라인을 Telegram으로 통지한다.
#
# 테스트 시딩 포인트(rollback_test.sh):
#   - restore_backup_files: lib.sh nas_target_path로 backup_dir → 원위치를 역산해
#     복원한다. 실제 docker 호출이 없는 순수 파일 복사 함수.
#   - restart_failed_containers: reflect.sh의 restart_container(→ _docker_cmd)를
#     재사용한다 — 테스트는 reflect.sh와 동일하게 _docker_cmd를 오버라이드한다.
#   - telegram_notify(lib.sh)를 통해 통지하며, 테스트는 TELEGRAM_CURL_CMD를 오버라이드한다.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=./reflect.sh
source "$SCRIPT_DIR/reflect.sh"

# restore_backup_files <backup_dir> <infra_dir> <ssd_base>
# 백업 디렉토리(REQ-CD-008 타임스탬프 디렉토리, lib.sh backup_file이 생성한 구조)
# 안의 파일들을 lib.sh nas_target_path로 원위치를 역산해 복원한다.
# backup_dir이 없거나 파일이 하나라도 복원 실패하면 return 1.
restore_backup_files() {
  local backup_dir="$1" infra_dir="$2" ssd_base="$3"
  [ -d "$backup_dir" ] || return 1

  local rel target failed=0 found=0
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    found=1
    target=$(nas_target_path "$rel" "$infra_dir" "$ssd_base") || { failed=1; continue; }
    mkdir -p "$(dirname "$target")"
    if cp -p "$backup_dir/$rel" "$target" 2>/dev/null; then
      _call_log_append "RESTORE:$target"
    else
      failed=1
    fi
  done < <(cd "$backup_dir" && find . -type f | sed 's|^\./||' | sort)

  # 백업 디렉토리가 있으나 파일이 하나도 없으면(빈 diff 배포 직후 등) 복원할 것이
  # 없다는 의미이지 실패가 아니다.
  [ "$failed" -eq 0 ]
}

# restart_failed_containers <container...>
# verify.sh VERIFY_FAILED_CONTAINERS를 소비해 원상 재시작한다(reflect.sh의
# restart_container를 재사용 — _docker_cmd 오버라이드로 테스트 가능).
restart_failed_containers() {
  local c failed=0
  for c in "$@"; do
    restart_container "$c" || failed=1
  done
  return "$failed"
}

# rollback_deploy <backup_dir> <infra_dir> <ssd_base> <bot_token> <chat_id> [failed_container...]
# REQ-CD-019: 백업 복원 + 영향받은 서비스 원상 재시작 + Telegram 통지.
# 복원·재시작이 모두 성공하면 "자동 복원됨"(return 0), 하나라도 실패하면
# "수동 개입 필요"(return 1)를 통지한다.
rollback_deploy() {
  local backup_dir="$1" infra_dir="$2" ssd_base="$3" bot_token="$4" chat_id="$5"
  shift 5
  local failed_containers=("$@")

  local restore_ok=1
  restore_backup_files "$backup_dir" "$infra_dir" "$ssd_base" && restore_ok=0

  local restart_ok=0
  if [ "${#failed_containers[@]}" -gt 0 ]; then
    restart_failed_containers "${failed_containers[@]}" || restart_ok=1
  fi

  local nl=$'\n'
  if [ "$restore_ok" -eq 0 ] && [ "$restart_ok" -eq 0 ]; then
    telegram_notify "$bot_token" "$chat_id" \
      "✅ <b>aaa-infra CD 배포 실패 — 자동 복원됨</b>${nl}백업 복원 및 영향받은 서비스 재시작이 완료되었습니다."
    return 0
  fi

  telegram_notify "$bot_token" "$chat_id" \
    "🚨 <b>aaa-infra CD 배포 실패 — 수동 개입 필요</b>${nl}자동 복원 실패(백업 복원 또는 서비스 재시작 단계). 즉시 확인이 필요합니다."
  return 1
}

# notify_pending_items <reflect_result> <bot_token> <chat_id>
# REQ-CD-020: 배포 성공 + reflect_deploy가 낸 NOTIFY: 라인(DB notify-only 스킵
# 등, REQ-CD-013A/015/017)을 전부 Telegram으로 전달한다. NOTIFY: 라인이 없으면
# 아무 것도 하지 않는다(호출 자체는 no-op).
notify_pending_items() {
  local result="$1" bot_token="$2" chat_id="$3"
  local nl=$'\n'
  local line
  while IFS= read -r line; do
    case "$line" in
      NOTIFY:*)
        telegram_notify "$bot_token" "$chat_id" \
          "ℹ️ <b>aaa-infra CD 안내</b>${nl}${line#NOTIFY:}"
        ;;
    esac
  done < <(printf '%s\n' "$result")
}
