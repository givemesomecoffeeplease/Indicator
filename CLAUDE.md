# Indicator

라이브 예배 밴드용 실시간 모니터 앱. Logic Pro 재생 상태를 읽어 SSE로 브라우저에 현재 섹션·카운트다운·가사를 표시.

## 빌드 & 실행

```bash
cd ~/Desktop/app/indicator && ./dev-run.sh
```

빌드 → 기존 앱 종료 → `/Applications/Indicator.app` 설치 → **손쉬운 사용 권한 자동 초기화** → 실행까지 자동. 앱 실행 시 손쉬운 사용 팝업이 뜨면 허용. Xcode는 편집용으로만 사용.

## 권한

- **손쉬운 사용(Accessibility)**: Logic Pro AX 트리 읽기에 필요. `/Applications/Indicator.app` 고정 경로를 사용하므로 최초 1회만 승인하면 `dev-run.sh` 실행 시마다 유지됨.
- **MIDI**: IAC Driver 접근 — 앱 실행 시 자동 활성화.

## 주요 파일

```
Indicator/Indicator/
├── AppDelegate.swift      # 앱 진입점, 메뉴바, IAC Driver 설정
├── LogicPoller.swift      # AX API로 Logic 상태 폴링 (0.25s)
├── MTCReceiver.swift      # MIDI Time Code 수신 (isPlaying 감지)
├── StateEngine.swift      # LogicSnapshot + MTC → IndicatorState 계산
├── WebServer.swift        # HTTP 서버 (/, /events SSE, /edit, /save, /export.csv, /import.csv)
├── LyricsStore.swift      # 가사·노트 인메모리 저장소
├── Models.swift           # Marker, LogicSnapshot, IndicatorState, SectionData
├── SSEBroadcaster.swift   # SSE 연결 관리
├── SettingsView.swift     # 카운트다운 설정 UI
└── Resources/index.html  # 브라우저 표시 화면
```

## 2026-06-26 작업 내역

### 진행률 바 & 카운트다운 & 섹션 전환 완전 재설계

#### 핵심 아키텍처 (3번째 시도, 완전히 새 구조)

| 역할 | 담당 |
|------|------|
| 마커 위치 파악 | AX (미리 읽어둠) |
| 현재 대략 위치 보정 | AX (250ms, 앵커용) |
| 섹션 전환 타이밍 예측 | AX 위치 + MTC 시간으로 계산 |
| 섹션 전환 실행 | MTC 임계 도달 → MIDI Clock beat에 스냅 |
| 진행률 바 | MTC 경과 시간 (`currentMTC - sectionEntryMTC`) |
| 카운트다운 | MIDI Clock beat마다 -1 |

**AX는 "감지"가 아니라 "예측 재료 제공" 역할** — bar 위치 계산에 쓰지 않으므로 250ms 튐이 진행률/카운트다운에 전혀 영향 없음

#### 주요 변경 파일
- `StateEngine.swift`: 완전 재작성
  - `sectionEntryMTC`: 섹션 진입 시점 MTC 기록
  - `transitionMTC`: 다음 섹션 전환 예상 MTC (AX 위치 + 마커 정보로 계산)
  - `transitionPending`: MIDI Clock beat 대기 플래그
  - MTC 0.5초 이상 점프 감지 → 되감기/점프 자동 리셋
  - AX 전환 감지 시 bar 위치가 현재보다 뒤면 무시 (MIDI Clock 전환 후 AX 역행 방지)
- `MTCReceiver.swift`: IAC Driver 소스만 연결 (다른 앱 MIDI Clock 반사 방지), MIDI Clock(0xF8) 수신
- `AppDelegate.swift`: `mtcReceiver.onBeat` → `stateEngine.onBeat()` 연결
- `dev-run.sh`: 설치 후 `tccutil reset Accessibility` 자동 호출

#### Logic Pro 설정
- **동기화 → MIDI → IAC 드라이버**: 클락(MIDI Clock) + MTC 둘 다 체크 필요

## 아키텍처

```
Logic Pro
  └─(AX API)─► LogicPoller ─► StateEngine ─► WebServer ─► 브라우저(SSE)
  └─(MIDI MTC)► MTCReceiver ──►      │
                                LyricsStore (가사·노트)
```

## 마커 규칙

- `#곡명` → 곡 구분 마커 (setlist)
- 일반 이름 → 섹션 마커 (Intro, Verse, Chorus 등)
- Logic **마커 목록 창**이 반드시 열려있어야 AX로 읽힘

## 가사·노트 워크플로

1. 메뉴바 → **가사·노트 편집 열기** → 브라우저 에디터에서 직접 입력
2. 또는 메뉴바 → **JSON 내보내기** → 편집 → **JSON 가져오기**
3. Google Sheets 연동: `/edit` 페이지의 **CSV 내보내기** → Sheets 편집 → **CSV 가져오기**

## 웹 엔드포인트

| 경로 | 설명 |
|------|------|
| `GET /` | 메인 인디케이터 화면 |
| `GET /events` | SSE 스트림 |
| `GET /edit` | 가사·노트 웹 에디터 |
| `POST /save` | JSON으로 가사·노트 저장 |
| `GET /export.csv` | CSV 내보내기 |
| `POST /import.csv` | CSV 가져오기 |

## 포트

`8888` — `http://[로컬IP]:8888`
