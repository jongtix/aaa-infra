#!/usr/bin/env bash
# =============================================================================
# CD 공용 셸 라이브러리 — SPEC-INFRA-CICD-001 T-002
# =============================================================================
# `.github/deploy/`에 배치한다 (`scripts/`가 아님 — plan.md §1.3).
# REQ-CD-006이 `scripts/` 디렉토리 전체를 NAS 동기화 대상으로 지정하므로,
# CD 헬퍼를 `scripts/`에 두면 "배포 로직이 배포 대상에 포함되는 순환"이 발생한다.
#
# 이 파일은 `deploy.yml`(T-003~T-005)에서 `source`로 불러 쓰는 함수 모음이다.
# 직접 실행 대상이 아니다.
#
# 제공 함수:
#   _parse_env <key> <path>              — collector deploy.yml과 동일한 awk 패턴
#   parse_env_or_fail <key> <path>       — 파싱 실패 시 stdout 비움 + return 1 (REQ-CD-004/004A)
#   create_backup_dir <backup_base>      — ${AAA_HDD_BASE}/backups/cicd/<timestamp>/ 생성 (REQ-CD-001/008)
#   backup_file <src> <repo_rel> <backup_dir> — 덮어쓰기 전 원본 백업 (REQ-CD-008)
#   prune_backup_retention <backup_base> [keep=10] — N=10 보존, 초과분 오래된 것부터 삭제 (DP-4)
#   is_excluded_path <repo_rel>          — 배포 제외목록 판정 (REQ-CD-007)
#   nas_target_path <repo_rel> <infra_dir> <ssd_base> — repo 경로 → NAS 경로 매핑 (REQ-CD-006)
#   list_deploy_candidates <checkout_dir> — 배포대상 후보 파일 목록 (REQ-CD-006)
#   compute_deploy_diff <checkout_dir> <infra_dir> <ssd_base> — per-file diff (REQ-CD-005~007)
#   telegram_notify <bot_token> <chat_id> <text> — ::add-mask:: 적용 후 Telegram 통지 (REQ-SEC-003)
set -eu

# -----------------------------------------------------------------------------
# .env 파싱 (REQ-CD-004 — collector deploy.yml과 동일한 awk `_parse_env` 패턴)
# -----------------------------------------------------------------------------
# 값 자체는 어떤 로그(echo/print)로도 노출하지 않는다. 호출부가 반환값을
# 변수에 담아서만 사용해야 한다.

_parse_env() {
  # $1=key $2=path
  # 프로젝트 시크릿은 'openssl rand -hex 24' 생성값(0-9, a-f)만 사용하므로
  # export 접두사·CRLF·특수문자 없이 단순 KEY=VALUE 형식이 보장됨(collector 규약과 동일)
  awk -F= -v key="$1" '$1==key{v=$2; gsub(/^[ \t"'"'"']+|[ \t"'"'"']+$/, "", v); print v; exit}' "$2"
}

# parse_env_or_fail: 파일 부재·키 부재를 명확한 에러(stderr, 값 미포함)로 알리고
# return 1. 실제 "즉시 종료"는 호출부가 `AAA_SSD_BASE=$(parse_env_or_fail ...) || exit 1`
# 형태로 처리한다(REQ-CD-004A) — 라이브러리 함수 자체가 프로세스를 kill하면
# 테스트 불가능해지므로 return 코드로 위임한다.
parse_env_or_fail() {
  local key="$1" path="$2" value=""

  if [ ! -f "$path" ]; then
    echo "[FATAL] env file not found: $path" >&2
    return 1
  fi

  value=$(_parse_env "$key" "$path")

  if [ -z "$value" ]; then
    echo "[FATAL] required env var not found: $key (path=$path)" >&2
    return 1
  fi

  printf '%s' "$value"
  return 0
}

# -----------------------------------------------------------------------------
# 타임스탬프 백업 (REQ-CD-008, DP-4)
# -----------------------------------------------------------------------------

