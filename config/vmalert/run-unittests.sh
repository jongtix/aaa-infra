#!/usr/bin/env bash
# =============================================================================
# vmalert 룰 유닛테스트 병렬 러너 — 샤드(rules_test_*.yaml)당 docker 컨테이너 1개
# =============================================================================
# vmalert-tool unittest는 테스트 블록마다 격리 스토리지를 열고 eval_time까지
# 30s 스텝으로 순차 시뮬레이션하므로 단일 파일 전체 실행은 10분 이상 걸린다.
# 장주기 샤드(gap_weekly 8d)를 격리 분할했으므로 병렬 실행 시
# 벽시계는 최대 샤드 시간으로 수렴한다(약 1/3~1/4).
#
# 사용:
#   ./run-unittests.sh              # 커버리지 대조 + 전체 샤드 병렬
#   ./run-unittests.sh core ops     # 지정 샤드만(파일명의 rules_test_<이름>.yaml 부분)
set -u
cd "$(dirname "$0")"

# vmalert-tool 버전을 하드코딩하지 않고 docker-compose.yml의 vmalert 이미지 태그에서
# 파싱한다(vmalert-tool과 vmalert는 VictoriaMetrics 동일 릴리스로 버전을 공유).
# Dependabot이 compose의 vmalert 태그를 올리면 이 스크립트도 자동으로 따라간다 —
# 별도 동기화 커밋이 필요 없다.
VMALERT_TAG=$(grep -oP 'victoriametrics/vmalert:\K\S+' ../../docker-compose.yml | head -1)
[ -n "$VMALERT_TAG" ] || { echo "[FAIL] docker-compose.yml에서 vmalert 이미지 태그를 찾을 수 없음"; exit 1; }
IMG="victoriametrics/vmalert-tool:${VMALERT_TAG}"
LOGDIR=$(mktemp -d /tmp/vmalert-unittest.XXXXXX)

./check-alert-coverage.sh || exit 1

if [ $# -gt 0 ]; then
  files=""
  for name in "$@"; do
    f="rules_test_${name}.yaml"
    [ -f "$f" ] || { echo "[FAIL] 샤드 없음: $f"; exit 1; }
    files="$files $f"
  done
else
  files=$(ls rules_test_*.yaml)
fi

pids=""
for f in $files; do
  docker run --rm -v "$PWD":/rules "$IMG" unittest --files="/rules/$f" \
    >"$LOGDIR/$f.log" 2>&1 &
  pids="$pids $!:$f"
done

fail=0
for p in $pids; do
  pid="${p%%:*}"; f="${p#*:}"
  if wait "$pid" && grep -q "^SUCCESS" "$LOGDIR/$f.log"; then
    printf 'PASS  %-32s %s\n' "$f" "$(grep -o 'Total time: .*' "$LOGDIR/$f.log")"
  else
    printf 'FAIL  %-32s 로그: %s\n' "$f" "$LOGDIR/$f.log"
    fail=1
  fi
done

[ "$fail" -eq 0 ] && echo "SUCCESS (전체 샤드 통과)" && rm -rf "$LOGDIR"
exit $fail
