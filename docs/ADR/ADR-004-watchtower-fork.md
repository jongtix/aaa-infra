# ADR-004: Watchtower 비공식 포크(nicholas-fedor) 채택

- **상태**: 승인
- **일자**: 2026-03-01
- **관련 문서**: [TECHSPEC 10.3절 — Docker Compose 구성](../TECHSPEC.md#103-docker-compose-구성)

---

## 맥락

containrrr/watchtower는 Docker 컨테이너 이미지 자동 업데이트 도구로, AAA 배포 파이프라인의 핵심 컴포넌트다.

AAA 배포 흐름은 다음과 같다: GitHub Actions → GHCR 이미지 푸시 → Watchtower가 NAS에서 GHCR 폴링 → 자동 업데이트. 이 흐름에서 Watchtower의 지속적인 유지보수가 필수적이다.

그러나 2025-12-17 containrrr/watchtower가 아카이브됨(유지보수 종료 선언). 이에 따라 Docker 29+ 호환 문제 발생 및 보안 패치 중단 상태가 되어, 대체 방안 검토가 필요해졌다.

---

## 결정

**nicholas-fedor/watchtower** 포크를 채택한다 (이미지: `ghcr.io/nicholas-fedor/watchtower`).

재검토 기준: 포크가 6개월 이상 릴리스 없으면 대안을 재검토한다.

---

## 검토한 대안

### 대안 1: nicholas-fedor/watchtower (채택)

containrrr의 drop-in replacement 포크.

| 항목 | 내용 |
|------|------|
| 장점 | containrrr drop-in replacement, 2.9k stars, 60+ 컨트리뷰터, 2~3주 릴리스 주기, Docker 29+ 호환, 공식 문서 사이트 운영 |
| 단점 | 개인 유지보수자 SPOF |

최신 버전: v1.14.2 (2026-02-17)

### 대안 2: beatkind/watchtower

또 다른 활성 포크 중 하나.

| 항목 | 내용 |
|------|------|
| 장점 | 또 다른 활성 포크 |
| 단점 | 311 stars, 최신 v2.3.2 (2025-06-22) 이후 8개월+ 릴리스 없음, 커뮤니티 규모 작음 |

**탈락 이유**: 릴리스 정체, 커뮤니티 규모 부족

### 대안 3: 대안 도구 전환 (Diun / WUD / Tugtainer)

Watchtower 의존을 탈피하여 다른 컨테이너 업데이트 도구로 전환.

| 항목 | 내용 |
|------|------|
| 장점 | Watchtower 의존 탈피 |
| 단점 | Diun은 알림 전용(업데이트 불가), WUD/Tugtainer는 수동 업데이트 필요 → CI/CD 자동 배포 파이프라인 목적에 부합하지 않음 |

**탈락 이유**: 자동 업데이트 기능 부재, 파이프라인 재설계 필요

---

## 결과

- `ghcr.io/nicholas-fedor/watchtower` 이미지를 사용한다.
- 모니터링 기준: 6개월 이상 릴리스 없으면 대안을 재검토한다.
- TECHSPEC 10.3절의 watchtower 이미지 소스를 GHCR (nicholas-fedor 포크)로 수정한다.
