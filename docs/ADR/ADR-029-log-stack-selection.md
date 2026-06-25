# ADR-029: 로그 수집 스택 선택 — VictoriaLogs + Vector

| 항목 | 내용 |
|------|------|
| 상태 | Accepted |
| 일자 | 2026-06-25 |
| 관련 이슈 | aaa-infra#33 |
| 관련 SPEC | SPEC-OBSV-LOGS-001 |

## 배경

collector가 JSON ECS 구조화 로그를 호스트 파일(`${AAA_HDD_BASE}/logs/aaa-collector/*.log`)에 기록하지만 UI 기반 ad-hoc 조회 환경이 없어 이상 확인 시 SSH + grep이 필요하다. 이 문서는 로그 저장·조회 백엔드와 수집 에이전트의 선택 근거를 기록한다.

## 결정

**VictoriaLogs + Vector** 조합을 채택한다.

- 백엔드: `victoriametrics/victoria-logs:v1.51.0`
- 수집 에이전트: `timberio/vector:0.56.0`

## 대안 비교

| 기준 | VictoriaLogs + Vector | Grafana Loki + Promtail |
|------|----------------------|------------------------|
| RAM 풋프린트 | ~128M (경량) | ~300-500M (Loki 최소 권장) |
| 기존 스택 통합 | VictoriaMetrics 동일 벤더 · VMUI · 동일 healthcheck 패턴 | Grafana 별도 배포 필요 |
| 쿼리 언어 | LogsQL | LogQL |
| JSON 파싱 | 기본 지원 | Promtail pipeline 필요 |
| Vector 네이티브 sink | 미지원(elasticsearch sink 경유 — DP1) | Promtail이 전용 클라이언트 |
| NAS(N100 8GB) 적합성 | 높음 (저메모리, 단순 설정) | 낮음 (추가 컴포넌트, 높은 메모리) |

## 근거

1. **VictoriaMetrics 제품군 일관성**: 기존 메트릭 스택(VM/vmalert)과 동일 벤더. healthcheck 패턴(`/health → OK`), 하드닝 표준, 볼륨 규약을 그대로 재사용해 운영 부담 최소화.
2. **저자원 환경 적합**: NAS(N100 4코어 8GB)에서 VictoriaLogs ~128M vs Loki 최소 ~300M. 기존 스택 합계 ~2.2GB에서 합계 ~2.4GB로 RAM 70% 임계(5.6GB) 대비 충분한 여유.
3. **Vector 범용성**: file source의 inode 기반 회전 추적·체크포인트로 logback gz-in-place 롤링 환경에서 안정적인 tail 가능. 향후 다른 소스(mysql·redis) 추가 시 동일 에이전트 재사용 가능.
4. **운영 단순성**: VMUI/LogsQL로 별도 Grafana 없이 ad-hoc 조회 가능. SSH 터널 방식으로 외부 노출 없이 안전하게 접근.

## 트레이드오프

- Vector 네이티브 `victoria_logs` sink가 없어 elasticsearch sink + `/insert/elasticsearch/` 엔드포인트 경유(DP1). 설정이 약간 복잡하나 기능상 동등.
- Grafana 생태계(풍부한 대시보드·LogQL 친숙도) 포기. 운영자가 LogsQL을 신규 학습 필요.
- 로그 기반 알림(vmalert 로그 룰)은 별도 후속 작업(§4 Exclusions).

## 연기 항목

- 디스크 크기 상한 플래그(`-retention.maxDiskSpaceUsageBytes`, DP6): 90일 시간 retention으로 운영 후 실측 기반 도입 검토.
- Grafana Loki 통합 대시보드: 본 SPEC 범위 외.
- mysql/redis 등 타 서비스 로그 수집(결정 C): 별도 SPEC.
