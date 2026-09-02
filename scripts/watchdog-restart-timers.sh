#!/usr/bin/env bash
# =============================================================================
# watchdog-restart-timers.sh — inactive systemd --user 타이머 자동 재기동
# =============================================================================
# db_tunnel 복구 패턴(aaa-restore-sshd-tunnel.timer)과 동일한 self-heal
# 방식이다: 재부팅/UGOS 업데이트로 enabled 타이머가 재무장되지 않고
# inactive(dead)로 남는 경우를 짧은 주기로 스스로 재기동한다(SPEC-INFRA-DB-BACKUP-001
# 타이머 3개가 2026-08-30 NAS 재부팅 이후 dead로 방치됐던 사고 대응).
#
# 멱등적이다 — 대상 유닛이 이미 active면 아무것도 하지 않는다.
#
# 사용법:
#   bash scripts/watchdog-restart-timers.sh <unit1.timer> [unit2.timer ...]
# =============================================================================

set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "[ERROR] 대상 타이머 유닛을 최소 1개 이상 인자로 전달하세요." >&2
  exit 1
fi

for unit in "$@"; do
  if systemctl --user is-active --quiet "$unit"; then
    echo "[INFO] ${unit} active — 변경 없음."
  else
    echo "[WARN] ${unit} inactive — 재기동합니다."
    systemctl --user start "$unit"
  fi
done
