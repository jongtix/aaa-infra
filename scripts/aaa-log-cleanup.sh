#!/usr/bin/env bash
# =============================================================================
# aaa-log-cleanup.sh — MySQL/Redis 호스트 마운트 로그 보존 정리
# (SPEC-INFRA-LOG-CLEANUP-001)
# =============================================================================
# aaa-collector/aaa-notifier는 logback rollingpolicy로 자체 회전이 이미 확정
# 활성 상태(2026-09-03 jar 내부 번들 application.yml 실측 확인, ADR-011 목표와
# 일치)이고, aaa-analyzer는 별도 작업(Python 네이티브 RotatingFileHandler/
# TimedRotatingFileHandler)으로 다루므로 이 스크립트는 자체 회전이 전혀 없는
# 것으로 확인된 MySQL/Redis 2개 디렉토리만 대상으로 한다(REQ-LC-001).
#
# 대상 디렉토리는 REQ-LC-004에 따라 하드코딩된 배열로만 열거한다 — 환경변수나
# glob 패턴으로 동적 확장하지 않는다.
#
# 설치 (NAS, root):
#   sudo mkdir -p /etc/systemd/system
#   sudo cp scripts/aaa-log-cleanup.service scripts/aaa-log-cleanup.timer \
#      /etc/systemd/system/
#   systemctl daemon-reload
#   systemctl enable --now aaa-log-cleanup.timer
#
# 검증:
#   systemctl is-active aaa-log-cleanup.timer
#   systemctl list-timers aaa-log-cleanup.timer
#   journalctl -u aaa-log-cleanup.service -n 50
# =============================================================================
set -eu

# ${AAA_HDD_BASE}가 정의되지 않으면 명확한 에러로 즉시 종료한다(EC-1,
# backup-mysql.sh의 ${AAA_HDD_BASE:?...} 패턴과 동일).
: "${AAA_HDD_BASE:?AAA_HDD_BASE 환경변수가 필요합니다}"

# 보존 기간(일) — REQ-LC-006 확정값. ADR-011(Java 서비스 로그 로테이션 목표
# "보존 30일")과의 정합 + SPEC-INFRA-DB-BACKUP-001 REQ-BK-006 GFS 최단 계층
# (daily, 7일) 이상 원칙, 두 근거만으로 독립적으로 충분하다(plan-audit iter-1
# D1 — "월 1회 복원 드릴 간격보다 길다"는 세 번째 근거는 삭제됨).
RETENTION_DAYS=30

# 정리 대상 디렉토리 — 정확히 2개(mysql/redis), 하드코딩 배열(REQ-LC-001/004).
# aaa-analyzer/aaa-collector/aaa-notifier는 명시적으로 제외한다 — 절대
# 재포함하지 말 것(§G 안티패턴).
readonly TARGET_DIRS=(
  "${AAA_HDD_BASE}/logs/mysql"
  "${AAA_HDD_BASE}/logs/redis"
)

for dir in "${TARGET_DIRS[@]}"; do
  # 대상 디렉토리가 마운트되지 않았거나 존재하지 않으면 건너뛰고 나머지를
  # 계속 처리한다(REQ-LC-003) — 한 디렉토리의 부재가 스크립트 전체 실행을
  # 중단시켜서는 안 된다.
  if [ ! -d "$dir" ]; then
    echo "[aaa-log-cleanup] SKIP: $dir (디렉토리 없음 또는 마운트되지 않음)"
    continue
  fi

  # mtime 기준 RETENTION_DAYS 초과 파일만 삭제한다. 삭제 파일 수를 stdout에
  # 기록해 journalctl로 사후 확인 가능해야 한다(REQ-LC-005).
  deleted_count=$(find "$dir" -type f -mtime "+${RETENTION_DAYS}" -print -delete | wc -l | tr -d ' ')

  if [ "$deleted_count" -eq 0 ]; then
    echo "[aaa-log-cleanup] OK: $dir (정리 대상 없음, RETENTION_DAYS=${RETENTION_DAYS})"
  else
    echo "[aaa-log-cleanup] OK: $dir (${deleted_count}개 파일 삭제, RETENTION_DAYS=${RETENTION_DAYS})"
  fi
done

echo "[aaa-log-cleanup] DONE"
