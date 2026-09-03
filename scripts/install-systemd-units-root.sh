#!/usr/bin/env bash
# =============================================================================
# install-systemd-units-root.sh — aaa DB backup systemd system(root) timer 설치
# =============================================================================
# 2026-09-03 — UGOS 재부팅 후 user-scope timer가 자동 기동되지 않는 문제
# (db_tunnel과 동일 사고 패턴, 8/30·9/2 재현)로 aaa-backup-mysql/
# aaa-backup-binlog/aaa-backup-restore-drill을 root(system) scope로
# 전환했다. aaa-reset-acl.service / aaa-restore-sshd-tunnel.service와
# 동일한 root-scope 패턴.
#
# aaa-timer-watchdog(구 user-scope self-heal watchdog)은 감시 대상이던
# 세 타이머가 root scope로 옮겨가며 무의미해져 함께 폐기했다 — 구
# watchdog 유닛은 NAS에서 수동으로 disable 필요(아래 안내 참조).
#
# 사용법 (NAS, root 필요): sudo bash scripts/install-systemd-units-root.sh
# =============================================================================
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "install-systemd-units-root.sh: root 권한 필요 — sudo로 실행하세요." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="/etc/systemd/system"

for unit in aaa-backup-mysql.service aaa-backup-mysql.timer aaa-backup-binlog.service aaa-backup-binlog.timer aaa-backup-restore-drill.service aaa-backup-restore-drill.timer; do
  cp "${SCRIPT_DIR}/${unit}" "${UNIT_DIR}/${unit}"
  chown root:root "${UNIT_DIR}/${unit}"
  chmod 644 "${UNIT_DIR}/${unit}"
  echo "installed: ${UNIT_DIR}/${unit}"
done

systemctl daemon-reload
systemctl enable --now aaa-backup-mysql.timer
systemctl enable --now aaa-backup-binlog.timer
systemctl enable --now aaa-backup-restore-drill.timer

echo ""
echo "확인: systemctl list-timers | grep aaa"
echo ""
echo "구 user-scope 유닛 정리(1회, 수동):"
echo "  systemctl --user disable --now aaa-backup-mysql.timer aaa-backup-binlog.timer aaa-backup-restore-drill.timer aaa-timer-watchdog.timer"
