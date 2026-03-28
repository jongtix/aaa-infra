#!/usr/bin/env bash
# =============================================================================
# init-nas.sh — NAS 최초 배포 전 호스트 환경 초기화
# =============================================================================
# docker compose up 실행 전에 1회 실행한다.
# 멱등성 보장: 반복 실행해도 기존 데이터를 손상하지 않는다.
#
# 사용법:
#   sudo bash scripts/init-nas.sh
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

info "사전 검증 완료"
echo ""

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
)

for dir in "${chown_app_dirs[@]}"; do
    chown $APP_UID:$APP_UID "$dir"
    chmod 750 "$dir"
    info "  chown $APP_UID:$APP_UID + chmod 750 $dir"
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
info "다음 파일을 배치한 후 docker compose up -d를 실행하세요:"
echo ""
echo "  설정 파일:"
echo "    ${AAA_SSD_BASE}/config/mysql/my.cnf"
echo "    ${AAA_SSD_BASE}/config/mysql/initdb.d/01-init.sh  (chmod +x 필수)"
echo "    ${AAA_SSD_BASE}/config/redis/redis.conf"
echo "    ${AAA_SSD_BASE}/config/redis/users.acl"
echo ""
echo "  시크릿 파일 (배치 후 chmod 600 적용):"
echo "    ${AAA_SSD_BASE}/secrets/.env.mysql"
echo "    ${AAA_SSD_BASE}/secrets/.env.redis"
echo "    ${AAA_SSD_BASE}/secrets/.env.common"
echo "    ${AAA_SSD_BASE}/secrets/.env.collector"