create_backup_dir() {
  # $1=backup_base — REQ-CD-001(M6): 배포 대상 경로(AAA_SSD_BASE)와는 별개로,
  # 백업 저장 위치는 HDD(AAA_HDD_BASE)를 받는다. 호출부가 어느 base를 넘기든
  # 이 함수는 그 아래 backups/cicd/<timestamp>/ 를 만들 뿐이므로 파라미터명을
  # 범용화한다(기능 변경 없음).
  local backup_base="$1"
  local ts dir
  ts=$(date +%Y%m%d-%H%M%S)
  dir="$backup_base/backups/cicd/$ts"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

backup_file() {
  # $1=src(체크아웃본 or NAS 현재 사본 경로) $2=repo_rel(백업 디렉토리 내 상대경로) $3=backup_dir
  local src="$1" repo_rel="$2" backup_dir="$3"
  mkdir -p "$backup_dir/$(dirname "$repo_rel")"
  if [ -f "$src" ]; then
    cp -p "$src" "$backup_dir/$repo_rel"
  fi
}

# prune_backup_retention: 배포당 1디렉토리 보존 정책(DP-4) — 최근 N개만 남기고
# 초과분은 가장 오래된 것부터 삭제. 디렉토리명이 `YYYYMMDD-HHMMSS` 타임스탬프
# 형식이라 사전순 정렬이 곧 시간순 정렬이다(테스트에서 mtime 편차에 의존하지
# 않아 결정적).
prune_backup_retention() {
  local backup_base="$1" keep="${2:-10}"

  [ -d "$backup_base" ] || return 0

  local dirs=()
  while IFS= read -r d; do
    dirs+=("$d")
  done < <(find "$backup_base" -mindepth 1 -maxdepth 1 -type d | sort)

  local count=${#dirs[@]}
  if [ "$count" -le "$keep" ]; then
    return 0
  fi

  local excess=$((count - keep))
  local i
  for ((i = 0; i < excess; i++)); do
    rm -rf -- "${dirs[$i]}"
  done
  return 0
}

# -----------------------------------------------------------------------------
# 배포 대상 한정(REQ-CD-006) / 제외목록(REQ-CD-007)
# -----------------------------------------------------------------------------

# is_excluded_path: repo-relative 경로가 REQ-CD-007 제외목록에 해당하면 0(true).
is_excluded_path() {
  local rel="$1"
  case "$rel" in
    config/vmalert/rules_test_*.yaml) return 0 ;;
    config/vmalert/run-unittests.sh) return 0 ;;
    config/vmalert/check-alert-coverage.sh) return 0 ;;
    config/mysql/*) return 0 ;;
    config/redis/*) return 0 ;;
    docs/*) return 0 ;;
    *) return 1 ;;
  esac
}

# DEPLOY_TARGET_CONFIG_FILES: config/ 아래 고정 단일 파일 배포대상(REQ-CD-006).
# nas_target_path와 list_deploy_candidates 양쪽에서 공유하는 단일 소스 —
# 신규 config 파일을 배포대상에 추가할 때 이 배열 하나만 갱신하면 된다.
DEPLOY_TARGET_CONFIG_FILES=(
  "config/vmalert/rules.yml"
  "config/alertmanager/alertmanager.yml"
  "config/victoriametrics/scrape.yml"
  "config/vector/vector.yaml"
)

_is_deploy_target_config_file() {
  local rel="$1" f
  for f in "${DEPLOY_TARGET_CONFIG_FILES[@]}"; do
    [ "$rel" = "$f" ] && return 0
  done
  return 1
}

# nas_target_path: repo-relative 경로 → NAS 실제 반영 경로(REQ-CD-006 매핑표).
# 알 수 없는 경로는 return 1(배포대상 아님).
nas_target_path() {
  local rel="$1" infra_dir="$2" ssd_base="$3"
  case "$rel" in
    docker-compose.yml)
      printf '%s\n' "$infra_dir/docker-compose.yml"
      ;;
    scripts/*)
      printf '%s\n' "$infra_dir/$rel"
      ;;
    *)
      if _is_deploy_target_config_file "$rel"; then
        printf '%s\n' "$ssd_base/$rel"
      else
        return 1
      fi
      ;;
  esac
}

# list_deploy_candidates: 체크아웃본 기준 배포대상 후보 경로(제외목록 적용 전) 나열.
list_deploy_candidates() {
  local checkout_dir="$1"
  local fixed=("docker-compose.yml" "${DEPLOY_TARGET_CONFIG_FILES[@]}")
  local f
  for f in "${fixed[@]}"; do
    if [ -f "$checkout_dir/$f" ]; then
      printf '%s\n' "$f"
    fi
  done

  if [ -d "$checkout_dir/scripts" ]; then
    (cd "$checkout_dir" && find scripts -type f | sort)
  fi
}

# compute_deploy_diff: 체크아웃본 vs NAS 현재 사본의 per-file diff(REQ-CD-005).
# 배포대상 한정(REQ-CD-006) + 제외목록(REQ-CD-007) 적용 후, 변경된 파일의
# repo-relative 경로를 한 줄씩 출력한다. NAS측 파일이 아예 없으면 변경으로 간주한다.
compute_deploy_diff() {
  local checkout_dir="$1" infra_dir="$2" ssd_base="$3"
  local rel target

  while IFS= read -r rel; do
    [ -z "$rel" ] && continue

    if is_excluded_path "$rel"; then
      continue
    fi

    target=$(nas_target_path "$rel" "$infra_dir" "$ssd_base") || continue

    if [ ! -f "$target" ] || ! cmp -s "$checkout_dir/$rel" "$target"; then
      printf '%s\n' "$rel"
    fi
  done < <(list_deploy_candidates "$checkout_dir")
}

# -----------------------------------------------------------------------------
# Telegram 통지 (REQ-SEC-003 — ::add-mask:: 적용)
# -----------------------------------------------------------------------------
# TELEGRAM_CURL_CMD를 오버라이드하면 테스트에서 실제 curl 호출 없이 검증 가능.

: "${TELEGRAM_CURL_CMD:=curl}"

telegram_notify() {
  # $1=bot_token $2=chat_id $3=text
  local bot_token="$1" chat_id="$2" text="$3"

  echo "::add-mask::$bot_token"
  echo "::add-mask::$chat_id"

  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$bot_token" \
    | "$TELEGRAM_CURL_CMD" -sf -K - \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=${text}"
}
