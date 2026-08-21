#!/usr/bin/env bash
# =============================================================================
# backup-mysql.sh — MySQL 백업 (mysqldump 풀 덤프 + GFS 보존 / binlog PITR 아카이브)
# SPEC-INFRA-DB-BACKUP-001
# =============================================================================
# 단일 스크립트, --mode 인자로 두 systemd USER 유닛(aaa-backup-mysql.timer /
# aaa-backup-binlog.timer)이 서로 다른 동작을 호출한다(design.md §1).
#
#   --mode=full    매일 05:00 KST: mysqldump 풀 덤프 + zstd 압축 + 무결성 검증
#                   + GFS 보존(일간 7/주간 4/월간 6) + 메트릭 푸시(스텁, M4)
#                   REQ-BK-001~006, REQ-SEC-003.
#   --mode=binlog   매시: FLUSH BINARY LOGS + 복사 + 프루닝. **M3에서 구현 예정
#                   — 현재는 스텁**(usage 출력 + 비정상 종료). REQ-BK-010~012.
#
# [전제 조건 — 이 스크립트 자체는 만들지 않는다]
#   PREP-2: config/mysql/grants/backup-grants.sql(신규 DB는 initdb.d/
#           03-init-backup.sh) 라이브 DB 적용(사용자 수동).
#   PREP-3: --defaults-extra-file 자격증명 파일(600 권한, NAS 전용, repo에
#           커밋하지 않음, 사용자 수동 생성). 컨테이너 내부 경로는
#           BACKUP_CNF_CONTAINER_PATH 환경변수로 주입(기본값 아래 참조) —
#           **이 파일을 aaa-mysql 컨테이너에 ro 마운트하는 docker-compose.yml
#           변경은 M5(스케줄러 USER 유닛 배포) 범위다 — systemd 타이머의 첫
#           자동 실행 전에 반드시 선행되어야 한다. M2 시점(현재)에는 이 스크립트
#           자체를 로컬 docker/curl 스텁으로만 검증했고 이 마운트는 아직
#           수행되지 않았다.**
#
# [패스워드 전달 — REQ-BK-003, REQ-SEC-001]
#   mysqldump에는 -p/argv/MYSQL_PWD를 사용하지 않는다 — --defaults-extra-file
#   (600 권한, 컨테이너 ro 마운트)로만 전달한다.
#
# [실패 알림 — REQ-VF-003]
#   .github/deploy/lib.sh의 telegram_notify() curl 패턴을 재사용한다.
#   원본은 GitHub Actions 전용 `::add-mask::` 마스킹을 포함하지만, 이 스크립트는
#   NAS에서 systemd 유닛으로 직접 실행되므로(CI 러너 아님) 그 두 줄은 제외하고,
#   토큰/chat_id는 기존 alertmanager 시크릿 파일(TELEGRAM_SYSTEM_BOT_TOKEN과
#   동일 시스템봇, project_telegram_bot_topology 메모리 참조)을 재사용한다.
#
# [GFS 날짜 연산 — 이식성]
#   GNU `date -d`는 NAS(Debian 12)에서는 동작하지만 로컬 macOS 검증 환경(BSD
#   date)에서는 동작하지 않는다. 플랫폼 분기 대신 Sakamoto 알고리즘(요일) +
#   Fliegel–Van Flandern JDN 공식(날짜 차이)을 순수 bash 정수 연산으로 구현해
#   외부 `date` 바이너리 방언에 전혀 의존하지 않는다 — NAS·CI·로컬 어디서나
#   동일하게 동작함이 보장된다(자체 검증: dow(2026,8,21)=5=금요일 실측과 일치).
#
# 사용법: backup-mysql.sh --mode=full|binlog
# =============================================================================

set -euo pipefail

# ---- 로깅 ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

usage() {
  cat >&2 <<'EOF'
사용법: backup-mysql.sh --mode=full|binlog

  --mode=full    매일 05:00 KST 트리거: mysqldump 풀 덤프 + GFS 보존
  --mode=binlog  매시 트리거: binlog 회전+복사 (M3에서 구현 예정 — 현재 스텁)
EOF
  exit 1
}

