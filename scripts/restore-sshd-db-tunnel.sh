#!/usr/bin/env bash
# =============================================================================
# restore-sshd-db-tunnel.sh — 부팅 시 db_tunnel Match 블록 복구
# =============================================================================
# UGOS 업데이트/재부팅이 /etc/ssh/sshd_config를 재생성하면서 db_tunnel 계정용
# `Match User db_tunnel` 블록(AllowTcpForwarding yes + PermitOpen)이 통째로
# 사라지는 사례가 실측됐다(2026-07-26 19:09:42, #118 ACL 장애 재부팅과 동일
# 시각 — UGOS가 그 이벤트에서 sshd_config도 함께 재생성한 것으로 추정).
#
# 전역 `AllowTcpForwarding no`만 남으면 db_tunnel의 `-L` 포트포워딩이 로컬
# 바인딩(리스닝)까지는 성공하지만, 실제 채널 릴레이는 SSH 서버가 거부해
# 접속 즉시 0바이트로 끊긴다(2026-08-13 실측 — SPEC-ANALYZER-TRAIN-AUTOMATION-001
# 수동 학습 실행 중 발견). 맥북 IDE(DataGrip)의 DB 접근 경로도 동일하게
# 끊긴다 — db_tunnel은 학습 자동화와 IDE 접근이 공유하는 유일한 통로다.
#
# 멱등성 보장: Match 블록이 이미 있으면 아무것도 하지 않는다.
#
# 사용법:
#   sudo bash scripts/restore-sshd-db-tunnel.sh
#
# 부팅마다 자동 실행하려면 scripts/aaa-restore-sshd-tunnel.service를
# systemd에 등록한다 (docs/SSHD-DB-TUNNEL-RESTORE.md 참고).
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

SSHD_CONFIG="/etc/ssh/sshd_config"
MARKER="Match User db_tunnel"

if [[ $EUID -ne 0 ]]; then
    error "root 권한이 필요합니다. sudo로 실행하세요."
    exit 1
fi

if [[ ! -f "$SSHD_CONFIG" ]]; then
    error "sshd_config가 없습니다: $SSHD_CONFIG"
    exit 1
fi

if grep -qF "$MARKER" "$SSHD_CONFIG"; then
    info "db_tunnel Match 블록이 이미 존재합니다 — 변경 없음."
    exit 0
fi

warn "db_tunnel Match 블록이 없습니다 — 복구합니다."

# 파일 끝에 추가한다. sshd_config는 top-down 평가라 Match 블록은 그 뒤에
# 오는 모든 지시문에 스코프를 열어버린다 — 반드시 파일의 마지막에 위치해야
# 전역 설정(AllowTcpForwarding no 등)을 안전하게 오버라이드한다.
cat >> "$SSHD_CONFIG" <<'EOF'

Match User db_tunnel
    AllowTcpForwarding yes
    PermitOpen 127.0.0.1:3306
    PermitTTY no
    ForceCommand nologin
    PasswordAuthentication no
EOF

if ! sshd -t; then
    error "sshd_config 문법 검증 실패 — 추가한 블록을 확인하세요."
    error "복구되지 않은 상태로 남습니다(자동 롤백하지 않음, 수동 확인 필요)."
    exit 1
fi

info "문법 검증 통과."

if systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service 2>/dev/null; then
    info "sshd reload 완료 — db_tunnel Match 블록 복구 완료."
else
    warn "sshd reload 실패 또는 서비스명이 다릅니다. 수동으로 reload하세요:"
    warn "  systemctl list-units --type=service | grep -i ssh"
    warn "  systemctl reload <실제 서비스명>"
    exit 1
fi
