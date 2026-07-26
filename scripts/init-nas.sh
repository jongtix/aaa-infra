#!/usr/bin/env bash
# =============================================================================
# init-nas.sh — NAS 최초 배포 전 호스트 환경 초기화
# =============================================================================
# docker compose up 실행 전에 1회 실행한다.
# 멱등성 보장: 반복 실행해도 기존 데이터를 손상하지 않는다.
#
# 사용법:
#   sudo bash scripts/init-nas.sh              # 최초 배포 전체 초기화
#   sudo bash scripts/init-nas.sh --reset-acl   # ACL 리셋만 (아래 참고)
#
# 사전 조건:
#   1. 프로젝트 루트 .env 파일에 AAA_SSD_BASE, AAA_HDD_BASE 설정 완료
#   2. SSD/HDD 볼륨이 마운트된 상태
#
# 실행 후 추가 작업:
#   1. 설정 파일 배치 — my.cnf, redis.conf, users.acl → config 디렉토리
#   2. 시크릿 파일 배치 — .env.mysql, .env.redis, .env.common → secrets 디렉토리
#   3. chmod 600 ${AAA_SSD_BASE}/secrets/.env.*
#   4. docker compose up -d
#
# --reset-acl 모드 (aaa-infra#118):
#   UGOS 소프트웨어 업데이트가 공유폴더(SSD_1/HDD_1)에 UGOS 전용 ACL을
#   재적용하면, NAS에 등록되지 않은 컨테이너 uid(999/1004/1005/1006/65534)의
#   파일 open이 커널 레벨에서 거부되어 mysql/redis/alertmanager/vector가
#   크래시루프에 빠진다. Step 3와 달리 로그/상태 디렉토리 하위 "기존 파일"까지
#   재귀로 chown/chmod해 리셋한다(Step 3는 비재귀라 디렉토리만 리셋되고
#   기존 파일의 ACL은 남는다 — 2026-07-25 장애 실측으로 확인).
#   데이터 디렉토리(data/mysql, data/redis)는 대상에서 제외한다: 라이브 DB
#   파일의 불필요한 재귀 chown을 피하고, 실측상 이 두 디렉토리는 ACL
#   재적용 대상이 아니었다.
#   부팅마다 자동 실행하려면 scripts/aaa-reset-acl.service를 systemd에
#   등록한다 (docs/UGOS-ACL-RESET.md 참고).
# =============================================================================

set -euo pipefail

# --- 색상 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- UID 정의 ---
# DB 서비스: MySQL 8.4, Redis 8.6 공식 이미지 내부 프로세스 UID
# 확인: docker inspect --format='{{.Config.User}}' mysql:8.4
DB_UID=999
# 앱 서비스: Dockerfile에서 adduser -u 로 고정한 비루트 유저
# 확인: grep 'adduser' aaa-collector/Dockerfile
APP_UID=1004
# analyzer 전용 UID(SPEC-ANALYZER-FOUNDATION-001) — APP_UID(collector/vector)와 공유하지 않는다
ANALYZER_UID=1005
# notifier 전용 UID(SPEC-NOTIFIER-FOUNDATION-001) — APP_UID(collector/vector)와 공유하지 않는다
NOTIFIER_UID=1006
# Alertmanager 공식 이미지 실행 유저(nobody)
AM_UID=65534

# --- 모드 파싱 ---
RESET_ACL_ONLY=false
if [[ "${1:-}" == "--reset-acl" ]]; then
    RESET_ACL_ONLY=true
fi

# =============================================================================
# Step 1. 사전 검증
# =============================================================================

# root 권한 확인
if [[ $EUID -ne 0 ]]; then
    error "root 권한이 필요합니다. sudo로 실행하세요."
    exit 1
fi

# 프로젝트 루트 .env 로드
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${PROJECT_ROOT}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    error "프로젝트 루트 .env 파일이 없습니다: $ENV_FILE"
    error "docker-compose.yml과 같은 디렉토리에 .env 파일을 먼저 생성하세요."
    exit 1
fi

# .env에서 변수 로드 (export 없이 값만 추출)
AAA_SSD_BASE="$(grep -E '^AAA_SSD_BASE=' "$ENV_FILE" | cut -d'=' -f2- | sed "s/^['\"]//;s/['\"]$//")"
AAA_HDD_BASE="$(grep -E '^AAA_HDD_BASE=' "$ENV_FILE" | cut -d'=' -f2- | sed "s/^['\"]//;s/['\"]$//")"

if [[ -z "$AAA_SSD_BASE" ]]; then
    error "AAA_SSD_BASE가 .env에 설정되지 않았습니다."
    exit 1
fi

if [[ -z "$AAA_HDD_BASE" ]]; then
    error "AAA_HDD_BASE가 .env에 설정되지 않았습니다."
    exit 1
fi

info "AAA_SSD_BASE=$AAA_SSD_BASE"
info "AAA_HDD_BASE=$AAA_HDD_BASE"

# 마운트 포인트 존재 확인
if [[ ! -d "$AAA_SSD_BASE" ]]; then
    error "SSD 경로가 존재하지 않습니다: $AAA_SSD_BASE"
    error "볼륨이 마운트되었는지 확인하세요."
    exit 1
fi

if [[ ! -d "$AAA_HDD_BASE" ]]; then
    error "HDD 경로가 존재하지 않습니다: $AAA_HDD_BASE"
    error "볼륨이 마운트되었는지 확인하세요."
    exit 1
fi

# sudo 실행자 감지 (config/secrets 소유권 설정용)
# --reset-acl 모드는 config/secrets를 건드리지 않고 부팅 시 root로(비-sudo) 실행되므로
# SUDO_USER 요구를 건너뛴다.
if [[ "$RESET_ACL_ONLY" == false ]]; then
    HOST_USER="${SUDO_USER:-}"
    if [[ -z "$HOST_USER" ]]; then
        error "SUDO_USER를 감지할 수 없습니다. 'sudo bash scripts/init-nas.sh'로 실행하세요."
        exit 1
    fi
    HOST_GROUP="$(id -gn "$HOST_USER")"
    info "호스트 사용자: $HOST_USER:$HOST_GROUP"

    # UID 충돌 확인
    if id $DB_UID &>/dev/null; then
        EXISTING_USER="$(id -nu $DB_UID 2>/dev/null || echo 'unknown')"
        warn "UID $DB_UID가 이미 사용 중입니다 (user: $EXISTING_USER)."
        warn "MySQL/Redis 컨테이너가 이 UID를 사용합니다. 충돌 여부를 확인하세요."
    fi
fi

info "사전 검증 완료"
echo ""

# =============================================================================
# --reset-acl 모드: ACL 리셋만 수행하고 종료 (aaa-infra#118)
# =============================================================================
if [[ "$RESET_ACL_ONLY" == true ]]; then
    info "ACL 리셋 모드 — 로그/상태 디렉토리를 재귀로 리셋합니다..."
    echo ""

    # uid:gid → 대상 디렉토리 매핑. 디렉토리 자체 + 하위 전체(기존 파일 포함)를 재귀 리셋한다.
    # data/mysql, data/redis는 라이브 DB 파일이라 제외 — Step 3와 동일 정책, 재귀 불필요(실측상 ACL 미적용 대상).
    reset_targets=(
        "${DB_UID}:${DB_UID}:${AAA_HDD_BASE}/logs/mysql"
        "${DB_UID}:${DB_UID}:${AAA_HDD_BASE}/logs/redis"
        "${APP_UID}:${APP_UID}:${AAA_HDD_BASE}/logs/aaa-collector"
        "${APP_UID}:${APP_UID}:${AAA_HDD_BASE}/data/vector"
        "${ANALYZER_UID}:${ANALYZER_UID}:${AAA_HDD_BASE}/logs/aaa-analyzer"
        "${NOTIFIER_UID}:${NOTIFIER_UID}:${AAA_HDD_BASE}/logs/aaa-notifier"
        "${AM_UID}:${AM_UID}:${AAA_HDD_BASE}/data/alertmanager"
    )

    for target in "${reset_targets[@]}"; do
        owner="${target%%:*}"
        rest="${target#*:}"
        group="${rest%%:*}"
        dir="${rest#*:}"

        if [[ ! -d "$dir" ]]; then
            warn "  대상 디렉토리가 없어 건너뜁니다: $dir"
            continue
        fi

        chown -R "${owner}:${group}" "$dir"
        find "$dir" -type d -exec chmod 750 {} +
        find "$dir" -type f -exec chmod 640 {} +
        info "  재귀 리셋 완료: $dir (uid:gid=${owner}:${group})"
    done

    echo ""
    info "ACL 리셋 완료. 'docker compose up -d'로 컨테이너를 (재)기동하세요."
    exit 0
fi

# =============================================================================
# Step 2. 디렉토리 생성
# =============================================================================

info "디렉토리 생성 시작..."

dirs=(
    "${AAA_SSD_BASE}/secrets"
    "${AAA_SSD_BASE}/data/mysql"
    "${AAA_SSD_BASE}/data/redis"
    "${AAA_SSD_BASE}/config"
    "${AAA_SSD_BASE}/config/mysql"
    "${AAA_SSD_BASE}/config/mysql/initdb.d"
    "${AAA_SSD_BASE}/config/redis"
    "${AAA_HDD_BASE}/logs/mysql"
    "${AAA_HDD_BASE}/logs/redis"
    "${AAA_HDD_BASE}/logs/aaa-collector"
    "${AAA_HDD_BASE}/logs/aaa-analyzer"
    "${AAA_HDD_BASE}/logs/aaa-notifier"
    # 관측성 스택(OBSV-001): 신규 bind-mount 소스 — 사전 생성 필요
    "${AAA_HDD_BASE}/data/victoriametrics"
    "${AAA_HDD_BASE}/data/alertmanager"
    "${AAA_SSD_BASE}/config/victoriametrics"
    "${AAA_SSD_BASE}/config/vmalert"
    "${AAA_SSD_BASE}/config/alertmanager"
    # 로그 수집 스택(SPEC-OBSV-LOGS-001): bind-mount 소스 사전 생성
    "${AAA_HDD_BASE}/data/victorialogs"
    "${AAA_HDD_BASE}/data/vector"
    "${AAA_SSD_BASE}/config/vector"
)

for dir in "${dirs[@]}"; do
    mkdir -p "$dir"
    info "  $dir"
done

echo ""

# =============================================================================
# Step 3. 소유권 설정 (데이터/로그 디렉토리)
# =============================================================================
info "소유권 설정 (UID $DB_UID: MySQL/Redis, UID $APP_UID: 앱 서비스)..."

chown_db_dirs=(
    "${AAA_SSD_BASE}/data/mysql"
    "${AAA_SSD_BASE}/data/redis"
    "${AAA_HDD_BASE}/logs/mysql"
    "${AAA_HDD_BASE}/logs/redis"
)

for dir in "${chown_db_dirs[@]}"; do
    chown $DB_UID:$DB_UID "$dir"
    chmod 750 "$dir"
    info "  chown $DB_UID:$DB_UID + chmod 750 $dir"
done

chown_app_dirs=(
    "${AAA_HDD_BASE}/logs/aaa-collector"
    # vector 체크포인트 디렉토리: APP_UID(1004) 소유 필수 — vector가 체크포인트를 기록해야 재시작 후 중복 적재 방지(REQ-013)
    "${AAA_HDD_BASE}/data/vector"
)

for dir in "${chown_app_dirs[@]}"; do
    chown $APP_UID:$APP_UID "$dir"
    chmod 750 "$dir"
    info "  chown $APP_UID:$APP_UID + chmod 750 $dir"
done

# analyzer는 ANALYZER_UID(1005, 상단 정의)로 실행된다(SPEC-ANALYZER-FOUNDATION-001, SPEC-OBSV-LOGS-002).
# $APP_UID(1004, collector/vector 전용)를 재사용하지 않고 별도 명시적 chown으로 처리한다(notifier와 동일 패턴).
chown_analyzer_dirs=(
    "${AAA_HDD_BASE}/logs/aaa-analyzer"
)

for dir in "${chown_analyzer_dirs[@]}"; do
    chown $ANALYZER_UID:$ANALYZER_UID "$dir"
    chmod 750 "$dir"
    info "  chown $ANALYZER_UID:$ANALYZER_UID + chmod 750 $dir"
done

# notifier는 $APP_UID(1004, collector/vector 전용)를 공유하지 않고 NOTIFIER_UID(1006, 상단 정의)로
# 실행된다(SPEC-NOTIFIER-FOUNDATION-001, analyzer가 로그 볼륨을 가진다면 1005를 쓰는 것과 동일한 이유).
chown_notifier_dirs=(
    "${AAA_HDD_BASE}/logs/aaa-notifier"
)

for dir in "${chown_notifier_dirs[@]}"; do
    chown $NOTIFIER_UID:$NOTIFIER_UID "$dir"
    chmod 750 "$dir"
    info "  chown $NOTIFIER_UID:$NOTIFIER_UID + chmod 750 $dir"
done

# 관측성(OBSV-001): Alertmanager는 nobody(AM_UID=65534, 상단 정의)로 실행되며 nflog/silences를 /alertmanager에 기록.
# VictoriaMetrics는 root 실행이라 데이터 디렉토리 chown 불필요.
# 로그 스택(SPEC-OBSV-LOGS-001): VictoriaLogs는 root 실행이라 data/victorialogs chown 불필요(DP2).
# data/vector는 APP_UID(1004) 소유 필수 — chown_app_dirs에 포함.
chown_am_dirs=(
    "${AAA_HDD_BASE}/data/alertmanager"
)

for dir in "${chown_am_dirs[@]}"; do
    chown $AM_UID:$AM_UID "$dir"
    chmod 750 "$dir"
    info "  chown $AM_UID:$AM_UID + chmod 750 $dir"
done

echo ""

# =============================================================================
# Step 4. 디렉토리 권한 설정 (시크릿 + 설정)
# =============================================================================

info "설정 디렉토리 소유권 및 권한 설정 ($HOST_USER:$HOST_GROUP, chmod 755)..."

chown_config_dirs=(
    "${AAA_SSD_BASE}/config"
    "${AAA_SSD_BASE}/config/mysql"
    "${AAA_SSD_BASE}/config/mysql/initdb.d"
    "${AAA_SSD_BASE}/config/redis"
    "${AAA_SSD_BASE}/config/victoriametrics"
    "${AAA_SSD_BASE}/config/vmalert"
    "${AAA_SSD_BASE}/config/alertmanager"
    "${AAA_SSD_BASE}/config/vector"
)

for dir in "${chown_config_dirs[@]}"; do
    chown "$HOST_USER:$HOST_GROUP" "$dir"
    chmod 755 "$dir"
    info "  chown $HOST_USER:$HOST_GROUP + chmod 755 $dir"
done

info "시크릿 디렉토리 소유권 및 권한 설정 ($HOST_USER:$HOST_GROUP, chmod 700)..."

chown "$HOST_USER:$HOST_GROUP" "${AAA_SSD_BASE}/secrets"
chmod 700 "${AAA_SSD_BASE}/secrets"
info "  chown $HOST_USER:$HOST_GROUP + chmod 700 ${AAA_SSD_BASE}/secrets"

echo ""

# =============================================================================
# Step 5. 다음 단계 안내
# =============================================================================

info "디렉토리 초기화 완료."
echo ""
info "1) 다음 설정 파일을 배치하세요 (레포 aaa-infra/config/mysql/* 복사):"
echo ""
echo "  설정 파일:"
echo "    ${AAA_SSD_BASE}/config/mysql/my.cnf"
echo "    ${AAA_SSD_BASE}/config/mysql/initdb.d/01-init-collector.sh  (chmod +x 필수)"
echo "    ${AAA_SSD_BASE}/config/redis/redis.conf"
echo "    ${AAA_SSD_BASE}/config/redis/users.acl"
echo "    ${AAA_SSD_BASE}/config/victoriametrics/scrape.yml"
echo "    ${AAA_SSD_BASE}/config/vmalert/rules.yml"
echo "    ${AAA_SSD_BASE}/config/alertmanager/alertmanager.yml"
echo "    ${AAA_SSD_BASE}/config/vector/vector.yaml"
echo ""
echo "  시크릿 파일 (배치 후 chmod 600 적용):"
echo "    ${AAA_SSD_BASE}/secrets/.env.mysql"
echo "    ${AAA_SSD_BASE}/secrets/.env.redis"
echo "    ${AAA_SSD_BASE}/secrets/.env.common"
echo "    ${AAA_SSD_BASE}/secrets/.env.collector"
echo ""
echo "  Alertmanager 토큰 파일 (값-전용: KEY= 없이 값만, 후행 개행 없이 — bot_token_file/chat_id_file로 직접 읽음):"
echo "    ${AAA_SSD_BASE}/secrets/alertmanager.bot_token   (GitHub Actions TELEGRAM_SYSTEM_BOT_TOKEN과 동일 시스템봇 토큰 값, 신규 봇 불필요)"
echo "    ${AAA_SSD_BASE}/secrets/alertmanager.chat_id     (시스템 chat id 값)"
echo "    → 두 토큰 파일은 배치 후 chmod 644 (compose가 secrets uid/gid/mode 무시 →"
echo "      컨테이너 nobody(65534)가 읽도록 0644 필수. 0600이면 AM NOT_READABLE. 디렉토리 700이 호스트 노출 차단)"
echo ""
info "2) docker compose up -d 로 기동하세요."
echo ""
info "3) [최초/복구 DB] collector 최초 부팅(Flyway 스키마 생성) 후, collector Tier-2 UPDATE 권한을 1회 적용하세요 (ADR-026):"
echo "    docker exec -i aaa-mysql sh -c 'mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\"' \\"
echo "      < ${AAA_SSD_BASE}/aaa-infra/config/mysql/grants/collector-tier2-grants.sql"
echo "    # initdb.d는 미존재 테이블에 테이블단위 GRANT 불가(MySQL 8.4 ERROR 1146) → 스키마 생성 후 별도 적용"
echo "    # 검증: SHOW GRANTS FOR 'collector'@'%';"
