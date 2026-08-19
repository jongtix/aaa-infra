#!/usr/bin/env bash
# .trivyignore(-*) 항목의 만료 판정(expired/warning/ok) 공용 로직 —
# SPEC-INFRA-CVE-SCAN-003 리뷰-수정 패스에서 분리(Item 2, option a).
#
# scan-thirdparty job의 "Compute third-party exception allowlist" 스텝 전용으로
# 소싱된다. scan-self-built job의 "Check .trivyignore expiry" 스텝은 이 파일을
# 소싱하지 않는다 — REQ-CVE-008/AC-08(scan-self-built job byte-identical 유지)
# 제약 때문에 그쪽은 동일 판정 로직이 인라인 중복으로 남아 있다(의도적 미해결,
# progress.md §E.2 review-fix 섹션 참조).
set -euo pipefail

# classify_expiry <exp-date> <today> <warn-date>
#   exp-date가 today보다 이르면 "expired", warn-date보다 이르면 "warning", 아니면 "ok".
#   모든 인자는 YYYY-MM-DD 형식의 UTC 날짜 문자열이어야 한다(문자열 사전식 비교).
classify_expiry() {
  local exp="$1" today="$2" warn="$3"
  if [[ "$exp" < "$today" ]]; then
    echo "expired"
  elif [[ "$exp" < "$warn" ]]; then
    echo "warning"
  else
    echo "ok"
  fi
}
