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

## 2026-06-29 작업 내역

### 가사 띄어쓰기 수정
- `index.html`, `singer.html`: `renderLyricBlock`에서 공백 문자(`' '`) → ` `으로 렌더링. 가사 단어 사이 공백이 화면에 표시되지 않던 버그 수정.

### 2번째 슬라이드 재생 중 표시 안 되는 버그 수정
- 원인: `sl.startBar`는 절대 bar 번호(Logic 세션 전체 기준), `currentBarFloat`는 섹션 내 상대 bar 번호 — 두 값의 기준이 달라 비교가 틀렸음.
- `index.html`, `singer.html`: `findTokens` → `findSlide`로 교체. `relStart = sl.startBar - sec.startBar`(섹션-상대 값)와 `barFloat` 비교. 이제 재생 중에도 정확한 슬라이드 선택.
- 반환값을 전체 slide 객체로 변경(`tokens`뿐 아니라 `instChords`, `isInstrumental`도 포함).

### 간주 8비트 그리드 편집기
- `WebServer.swift`: `renderInstEditor` 완전 재설계. 마디별 단일 코드 입력 → 8비트 그리드(1 + 2 + 3 + 4 +) 입력으로 교체.
- 저장 형식: `segData.instChords: [[{pos, name}]]` — 기존 `tokens` 대신 사용.
- `loadState`, `getSegs`, `saveAll` 모두 `instChords` 지원 추가.

### 간주 코드 전체 표시 + 마디 구분
- `index.html`, `singer.html`: `renderInstDisplay` 신규 함수. 모든 마디를 카드형 그리드로 표시, 각 마디 내 8비트 슬롯 시각화. 빈 마디도 표시.
- `renderSlide` 래퍼 함수 추가: `isInstrumental`이면 `renderInstDisplay`, 아니면 `renderLyricBlock` 호출.

## 2026-06-28 작업 내역 (3차)

### Universal Binary 빌드 + GitHub Release 업데이트

- Release 빌드 시 `ONLY_ACTIVE_ARCH=NO`, `ARCHS="arm64 x86_64"` → Universal Binary (Intel + Apple Silicon 동시 지원)
- Deployment Target: macOS 14.0 → macOS 14 (Sonoma) + macOS 15 (Sequoia) 모두 지원
- GitHub Releases v1.0.0: Universal Binary `.zip` 교체, 릴리즈 노트 갱신

## 2026-06-28 작업 내역 (2차)

### 에디터·밴드뷰·싱어뷰 UI 개편

