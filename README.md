# aaa-infra

AAA (Algorithmic Alpha Advisor) 프로젝트의 인프라 공통 관리 레포지토리.

Docker Compose 구성, 공통 인프라, 프로젝트 문서를 관리한다.

## 프로젝트 개요

한국(KOSPI/KOSDAQ)·미국(NYSE/NASDAQ) 주식 시장 데이터 수집 → ML 분석 → 알림 → 반자동 주문의 MSA 시스템. 1인 개인 프로젝트.

## Quick Start

```bash
# 인프라 전체 기동 (MySQL, Redis)
docker compose up -d

# 특정 서비스만 기동
docker compose up -d mysql redis

# 로그 확인
docker compose logs -f

# 종료
docker compose down
```

## 서비스 구성

`aaa/` 디렉토리 아래 5개 서비스가 각각 독립 git 레포로 존재한다.

| 서비스 | 역할 | 스택 | Phase |
|--------|------|------|-------|
| aaa-infra | Docker Compose, 공통 인프라, 프로젝트 문서 | Docker Compose | 전체 |
| aaa-collector | 데이터 수집 (KIS API + 외부 API) | Java 21, Spring Boot 3.5.11 | 1 |
| aaa-analyzer | ML 분석, 매매 신호 생성 | Python 3.14, FastAPI | 2 |
| aaa-notifier | 알림 필터링 + 텔레그램 발송 | Java 21, Spring Boot 3.5.11 | 3 |
| aaa-trader | 텔레그램 명령 → KIS API 주문 실행 | Java 21, Spring Boot 3.5.11 | 4 |

## 인프라 스택

| 구성 요소 | 버전 | 용도 |
|-----------|------|------|
| MySQL | 8.4 | 단일 DB, 서비스별 사용자·권한 격리 |
| Redis | 8.4 | Streams (서비스 간 이벤트 버스) + 캐싱 |
| Docker Compose | - | 서비스 오케스트레이션 |
| Watchtower | - | GHCR 폴링 → 자동 컨테이너 업데이트 |
| GitHub Actions | - | CI/CD — Docker 이미지 빌드 → GHCR 푸시 |

## 배포 환경

- **프로덕션**: UGREEN DXP2800 NAS (Intel N100, 8→16GB RAM)
- **ML 학습**: MacBook (SSH 접속, 학습 결과 NFS/SMB로 NAS 전송)
- **배포 흐름**: GitHub Push → GitHub Actions 빌드 → GHCR → Watchtower 자동 업데이트

## 디렉토리 구조

```
aaa-infra/
├── docs/
│   ├── PRD.md          — 제품 요구사항 (무엇을, 왜)
│   ├── TECHSPEC.md     — 기술 사양서 (어떻게)
│   ├── MILESTONE.md    — Phase별 마일스톤
│   ├── TODO.md         — 현재 진행 중인 작업 목록
│   └── ADR/            — 아키텍처 결정 기록
└── README.md
```

## 로드맵

Phase별 상세 계획은 [docs/MILESTONE.md](docs/MILESTONE.md) 참조.