# ---- 설정 (환경변수로 오버라이드 가능 — 테스트/검증 용도) ----
MYSQL_CONTAINER="${MYSQL_CONTAINER_NAME:-aaa-mysql}"
BACKUP_CNF_CONTAINER="${BACKUP_CNF_CONTAINER_PATH:-/run/secrets/backup-mysql.cnf}"
TELEGRAM_BOT_TOKEN_FILE="${TELEGRAM_BOT_TOKEN_FILE:-${AAA_SSD_BASE:-}/secrets/alertmanager.bot_token}"
TELEGRAM_CHAT_ID_FILE="${TELEGRAM_CHAT_ID_FILE:-${AAA_SSD_BASE:-}/secrets/alertmanager.chat_id}"
: "${TELEGRAM_CURL_CMD:=curl}"

readonly RETENTION_DAILY=7
readonly RETENTION_WEEKLY=4
readonly RETENTION_MONTHLY=6
readonly SIZE_FLOOR_PERCENT=85  # REQ-BK-004: 직전 대비 이 % 미만이면 알림

# 백업 디렉토리는 실제 실행(run_full/run_binlog) 시점에만 AAA_HDD_BASE를
# 요구한다 — GFS 로직(gfs_classify/gfs_prune)은 디렉토리를 인자로 받으므로
# AAA_HDD_BASE 없이도 단독 테스트 가능하다(팀-리드 지시 E9 시나리오).
backup_dir() {
  echo "${BACKUP_MYSQL_DIR:-${AAA_HDD_BASE:?AAA_HDD_BASE 환경변수가 필요합니다}/backups/mysql}"
}
binlog_dir() {
  echo "${BACKUP_MYSQL_BINLOG_DIR:-$(backup_dir)/binlog}"
}

# =============================================================================
# 순수 bash 날짜 연산 (외부 date 바이너리 비의존 — 상단 주석 참조)
# =============================================================================

# Sakamoto's algorithm — 요일(0=일 1=월 ... 6=토)
_dow() {
  local y=$1 m=$2 d=$3
  local -a t=(0 3 2 5 0 3 5 1 4 6 2 4)
  (( m < 3 )) && y=$((y - 1))
  echo $(( (y + y/4 - y/100 + y/400 + t[m-1] + d) % 7 ))
}

# Fliegel & Van Flandern — Julian Day Number(그레고리력, 정수)
_jdn() {
  local y=$1 m=$2 d=$3
  local a=$(( (14 - m) / 12 ))
  local y2=$(( y + 4800 - a ))
  local m2=$(( m + 12*a - 3 ))
  echo $(( d + (153*m2 + 2)/5 + 365*y2 + y2/4 - y2/100 + y2/400 - 32045 ))
}

# YYYYMMDD → "Y M D" (10진 파싱 시 08/09가 8진수로 오인되지 않도록 10# 접두)
_split_ymd() {
  local ymd="$1"
  echo "$((10#${ymd:0:4})) $((10#${ymd:4:2})) $((10#${ymd:6:2}))"
}

_today_ymd() {
  # `date +FORMAT`(파싱 없는 포맷 출력)은 GNU date(NAS/Debian 12)와
  # BSD date(로컬 macOS 검증 환경) 양쪽에서 동일한 인자로 동작한다 —
  # `-d`/`-j -f`(임의 날짜 파싱)만 방언이 갈리므로 그 경로는 쓰지 않는다.
  # bash 내장 printf '%(...)T'는 bash 4.2+ 전용이라 로컬 bash 3.2(macOS
  # 기본, GPLv3 회피로 구버전 고정)에서 깨지므로 사용하지 않는다.
  date +%Y%m%d
}

# =============================================================================
# GFS(Grandfather-Father-Son) 보존 판정 — stateless, 파일명 날짜만 사용
# design.md §3 / spec.md REQ-BK-006
# =============================================================================