- `WebServer.swift`: 에디터 전면 교체 — 드래그 선택 방식 → 구분 bar 방식. 마디 박스 사이 gap 클릭으로 오렌지색 구분선 토글. 구분선 기준 세그먼트 자동 분리, 각 세그먼트에 가사/코드 에디터 독립 배치.
- `WebServer.swift`: 기본 슬라이드 자동생성 제거 — 토큰 없는 슬라이드 필터링, 빈 섹션 = 1개 빈 세그먼트 표시.
- `WebServer.swift`: 마디 번호 섹션 내 상대번호(1-based) 표시.
- `WebServer.swift`: 같은 섹션명 링크 버그 수정 — uiKey=song|||sec|||idx(인스턴스별), dataKey=song|||sec(데이터 공유).
- `WebServer.swift`: ghost token 4배 폭 (min-width:72px).
- `Resources/index.html`: 밴드/세션 화면 재설계 — lyric-panel(우측 1/3) 제거, 지금/다음 2컬럼으로 단순화. 각 컬럼: 섹션명→가사+코드(chord-above)→세션노트. 진행률 바 전체 폭 독립 요소(#progress-outer)로 분리.
- `Resources/singer.html`: 싱어 노트 표시 추가 — 현재/다음 카드 우상단에 노란색(#E8A840) 굵은 글씨로 singerNote/nextSingerNote 표시.

## 2026-06-28 작업 내역

### AX 폴링 재설계 + 싱어 뷰 + 가사 편집기

#### LogicPoller 완전 재설계 (Logic Pro CPU 폭주 방지)
- `fullScan()` — 앱 시작 시 1회 전체 스캔 (마커, 변박, BPM, 키, bar/beat)
- `driftTimer` — MTC 정지 시에만 500ms마다 bar/beat만 읽는 경량 드리프트 보정
- `mtcActive` 플래그 — MTC 재생 중이면 AX 드리프트 읽기 완전 스킵
- `syncBarBeat()` — StateEngine에서 점프 감지 시 호출, 100ms 후 강제 읽기
- `readBarBeatForced()` — `cachedMarkers` 비어있으면 `fullScan()` fallback (race condition 수정)

#### StateEngine 점프 감지
- `onJump` 클로저 추가 → AppDelegate에서 `logicPoller.syncBarBeat()` 호출
- `requiredCount = 1` (currentSectionIdx == -1 일 때) — 점프 후 즉시 섹션 확정

#### singer.html 신규 추가
- 상단: 곡 휠(밴드 방식 슬라이딩) + 시계 + 키
- 중간: 현재 섹션 카드(flex:3) / 다음 섹션 카드(flex:2) 상하 배치
- 섹션명 좌상단 가로 배치, 민트 컬러(#5DCAA5) 테두리
- 카운트다운 `#cd-overlap`: 두 카드 경계에 걸쳐 절대 위치
- 다음 섹션이 곡 마커일 때 곡명을 키컬러로 크게 표시
- `?demo` 파라미터: 더미 데이터로 SSE 없이 미리보기
- LyricToken 기반 코드+가사 렌더링 (band view와 동일 데이터)

#### /edit 가사 편집기 전면 개편 (WebServer.swift)
- 기존 단순 테이블 입력 → 사이드바 + 리치 에디터 레이아웃
- 왼쪽: 곡/섹션 트리 (수정된 섹션에 파란 점 표시)
- 오른쪽: `[G]찬양해 [D]찬양해` 형식 textarea + 실시간 미리보기 + 연주 노트
- 미리보기: 어두운 배경에 코드 민트색·가사 흰색, 코드-글자 수직 정렬
- 저장 시 LyricToken 배열로 파싱해 `/save` POST → LyricsStore 반영
- 변경된 섹션만 전송 (dirty 추적)

#### ⚠️ 미구현 — 마디 선택 기반 슬라이드 편집
- `LyricSlide.startBar / barCount`를 활용한 섹션 내 마디 범위 지정 편집 UI
- 현재는 섹션당 슬라이드 1개, startBar/barCount = 0으로 저장
- 추후: 섹션 총 마디 수 표시 + 드래그로 슬라이드 범위 지정

---

## 2026-06-27 작업 내역 (4차) — 설계 확정 (미구현)

### 싱어 뷰 + 가사/코드 편집기 + 카포 기능 설계

> 상세 플랜: `/Users/heehan/.claude/plans/immutable-discovering-patterson.md`

#### 라우팅 변경
- `GET /` → 역할 선택 랜딩 (localStorage 기억)
- `GET /band` → 기존 index.html (경로만 변경)
- `GET /singer` → 신규 singer.html
- `GET /api/sections` → 현재 Logic 섹션 목록 + 마디 수 JSON

#### 신규 데이터 모델 (`Models.swift`)
```swift
struct LyricToken: Codable, Equatable {
    enum TokenType: String, Codable { case char, ghost, br }
    var type: TokenType; var char: String?; var chord: String?
}
struct InstChordSlot: Codable, Equatable { var pos: Int; var name: String }
struct LyricSlide: Codable, Equatable {
    var startBar: Int; var barCount: Int; var isInstrumental: Bool
    var tokens: [LyricToken]; var instChords: [[InstChordSlot]]; var singerNote: String
}
// SectionData에 slides: [LyricSlide] 추가 (기본값 [], 하위호환)
// IndicatorState에 currentSlideTokens, nextSlideTokens, nextSongName, nextSongKey 추가
```

#### 코드 입력 정규화 규칙
- 근음 뒤 `b` → 플랫 (`bb`→B♭, `eb`→E♭)
- 근음 뒤 `s` → 샵, **단 다음 글자가 `u`이면 sus** (`cs7`→C#7, `csus4`→Csus4)
- `#` 병행 지원
- 카포: `localStorage['capo']` 기기별 독립, JS 렌더링 시 변환

#### 가사 편집기 UX (`/edit`)
- 마디 타임라인: **드래그 또는 Shift+클릭**으로 마디 범위 선택 → "슬라이드로 지정"
- 2단계 편집: ① 가사 textarea → ② 코드 입력 (글자 클릭 후 직접 입력, Enter/Space 확정)
- Tab → ghost 빈칸 추가 (가사 뒤 코드 삽입용) / × 또는 Backspace → ghost 삭제
- 간주 모드: 8분음표 그리드 8칸 (`1, +, 2, +, 3, +, 4, +`), 4마디 한 행
- 마커 이름 변경 시 연결 끊긴 섹션 표시 + 수동 재매핑 지원

#### 싱어 뷰 레이아웃 (레퍼런스 확정)
```
┌─────────────────────────────────────────┐ ← 황금색 테두리
│ [C]          [G]   ← 코드 글자 비례 위치│
│ 현재 가사 (흰색 크게, 줄바꿈 보존)      │ ← 왼쪽에 섹션명 세로
└─────────────────────────────────────────┘
           [ 카운트다운 작게 · 중앙 ]
┌─────────────────────────────────────────┐
│ 다음 가사 (희미하게)                    │
└─────────────────────────────────────────┘
┌──────────┬──────────────────┬───────────┐
│ 시계     │ 현재곡명 + 키    │ 다음곡+키 │
└──────────┴──────────────────┴───────────┘
```

---

## 2026-06-27 작업 내역 (3차)

### 상태 메뉴 체크리스트 개선

- `AppDelegate.swift`: `menuWillOpen`에서 IAC Driver 실시간 재확인 (시작 시 1회 체크 → 매번 MIDI 소스 목록 스캔)
- `AppDelegate.swift`: IAC 소스 이름 한국어 대응 — `"버스"` 포함 여부 추가 체크 (한국어 macOS에서 "IAC Driver Bus 1" → "버스 1"로 표시됨)
- `MTCReceiver.swift`: 동일 한국어 대응 — `start()`의 IAC 연결 로직에도 적용
- `MTCReceiver.swift`: MTC / MIDI Clock 수신 타임아웃 추가 — 마지막 수신 후 60초 경과 시 자동으로 빨간색 전환 (곡 사이 일시 정지는 초록 유지)
- GitHub Releases v1.0.0: 코드 화면 제거 + 상태 메뉴 수정된 빌드로 `Indicator.zip` 교체

---

## 2026-06-27 작업 내역 (2차)

### 코드 스트립 표시 방식 개선 + 타이밍 보정 시도

#### 코드 표시 방식 변경 (index.html)
- 전체 코드 배열 슬라이딩 → **5칸 고정 윈도우** 방식으로 전환
  - `prev2 / prev1 / current / next1 / next2` 5칸, 현재 코드는 항상 가운데
  - 섹션 변경 시 `snapStrip(idx)` 즉시 이동, 1칸 전진 시 `slideLeft(idx)` 슬라이드
  - `sliding` 플래그로 중복 애니메이션 방지
- `#chord-now` 마커 div 제거, `justify-content: center`로 항상 중앙 정렬

#### 타이밍 보정 시도 (StateEngine.swift)
- 코드 변경 브로드캐스트 rate limit 우회: `onBeat()`에서 `chordPending` 소모 시 즉시 브로드캐스트
- `compute()` 내 파이프라인 보정: `chordPending = true` + `nextChordMTC`까지 80ms 이내면 `displayChordIdx = currentChordIdx + 1` 미리 노출
- `recalcNextChord()` 기준 변경: `anchorMTC`(AX 기반, 250ms 오차) → `sectionEntryMTC`(비트 정확, 10ms) 기준으로 `nextChordMTC` 계산

#### ⚠️ 미해결 — 코드 타이밍 이슈 보류
- 전반적으로 코드 전환이 실제 비트보다 늦게 표시됨
- 섹션 전환 직후 첫 코드 변경이 한 박자 더 느림
- 근본 원인: MTC 10ms + AX 250ms + SSE rate limit 50ms + 네트워크 지연의 누적
- 브라우저 타이머(`setTimeout`) 방식도 시도했으나 Mac/iPad 클락 비동기 문제로 무의미
- **추후 해결 방향**: MIDI Clock beat 기반으로 코드 인덱스를 완전히 재설계하거나, 브라우저에 BPM + anchorBar + sectionEntryMTC를 넘겨 로컬에서 직접 계산하는 방식 필요

---

## 2026-06-27 작업 내역

### 앱 아이콘 + GitHub Releases 배포

- `Assets.xcassets/AppIcon.appiconset`: 앱 아이콘 신규 추가
  - 배경 `#14141a`, 민트 세리프 대문자 I `#5DCAA5` (Georgia 폰트)
  - 전체 사이즈 생성 (16~1024px, @2x 포함)
- `project.pbxproj`: Deployment Target 26.0 → 14.0 (macOS Sonoma+)
- Universal Binary: arm64 + x86_64 동시 지원
- GitHub Releases v1.0.0: `Indicator.zip` 직접 다운로드 가능
  - 설치: `/Applications`로 이동 → 오른쪽 클릭 → 열기 (보안 경고 우회 1회)

---

## 2026-06-26 작업 내역 (3차)

### AX+MTC+MIDI Clock 하이브리드 싱크 아키텍처 완성

#### 주요 변경
- `StateEngine.swift` 전면 재설계 — AX(섹션 감지) + MTC(부드러운 진행률) + MIDI Clock(박자 카운트다운) 3-레이어 구조
- `LogicPoller.swift`: AX 폴링 백그라운드 스레드(`DispatchSourceTimer`)로 이동 — 메인 스레드 블로킹/멈춤 해결
- `MTCReceiver.swift`: SysEx 크래시 수정 (pkt.length > 256 → 버퍼 오버플로), IAC Driver 전용 연결
- `Models.swift`: `TimeSigEvent` 구조체 추가, `LogicSnapshot.timeSigEvents` 필드 추가

#### 변박(박자 변경) 지원
- `LogicPoller`: '조표 및 박자표 목록' AX 창에서 변박 이벤트 읽기 (1초 캐시)
- `StateEngine`: `calcDuration(from:to:)` / `calcBeats(from:to:)` — 구간 내 변박 경계마다 분리 합산
- `beatsPerBarAt(bar:)` — timeSigEvents 기반 특정 마디의 박자 조회

#### 섹션 감지 안정화
- 재생 중: 같은 섹션 2회 연속 감지 시에만 전환 (AX 순간 오독 방지)
- 정지 상태 / seek 감지: 즉시 반영 (재생헤드 이동 빠른 캐치)
- seek 감지 임계값 0.5s → 2.0s (일시적 MIDI 글리치 오탐 방지)

#### 진행률 / 카운트다운 fallback
- MTC 수신 중: MTC 경과 시간 기반 (부드러움)
- MTC 없음(Logic 동기화 미설정): AX bar 위치 기반 (250ms 해상도)
- Logic 동기화 설정 필수: 환경설정 → 동기화 → MIDI → IAC Driver에 MTC + MIDI Clock 체크

---

## 2026-06-26 작업 내역 (2차)

### 코드 beat-snap, 레이아웃 재설계, POST 저장 버그 수정

#### 코드(Chord) 타이밍 — beat-snap
섹션 전환과 동일한 방식으로 코드 전환도 MIDI Clock beat에 스냅.

| 역할 | 담당 |
|------|------|
| 다음 코드 전환 시점 예측 | `nextChordMTC` (anchorMTC + 남은 bar × beatDuration) |
| 전환 예약 | MTC가 nextChordMTC - 0.5beat 이내 진입 시 `chordPending = true` |
| 전환 실행 | `onBeat()`에서 `chordPending` 소모 → `currentChordIdx += 1` |
| 섹션 변경 시 리셋 | `applySection()`에서 `currentChordIdx = -1`, `recalcNextChord()` 재호출 |

- 다음 섹션 코드 미리보기: `IndicatorState.nextSectionChords` 추가 — 현재 섹션 마지막 그룹일 때 next row에 다음 섹션 첫 4개 표시
- JS `renderChords`: `chords.join(',') + groupIdx` 키로 섹션 변경 감지 → group 번호 동일해도 재빌드

#### 레이아웃 — CSS Grid 공유 행
`#main`을 6행 Grid로 재설계해 지금/다음 컬럼이 동일 행을 공유:

| 행 | 내용 |
|----|------|
| row 1 | sec-label ("지금" / "다음") |
| row 2 | 섹션명 (big text) |
| row 3 | 메타 필 (키·박자·BPM) — 곡 이름 마커일 때만 표시 |
| row 4 | 가사 |
| row 5 | 노트 |
| row 6 | 코드 + 진행률 바 (지금 컬럼 전용) |

→ 한쪽에 가사/노트가 있어도 섹션명이 항상 같은 높이에 정렬됨

#### POST /save 버그 수정
- HTTP 헤더와 바디가 별도 TCP 패킷으로 올 때 바디를 못 받던 문제 수정
- `Content-Length` 헤더 파싱 후 바이트가 부족하면 추가 수신
- JS save 함수: 중복 섹션명(e.g. Verse1 × 2)이 있을 때 빈 값이 기존 값을 덮어쓰지 않도록 수정

---

### 진행률 바 & 카운트다운 & 섹션 전환 완전 재설계

#### 핵심 아키텍처 (3번째 시도, 완전히 새 구조)

| 역할 | 담당 |
|------|------|
| 마커 위치 파악 | AX (미리 읽어둠) |
| 현재 대략 위치 보정 | AX (250ms, 앵커용) |
| 섹션 전환 타이밍 예측 | AX 위치 + MTC 시간으로 계산 |
| 섹션 전환 실행 | MIDI Clock beat (countdownBeats 1→0인 순간) |
| 진행률 바 | MTC 경과 시간 (`currentMTC - sectionEntryMTC`) |
| 카운트다운 | MIDI Clock beat마다 -1 |

**AX는 "감지"가 아니라 "예측 재료 제공" 역할** — bar 위치 계산에 쓰지 않으므로 250ms 튐이 진행률/카운트다운에 전혀 영향 없음

#### 주요 변경 파일
- `StateEngine.swift`: 완전 재작성
  - `sectionEntryMTC`: 섹션 진입 시점 MTC 기록
  - `transitionMTC`: 다음 섹션 전환 예상 MTC (AX 위치 + 마커 정보로 계산)
  - `transitionPending` 제거 — countdownBeats 1→0 beat에서 직접 전환 실행
  - MTC 0.5초 이상 점프 감지 → 되감기/점프 자동 리셋
  - AX 전환 감지 시 bar 위치가 현재보다 뒤면 무시 (MIDI Clock 전환 후 AX 역행 방지)
- `MTCReceiver.swift`: IAC Driver 소스만 연결 (다른 앱 MIDI Clock 반사 방지), MIDI Clock(0xF8) 수신
- `AppDelegate.swift`: `mtcReceiver.onBeat` → `stateEngine.onBeat()` 연결, 메뉴바 온보딩 체크리스트 추가
- `MTCReceiver.swift`: `iacConnected`, `mtcReceived`, `clockReceived` 플래그 노출 (온보딩용)
- `dev-run.sh`: 설치 후 `tccutil reset Accessibility` 자동 호출

#### 온보딩 체크리스트 (메뉴바)
메뉴바 클릭 시 6가지 항목을 실시간으로 표시. ● 초록 = 정상, ○ 빨강 = 미설정 (클릭 시 해당 설정 화면으로 이동):
1. 손쉬운 사용 권한 → 시스템 설정
2. Logic Pro 실행 중
3. IAC Driver 연결됨 → 오디오 MIDI 설정
4. MTC 수신 중 → Logic 동기화 설정 안내
5. MIDI Clock 수신 중 → Logic 동기화 설정 안내
6. 마커 목록 창 열림

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
