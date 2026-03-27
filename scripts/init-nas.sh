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
AAA_SSD_BASE="$(grep -E '^AAA_SSD_BASE=' "$ENV_FILE" | cut -d'=' -f2-)"
AAA_HDD_BASE="$(grep -E '^AAA_HDD_BASE=' "$ENV_FILE" | cut -d'=' -f2-)"

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

# UID 999 충돌 확인
if id 999 &>/dev/null; then
    EXISTING_USER="$(id -nu 999 2>/dev/null || echo 'unknown')"
    warn "UID 999가 이미 사용 중입니다 (user: $EXISTING_USER)."
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
# MySQL 8.4, Redis 8.4 공식 이미지 내부 프로세스 UID: 999
# 이미지 버전 변경 시 UID 확인 필요: docker inspect --format='{{.Config.User}}' mysql:8.4

info "소유권 설정 (UID 999)..."

chown_dirs=(
    "${AAA_SSD_BASE}/data/mysql"
    "${AAA_SSD_BASE}/data/redis"
    "${AAA_HDD_BASE}/logs/mysql"
    "${AAA_HDD_BASE}/logs/redis"
)

for dir in "${chown_dirs[@]}"; do
    chown 999:999 "$dir"
    info "  chown 999:999 $dir"
done

chown_app_dirs=(
    "${AAA_HDD_BASE}/logs/aaa-collector"
)

for dir in "${chown_app_dirs[@]}"; do
    chown 1004:1004 "$dir"
    info "  chown 1004:1004 $dir"
done

echo ""

# =============================================================================
# Step 4. 디렉토리 권한 설정 (시크릿 + 설정)
# =============================================================================

info "시크릿 디렉토리 권한 설정..."

chmod 700 "${AAA_SSD_BASE}/secrets"
info "  chmod 700 ${AAA_SSD_BASE}/secrets/"

info "설정 디렉토리 권한 설정..."

chmod 700 "${AAA_SSD_BASE}/config/mysql"
info "  chmod 700 ${AAA_SSD_BASE}/config/mysql/"
chmod 700 "${AAA_SSD_BASE}/config/redis"
info "  chmod 700 ${AAA_SSD_BASE}/config/redis/"

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