# 인자: $1=대상 디렉토리 $2=오늘 날짜(YYYYMMDD, 생략 시 실제 오늘)
# 출력: "<파일명> KEEP|DELETE" 한 줄씩(stdout)
gfs_classify() {
  local dir="$1" today="${2:-$(_today_ymd)}"
  local ty tm td today_jdn
  read -r ty tm td <<<"$(_split_ymd "$today")"
  today_jdn=$(_jdn "$ty" "$tm" "$td")

  local -a files=() dates=()
  local f base
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    if [[ "$base" =~ ^dump-([0-9]{8})\.sql\.zst$ ]]; then
      files+=("$base")
      dates+=("${BASH_REMATCH[1]}")
    fi
  done < <(find "$dir" -maxdepth 1 -name 'dump-*.sql.zst' -print0 2>/dev/null)

  local n=${#dates[@]}
  (( n == 0 )) && return 0

  # weekly/monthly 후보를 날짜 내림차순 정렬해 최근 N개만 채택
  local -a sunday_dates=() firstofmonth_dates=()
  local i y m d
  for ((i = 0; i < n; i++)); do
    read -r y m d <<<"$(_split_ymd "${dates[$i]}")"
    [[ "$(_dow "$y" "$m" "$d")" == "0" ]] && sunday_dates+=("${dates[$i]}")
    (( d == 1 )) && firstofmonth_dates+=("${dates[$i]}")
  done

  # mapfile(bash 4+)을 쓰지 않는다 — NAS(bash 5.2)뿐 아니라 로컬 검증 환경
  # (macOS 기본 bash 3.2, GPLv3 회피로 구버전 고정)에서도 동일하게 동작해야
  # 하므로 while read 루프로 이식성을 확보한다.
  local -a weekly_keep=() monthly_keep=()
  if (( ${#sunday_dates[@]} > 0 )); then
    while IFS= read -r _wd; do weekly_keep+=("$_wd"); done \
      < <(printf '%s\n' "${sunday_dates[@]}" | sort -r | head -n "$RETENTION_WEEKLY")
  fi
  if (( ${#firstofmonth_dates[@]} > 0 )); then
    while IFS= read -r _md; do monthly_keep+=("$_md"); done \
      < <(printf '%s\n' "${firstofmonth_dates[@]}" | sort -r | head -n "$RETENTION_MONTHLY")
  fi

  _in_list() {
    local needle="$1"; shift
    local x
    for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
    return 1
  }

  for ((i = 0; i < n; i++)); do
    local date_str="${dates[$i]}" file_jdn days_ago is_daily=0 is_weekly=0 is_monthly=0
    read -r y m d <<<"$(_split_ymd "$date_str")"
    file_jdn=$(_jdn "$y" "$m" "$d")
    days_ago=$(( today_jdn - file_jdn ))

    (( days_ago >= 0 && days_ago < RETENTION_DAILY )) && is_daily=1
    if (( ${#weekly_keep[@]} > 0 )) && _in_list "$date_str" "${weekly_keep[@]}"; then is_weekly=1; fi
    if (( ${#monthly_keep[@]} > 0 )) && _in_list "$date_str" "${monthly_keep[@]}"; then is_monthly=1; fi

    if (( is_daily || is_weekly || is_monthly )); then
      printf '%s KEEP\n' "${files[$i]}"
    else
      printf '%s DELETE\n' "${files[$i]}"
    fi
  done
}

# 인자: $1=대상 디렉토리 $2=오늘 날짜(YYYYMMDD, 생략 시 실제 오늘)
gfs_prune() {
  local dir="$1" today="${2:-$(_today_ymd)}"
  local fname verdict
  while read -r fname verdict; do
    [[ -z "$fname" ]] && continue
    if [[ "$verdict" == "DELETE" ]]; then
      info "GFS 프루닝: 삭제 - ${fname}"
      rm -f -- "${dir}/${fname}"
    fi
  done < <(gfs_classify "$dir" "$today")
}

# =============================================================================
# REQ-VF-003 — 실패 즉시 통지 (telegram_notify 패턴 재사용)
# =============================================================================

notify_failure() {
  local text="$1"
  if [[ ! -r "$TELEGRAM_BOT_TOKEN_FILE" || ! -r "$TELEGRAM_CHAT_ID_FILE" ]]; then
    error "Telegram 자격증명 파일을 읽을 수 없어 알림 전송 실패: ${text}"
    return 1
  fi
  local bot_token chat_id
  bot_token="$(<"$TELEGRAM_BOT_TOKEN_FILE")"
  chat_id="$(<"$TELEGRAM_CHAT_ID_FILE")"
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$bot_token" \
    | "$TELEGRAM_CURL_CMD" -sf -K - \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "text=${text}"
}

fail() {
  local msg="$1"
  error "$msg"
  notify_failure "🚨 [aaa-backup] ${msg}" || warn "Telegram 알림 전송도 실패했습니다(위 오류 참조)."
  exit 1
}

# ---- REQ-VF-001/-005 메트릭 푸시 — 스텁(M4에서 구현) ----
push_metric() {
  local mode="$1"
  # TODO(M4): curl -sf -d "aaa_backup_last_success_timestamp_seconds{mode=\"${mode}\"} $(date +%s)" \
  #   "${VM_IMPORT_URL:-http://localhost:8428}/api/v1/import/prometheus"
  info "[stub] mode=${mode} 메트릭 푸시는 M4에서 구현 예정 — 현재는 스킵"
}

# =============================================================================
# --mode=full — REQ-BK-001~006
# =============================================================================
run_full() {
  local dir today dump_file
  dir="$(backup_dir)"
  mkdir -p "$dir"
  chmod 700 "$dir"  # REQ-SEC-003

  today="$(_today_ymd)"
  dump_file="${dir}/dump-${today}.sql.zst"

  info "mysqldump 실행(docker exec ${MYSQL_CONTAINER}) → ${dump_file}"

  # REQ-BK-021: --single-transaction 사용으로 동시 DDL 발생 시 안전하게 실패
  # (deadlock/lock-timeout으로 비정상 종료) — pipefail로 mysqldump 실패를
  # zstd 성공 여부와 무관하게 감지한다.
  if ! docker exec "$MYSQL_CONTAINER" mysqldump \
        --defaults-extra-file="$BACKUP_CNF_CONTAINER" \
        --single-transaction --source-data=2 \
        --routines --events --triggers \
        --set-gtid-purged=OFF --default-character-set=utf8mb4 \
        --no-tablespaces --all-databases \
      | zstd -q -o "$dump_file"; then
    local ps=("${PIPESTATUS[@]}")
    fail "mysqldump 또는 zstd 압축 실패(exit mysqldump=${ps[0]:-?} zstd=${ps[1]:-?}) — dump_file=${dump_file} (REQ-BK-021: 동시 DDL 등으로 인한 안전한 실패일 수 있음)"
  fi
  chmod 600 "$dump_file"

  # REQ-BK-005: 무결성 검증 + SHA256
  if ! zstd -t "$dump_file" 2>/dev/null; then
    fail "zstd 무결성 검증 실패: ${dump_file}"
  fi
  ( cd "$dir" && sha256sum "$(basename "$dump_file")" > "$(basename "$dump_file").sha256" )
  chmod 600 "${dump_file}.sha256"

  # REQ-BK-004: 직전 덤프 대비 85% 미만이면 알림, 최초 실행 시 스킵
  local prev_file
  prev_file="$(find "$dir" -maxdepth 1 -name 'dump-*.sql.zst' ! -name "$(basename "$dump_file")" -exec basename {} \; 2>/dev/null | sort -r | head -n1)"
  if [[ -n "$prev_file" ]]; then
    local cur_size prev_size threshold
    cur_size=$(stat -f%z "$dump_file" 2>/dev/null || stat -c%s "$dump_file")
    prev_size=$(stat -f%z "${dir}/${prev_file}" 2>/dev/null || stat -c%s "${dir}/${prev_file}")
    threshold=$(( prev_size * SIZE_FLOOR_PERCENT / 100 ))
    if (( cur_size < threshold )); then
      notify_failure "⚠️ [aaa-backup] 덤프 크기 이상: ${dump_file}(${cur_size}B) < 직전(${prev_file}, ${prev_size}B)의 ${SIZE_FLOOR_PERCENT}%" \
        || warn "크기 이상 알림 전송 실패(백업 자체는 계속 진행)"
    fi
  else
    info "직전 덤프 없음(최초 실행) — 크기 비교 스킵, 이번 크기를 기준값으로만 기록"
  fi

  gfs_prune "$dir" "$today"
  push_metric full
  info "full 백업 완료: ${dump_file}"
}

# =============================================================================
# --mode=binlog — REQ-BK-010~012 (M3에서 구현 예정 — 현재 스텁)
# =============================================================================
run_binlog() {
  error "binlog 모드는 아직 구현되지 않았습니다(M3에서 구현 예정)"
  exit 1
}

# =============================================================================
# 진입점
# =============================================================================
main() {
  local mode=""
  local arg
  for arg in "$@"; do
    case "$arg" in
      --mode=*) mode="${arg#--mode=}" ;;
      -h|--help) usage ;;
      *) error "알 수 없는 인자: ${arg}"; usage ;;
    esac
  done

  [[ -z "$mode" ]] && usage

  case "$mode" in
    full) run_full ;;
    binlog) run_binlog ;;
    *) error "알 수 없는 --mode 값: ${mode} (full|binlog만 허용)"; usage ;;
  esac
}

# 테스트에서 함수만 재사용할 수 있도록 직접 실행될 때만 main을 호출한다
# (source될 때는 dispatch/usage가 실행되지 않음).
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi
