#!/usr/bin/env bash
# =============================================================================
# aaa-backup-restore-drill.sh — 월 1회 복원 드릴 (SPEC-INFRA-DB-BACKUP-001)
# =============================================================================
# REQ-VF-004: 최신 풀 덤프(dump-<YYYYMMDD>.sql.zst)를 throwaway `mysql:8.4`
# 컨테이너에 복원한 뒤 테이블 수·핵심 테이블 행 수·MAX(trade_date) 신선도를
# 검증하고 컨테이너를 폐기한다. PITR 재생(mysqlbinlog 온디맨드 확보, design.md
# §4 3단계)은 이 드릴의 범위 밖이다 — REQ-VF-004 범위는 풀 덤프 복원 검증만.
#
# 트리거: aaa-backup-restore-drill.timer(systemd USER, 매월 1일 05:30 KST,
#         OnCalendar=*-*-01 05:30:00) 또는 수동:
#           systemctl --user start aaa-backup-restore-drill.service
#
# [단일 커넥션 전략 — 왜 root 패스워드가 필요 없는가]
#   mysqldump --all-databases(backup-mysql.sh --mode=full)는 mysql 시스템
#   스키마(mysql.user 등)도 포함하므로, 복원 도중 root 인증 정보가 소스
#   서버의 값으로 덮어써질 수 있다. 이 스크립트는 복원 SQL과 검증 SELECT를
#   동일한 `docker exec -i ... mysql`(단일 프로세스·단일 커넥션)에 이어붙여
#   실행한다 — 연결이 끊기지 않으므로 재인증이 필요 없다(design.md §4
#   PITR 재생 절차의 "단일 커넥션" 원칙과 동일한 이유).
#
# [자격증명 — REQ-BK-003/REQ-SEC-001 정신 준수, argv/env 패스워드 노출 없음]
#   throwaway 컨테이너는 `-e MYSQL_ALLOW_EMPTY_PASSWORD=yes`로 기동한다.
#   포트 미게시(호스트 네트워크 미노출)·사전 데이터 없음·수명이 검증
#   시간뿐인 ephemeral 인스턴스이므로 패스워드 자체가 불필요하다 — 이는
#   실제 백업 계정 패스워드(REQ-BK-003이 보호 대상으로 하는 것)와 무관한,
#   mysql:8.4 공식 이미지의 최초 기동 관례일 뿐이다.
#
# [폐기 — 성공/실패 무관 항상 실행]
#   trap 기반 cleanup()으로 컨테이너를 EXIT 시 항상 `docker rm -f`한다 —
#   해피패스 마지막 줄에만 배치하지 않는다(M3 binlog 복사 실패 시 부분
#   파일 정리와 동일한 trap 기반 정리 원칙).
#
# 사용법: aaa-backup-restore-drill.sh  (인자 없음, --mode 디스패치 불필요 —
#         단일 목적 스크립트)
# =============================================================================

set -euo pipefail

# ---- 로깅 ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ---- 설정 (환경변수로 오버라이드 가능 — 테스트/검증 용도) ----
: "${DOCKER_CMD:=docker}"
DRILL_MYSQL_IMAGE="${DRILL_MYSQL_IMAGE:-mysql:8.4}"
DRILL_CONTAINER_NAME="${DRILL_CONTAINER_NAME:-aaa-restore-drill-$$}"
DRILL_READY_TIMEOUT_SECONDS="${DRILL_READY_TIMEOUT_SECONDS:-120}"
# REQ-VF-004는 정확한 신선도 임계값을 지정하지 않는다 — daily GFS 등급
# 보존 윈도우(7일, REQ-BK-006)를 근거로 여유를 둔 값을 재량으로 채택했다
# (progress.md Gaps에 판단 근거로 기록).
DRILL_FRESHNESS_DAYS="${DRILL_FRESHNESS_DAYS:-10}"
# REQ-VF-004는 "핵심 테이블"을 지정하지 않는다 — stocks(마스터, 전 시계열
# 테이블의 FK 대상)와 daily_ohlcv(TECHSPEC §4.1 Priority 1, trade_date
# 보유)를 최소 검증 대상으로 선택했다(docs/TECHSPEC.md §4.1 참조,
# progress.md Gaps에 판단 근거로 기록).
MYSQL_DATABASE_NAME="${MYSQL_DATABASE_NAME:-aaa}"
TELEGRAM_BOT_TOKEN_FILE="${TELEGRAM_BOT_TOKEN_FILE:-${AAA_SSD_BASE:-}/secrets/alertmanager.bot_token}"
TELEGRAM_CHAT_ID_FILE="${TELEGRAM_CHAT_ID_FILE:-${AAA_SSD_BASE:-}/secrets/alertmanager.chat_id}"
: "${TELEGRAM_CURL_CMD:=curl}"

# Telegram 알림 "확인:" 줄에 반복 사용하는 복붙용 명령(운영자 관점 문구)
readonly ACTION_JOURNAL_DRILL='ssh nas-ugreen "journalctl --user -u aaa-backup-restore-drill.service -n 50"'
readonly ACTION_RERUN_FULL='systemctl --user start aaa-backup-mysql.service 로 풀 백업 즉시 재실행'

backup_dir() {
  echo "${BACKUP_MYSQL_DIR:-${AAA_HDD_BASE:?AAA_HDD_BASE 환경변수가 필요합니다}/backups/mysql}"
}

# =============================================================================
# REQ-VF-003 패턴 재사용 — Telegram 통지 (backup-mysql.sh와 동일 구현·동일 형식)
# =============================================================================
# [메시지 형식, 2026-08-25 사용자 확정] backup-mysql.sh 주석 참조 — 운영자가
# "무엇이 / 왜 / 뭘 확인" 3줄로 읽도록, 스펙 ID·내부 변수명·raw 에러 출력은
# 본문에서 제외하고 로컬 로그(journalctl)로 유도한다.
_html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }

_telegram_send() {
  local text="$1"
  if [[ ! -r "$TELEGRAM_BOT_TOKEN_FILE" || ! -r "$TELEGRAM_CHAT_ID_FILE" ]]; then
    error "Telegram 자격증명 파일을 읽을 수 없어 알림 전송 실패"
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

# notify_failure <제목> <상태> <확인>
notify_failure() {
  local title="$1" status="$2" action="$3"
  local text
  text=$'🚨 <b>[긴급]</b>\n• <b>'"$(_html_escape "$title")"$'</b>\n상태: '"$(_html_escape "$status")"$'\n확인: '"$(_html_escape "$action")"
  _telegram_send "$text"
}

# fail <제목> <상태> <확인> — 로컬 로그 + Telegram 통지 후 종료
fail() {
  local title="$1" status="$2" action="$3"
  error "${title} — ${status}"
  notify_failure "$title" "$status" "$action" || warn "Telegram 알림 전송도 실패했습니다(위 오류 참조)."
  exit 1
}

# 복원 결과가 불완전한 4가지 경우(테이블 수·stocks·daily_ohlcv·일봉 날짜)는
# 운영자 입장에서 같은 의미("현재 백업으로는 복구 불가")이므로 제목·확인을
# 하나로 묶고 상태의 항목만 치환한다.
fail_incomplete() {
  fail "복원 드릴 실패 — 복원 데이터 불완전" \
    "복원 결과 $1. 현재 백업으로는 복구 불가능" \
    "원본 DB와 대조 → 문제 없으면 ${ACTION_RERUN_FULL} 후 드릴 재시도"
}

# =============================================================================
# throwaway 컨테이너 폐기 — trap 기반(성공/실패 무관 항상 실행)
# =============================================================================

CONTAINER_STARTED=0
cleanup() {
  if [[ "$CONTAINER_STARTED" == "1" ]]; then
    info "throwaway 컨테이너 폐기: ${DRILL_CONTAINER_NAME}"
    "$DOCKER_CMD" rm -f "$DRILL_CONTAINER_NAME" >/dev/null 2>&1 \
      || warn "컨테이너 폐기 실패(수동 정리 필요할 수 있음): ${DRILL_CONTAINER_NAME}"
  fi
}
trap cleanup EXIT

# ---- 최신 덤프 파일 탐색 ----
find_latest_dump() {
  local dir="$1"
  find "$dir" -maxdepth 1 -name 'dump-*.sql.zst' -exec basename {} \; 2>/dev/null \
    | sort -r | head -n1
}

# =============================================================================
# 진입점
# =============================================================================
main() {
  local dir dump_file dump_path
  dir="$(backup_dir)"
  dump_file="$(find_latest_dump "$dir")"
  if [[ -z "$dump_file" ]]; then
    fail "복원 드릴 실패 — 복원할 덤프 없음" \
      "백업 디렉토리에 덤프 파일이 하나도 없음. 풀 백업이 한 번도 성공하지 못했거나 디렉토리가 비워짐" \
      "ssh nas-ugreen \"ls -la ${dir}\" → 풀 백업 실패 알림 이력 대조"
  fi
  dump_path="${dir}/${dump_file}"
  info "복원 대상 덤프: ${dump_path}"

  info "throwaway 컨테이너 기동: ${DRILL_CONTAINER_NAME} (${DRILL_MYSQL_IMAGE})"
  if ! "$DOCKER_CMD" run -d --name "$DRILL_CONTAINER_NAME" \
        -e MYSQL_ALLOW_EMPTY_PASSWORD=yes \
        "$DRILL_MYSQL_IMAGE" >/dev/null; then
    fail "복원 드릴 실패 — 임시 MySQL 기동 불가" \
      "검증용 ${DRILL_MYSQL_IMAGE} 컨테이너를 띄우지 못함. 이미지 pull 실패·이전 드릴 잔존 컨테이너 의심" \
      "ssh nas-ugreen \"docker ps -a | grep ${DRILL_CONTAINER_NAME}\" → 잔존 시 docker rm -f 후 재실행"
  fi
  CONTAINER_STARTED=1

  # [PREP-7 라이브 검증 정정, 2026-08-25] mysql:8.4 공식 이미지는 기동 중
  # 임시(bootstrap) 서버 단계를 거치며, 이 단계에서도 mysqladmin ping이
  # 일시적으로 성공했다가(임시 서버가 응답) 곧바로 실패하는(임시 서버 종료)
  # 구간이 실측된다(t=4~5s 성공 → t=6~7s 실패 → t=8s+ 안정). 첫 성공에
  # 곧바로 복원을 시작하면 임시 서버가 종료되는 타이밍과 겹쳐
  # "Lost connection to MySQL server during query"로 복원이 중단된다.
  # 연속 3회 성공(간격 2초, 총 6초 안정 구간)을 요구해 임시 서버 단계를
  # 건너뛴다 — 이미지 버전마다 다를 수 있는 "ready for connections" 로그
  # 출현 횟수에 의존하지 않는 범용 해법.
  info "컨테이너 준비 대기(최대 ${DRILL_READY_TIMEOUT_SECONDS}초, 연속 3회 성공 요구)"
  local waited=0 consecutive_ok=0
  while (( consecutive_ok < 3 )); do
    if "$DOCKER_CMD" exec "$DRILL_CONTAINER_NAME" mysqladmin ping --silent >/dev/null 2>&1; then
      consecutive_ok=$((consecutive_ok + 1))
    else
      consecutive_ok=0
    fi
    if (( consecutive_ok < 3 )); then
      sleep 2
      waited=$((waited + 2))
      if (( waited >= DRILL_READY_TIMEOUT_SECONDS )); then
        fail "복원 드릴 실패 — 임시 MySQL 응답 없음" \
          "${DRILL_READY_TIMEOUT_SECONDS}초 안에 MySQL이 준비되지 않음. NAS 부하 과다 의심" \
          'ssh nas-ugreen "uptime && docker stats --no-stream" → 부하 해소 후 재실행'
      fi
    fi
  done
  info "컨테이너 준비 완료(대기 ${waited}초)"

  # 검증 SELECT — 복원 SQL과 동일 커넥션에 이어붙여 실행(위 헤더 주석 참조)
  local verify_sql
  verify_sql=$(cat <<SQL
SELECT 'TABLE_COUNT' AS metric, COUNT(*) AS value FROM information_schema.tables WHERE table_schema = '${MYSQL_DATABASE_NAME}'
UNION ALL
SELECT 'STOCKS_COUNT', COUNT(*) FROM ${MYSQL_DATABASE_NAME}.stocks
UNION ALL
SELECT 'DAILY_OHLCV_COUNT', COUNT(*) FROM ${MYSQL_DATABASE_NAME}.daily_ohlcv
UNION ALL
SELECT 'MAX_TRADE_DATE_DAYS_AGO', COALESCE(DATEDIFF(CURDATE(), MAX(trade_date)), -1) FROM ${MYSQL_DATABASE_NAME}.daily_ohlcv;
SQL
)

  info "덤프 복원 + 검증 쿼리 실행(단일 커넥션): ${dump_path}"
  local result
  if ! result="$( { zstd -dc "$dump_path"; printf '%s\n' "$verify_sql"; } \
        | "$DOCKER_CMD" exec -i "$DRILL_CONTAINER_NAME" mysql -N -B --user=root 2>&1 )"; then
    local last_err
    last_err="$(grep -i 'error' <<<"$result" | tail -n1)"
    [[ -z "$last_err" ]] && last_err="$(tail -n1 <<<"$result")"
    error "복원/검증 출력 전문: ${result}"
    fail "복원 드릴 실패 — 덤프 복원 중단" \
      "덤프를 넣는 도중 오류. 덤프 손상 또는 임시 MySQL 다운(메모리 부족) 의심. 마지막 오류: ${last_err}" \
      "${ACTION_JOURNAL_DRILL} → 최신 덤프 손상이면 직전 덤프로 수동 드릴"
  fi

  info "검증 결과(raw):"
  echo "$result"

  local table_count stocks_count daily_ohlcv_count freshness_days
  table_count="$(awk -F'\t' '$1=="TABLE_COUNT"{print $2}' <<<"$result")"
  stocks_count="$(awk -F'\t' '$1=="STOCKS_COUNT"{print $2}' <<<"$result")"
  daily_ohlcv_count="$(awk -F'\t' '$1=="DAILY_OHLCV_COUNT"{print $2}' <<<"$result")"
  freshness_days="$(awk -F'\t' '$1=="MAX_TRADE_DATE_DAYS_AGO"{print $2}' <<<"$result")"

  if [[ -z "$table_count" || -z "$stocks_count" || -z "$daily_ohlcv_count" || -z "$freshness_days" ]]; then
    error "검증 출력 전문: ${result}"
    fail "복원 드릴 실패 — 검증 결과 해석 불가" \
      "복원은 됐으나 검증 응답이 예상 형식이 아님. 테이블 구조 변경 가능성" \
      "${ACTION_JOURNAL_DRILL} → raw 출력 확인 후 스크립트 검증 쿼리 갱신"
  fi

  # AC-VF-004: 테이블 수 · 핵심 테이블 행 수 · MAX(trade_date) 신선도 확인
  if (( table_count < 5 )); then
    fail_incomplete "테이블 ${table_count}개(기대 5개 이상)"
  fi
  if (( stocks_count < 1 )); then
    fail_incomplete "stocks 0행(핵심 마스터 데이터 누락)"
  fi
  if (( daily_ohlcv_count < 1 )); then
    fail_incomplete "daily_ohlcv 0행(핵심 시계열 누락)"
  fi
  if [[ "$freshness_days" == "-1" ]]; then
    fail_incomplete "daily_ohlcv에 일봉 날짜가 전혀 없음"
  fi
  if (( freshness_days > DRILL_FRESHNESS_DAYS )); then
    fail "복원 드릴 실패 — 백업이 오래됨" \
      "복원된 일봉 최신일이 ${freshness_days}일 전(허용 ${DRILL_FRESHNESS_DAYS}일). 최근 풀 백업이 실패했거나 수집이 멈췄을 가능성" \
      "최근 풀 백업/데드맨 알림 이력 확인 → 수집 정상이면 ${ACTION_RERUN_FULL}"
  fi

  info "복원 드릴 PASS: table_count=${table_count} stocks=${stocks_count} daily_ohlcv=${daily_ohlcv_count} freshness_days=${freshness_days}"
}

# 테스트에서 함수만 재사용할 수 있도록 직접 실행될 때만 main을 호출한다
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi
