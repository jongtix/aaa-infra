#!/usr/bin/env bash
# =============================================================================
# alertname 커버리지 대조 — rules.yml 정의 ↔ rules_test_*.yaml 참조 양방향 검사
# =============================================================================
# 목적:
#   1. 테스트 없는 룰(A−B): 룰만 추가하고 테스트를 안 쓴 누락 검출.
#      의도적 생략은 아래 ALLOW_UNCOVERED에 등재(자매 룰이 동일 패턴을 커버하는 경우만).
#   2. 죽은 참조(B−A): 룰 리네임/삭제 후 옛 이름을 참조하는 테스트 검출.
#      vmalert-tool은 존재하지 않는 alertname의 무발화 기대(exp_alerts: [])를
#      "안 떴으니 통과"로 처리하므로, 오타/리네임 시 테스트가 조용히 무의미해진다.
# 종료 코드: 죽은 참조 또는 허용 목록 밖 미커버 룰 발견 시 1.
set -u
cd "$(dirname "$0")" || exit 1

# 의도적 미커버(2026-07-11 기준): W2 신선도 자매 룰 — 동일 표현식 패턴을
# StaleDomesticDaily/StaleInvestorTrend/StaleDisclosures/StaleVix 테스트가 대표 커버.
ALLOW_UNCOVERED="
CollectorWatermarkFreshnessStaleExtendedHoursAfter
CollectorWatermarkFreshnessStaleExtendedHoursPre
CollectorWatermarkFreshnessStaleOverseasDaily
CollectorWatermarkFreshnessStaleShortSaleDomestic
CollectorWatermarkFreshnessStaleUsdKrw
"

rules=$(awk '/^[[:space:]]*- alert:/ {print $NF}' rules.yml | sort -u)
tests=$(awk '/alertname:/ {print $NF}' rules_test_*.yaml | sort -u)

uncovered=$(comm -23 <(echo "$rules") <(echo "$tests"))
deadrefs=$(comm -13 <(echo "$rules") <(echo "$tests"))

fail=0

if [ -n "$deadrefs" ]; then
  echo "[FAIL] 존재하지 않는 룰을 참조하는 테스트(리네임/오타 의심):"
  while IFS= read -r ref; do echo "  - $ref"; done <<< "$deadrefs"
  fail=1
fi

blocked=""
for r in $uncovered; do
  case "$ALLOW_UNCOVERED" in
    *"$r"*) ;;
    *) blocked="$blocked $r" ;;
  esac
done
if [ -n "$blocked" ]; then
  echo "[FAIL] 테스트가 없는 룰(허용 목록 밖 — 테스트 추가 또는 ALLOW_UNCOVERED 등재 필요):"
  for r in $blocked; do echo "  - $r"; done
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  n_rules=$(echo "$rules" | wc -l | tr -d ' ')
  n_allow=$(echo "$uncovered" | grep -c . || true)
  echo "[OK] alertname 커버리지 정상 — 룰 ${n_rules}종, 의도적 미커버 ${n_allow}종(허용 목록), 죽은 참조 0건"
fi
exit $fail
