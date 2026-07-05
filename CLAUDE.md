# Indicator

## 2026-07-05 작업 내역

### HTML 내보내기/가져오기 버그 수정 (v0.2.1)

#### 문제 1 — slides 디코딩 실패 (가장 근본 원인)
- **원인**: `rawSlidesFromState` JS 함수가 슬라이드 객체에 `singerNote` 필드를 빠뜨림. Swift `LyricSlide` 구조체는 이 필드가 필수(`var singerNote: String`)이므로 자동 Codable 디코딩 실패 → `SectionData.slides`가 항상 `[]`로 저장됨.
- **영향**: 내보내기→가져오기 경로 전체 (일반 `saveAll`은 직접 슬라이드 빌드 시 `singerNote:''` 포함하므로 정상). 가져오기한 가사가 하나도 저장되지 않는 버그.
- **수정**: `rawSlidesFromState`에 `singerNote:''` 추가 (`WebServer.swift`).

#### 문제 2 — `buildExportData` 잘못된 필드 참조
- **원인**: `sec.startBar`(없는 필드, `undefined`)를 `occIdx`로 사용 → dirty 수정사항이 내보내기에 미포함, 반복 섹션(Chorus×2 등) 데이터 오염.
- **수정**: `sec.occIdx`로 교정, 내보낸 섹션 객체에도 `occIdx` 포함 (`WebServer.swift`).

#### 문제 3 — `handleImportFile` 잘못된 저장 키
- **원인**: 서버에 POST할 때 키를 `sec이름`으로만 사용 → 서버가 기대하는 `sec@@occIdx` 형식 불일치. `sec.startBar`(undefined)로 garbage 키 추가 생성.
- **수정**: `sec.sec+'@@'+(sec.occIdx??0)` 형식으로 교정, garbage 키 제거 (`WebServer.swift`).

#### 문제 4 — 구버전 파일 호환 (singerNote 없는 slides)
- **원인**: 이전 버전으로 내보낸 HTML 파일의 slides에 `singerNote` 없음 → 가져오기 시 동일하게 디코딩 실패.
- **수정**: `handleImportFile`에서 `fixSlides()` 헬퍼로 `singerNote` 자동 보완 (`WebServer.swift`).

#### UX 개선
- standalone 모드(팀원 파일)에서 섹션 기본 펼침 (`open:STANDALONE`) — 마디 그리드 즉시 표시.
- standalone 모드 진입 시 안내 배너 표시 ("가사 편집 후 저장 버튼 → 편집 완료 파일 다운로드").

---

## 2026-07-02 작업 내역

### 사전 스캔 v2 완성 — MTC 기반 변박/섹션 결정론적 계산

#### 핵심 설계
- **`ScheduleStore.swift`** (전면 재작성): 스캔 시 모든 변박 이벤트(`TimeSigEvent`, bar 번호)를 MTC 초로 변환해 `ScannedTimeSig` 배열로 저장. `beatsPerBarAt(mtcSeconds:)` — 배열 탐색만으로 즉시 반환, AX 지연 없음.
- **자동 스캔**: 앱 시작 후 MTC 첫 수신 시 자동 스캔 (`AppDelegate.onTimeUpdate`). 조건: 마커+변박+anchorMTC(>0) 모두 있을 때. timeSigs가 1개 이하면 재스캔.
- **bar→MTC 변환**: `convertTimeSigsToMTC()` — 앵커(bar, MTC)에서 앞뒤로 세그먼트별 `barDuration = beatsPerBar × (4/beatUnit) × (60/BPM)` 누산. BPM 일정 가정(변속 없는 곡 전제).

#### StateEngine 변경
- **박자 업데이트**: `applySection()`에서 `ScheduleStore.beatsPerBarAt(mtcSeconds: bounds.start)`로 섹션 진입 시 즉시 확정. `onBeat()`에서 덮어쓰지 않음(경계 직전 MTC로 이전 박자를 반환해 덮어쓰는 race condition 제거).
- **카운트다운**: `onBeat()`마다 `-1` 감소 (MTC 재계산 제거 → 같은 숫자 두 번 나오거나 건너뛰는 버그 수정). 섹션 진입 시 `initCountdown()`으로 MTC 기반 초기값 1회 계산.
- **정지 상태 섹션 감지**: `snapshot.transportMTC`(AX 타임코드 디스플레이, 정지 중에도 읽힘) 우선 사용 → 앵커 추산 폴백.
- **박자 표시**: `compute()`에서 `currentSectionBeatsPerBar/beatUnit`을 그대로 사용 (ScheduleStore 매번 조회 제거).
- **`recompute()` 버그 수정**: `lastState` 업데이트를 실제 브로드캐스트 직전으로 이동 (이전: rate limit 걸려도 `lastState` 갱신 → 이후 상태 변화 묻힘).
- **`transportMTC` 읽기**: `LogicPoller.readTransportValues()`에서 두 번째 "재생헤드 위치" AX 그룹에서 타임코드 읽음 (`snapshot.transportMTC`).

#### 스캔 결과 예시 (20260628click 프로젝트)
```
anchorBar=51 anchorMTC=3600.08 bpm=90.0
3/4 @ 3600.08s  (bar 1)
4/4 @ 3600.08s  (bar 1 기본값 중복 — Logic 기본 4/4가 지워지지 않아 발생)
4/4 @ 3708.08s  (bar 55)
2/4 @ 3751.47s  (bar 71)
3/4 @ 3752.80s  (bar 72)
4/4 @ 3790.80s  (bar 91)
3/4 @ 3881.47s  (bar 125)
4/4 @ 3911.47s  (bar 140)
```

#### 미해결 / 다음 작업
1. **Logic 기본 4/4 중복 문제**: 조표 및 박자표 목록 첫 줄에 위치 없는 기본값(4/4)이 항상 존재. 실제 첫 변박(3/4 @ bar 1)과 같은 MTC에 겹쳐서 `beatsPerBarAt`이 `last(where:)` 기준으로 기본값보다 늦은 걸 반환함 → 현재는 우연히 동작하지만, 기본값이 실제 변박보다 나중에 정렬되면 틀릴 수 있음. **수정 방향**: `extractTimeSigsAndKeys`에서 위치 없는 기본행은 bar 0으로 처리해 항상 가장 앞에 오게 하거나, 같은 bar에 여러 항목이 있으면 마지막 것만 유지.
2. **카운트다운 6에서 시작 버그**: 4/4 섹션인데 3/4 threshold(6)가 적용되는 경우 여전히 발생 여부 테스트 중. `applySection()`에서 `currentSectionBeatsPerBar = 4` 설정 후 `onBeat()`이 덮어쓰지 않도록 수정 완료 — 테스트 필요.
3. **BPM 변속 미지원**: `convertTimeSigsToMTC`는 단일 BPM 가정. 곡 중 BPM 변속이 있으면 변박 MTC 오차 발생. 현재 사용 프로젝트는 BPM 고정이라 무관.
4. **디버그 로그 정리**: `[AX]`, `[BPB]` 등 `debugLog()` 호출 남아있음 — 릴리즈 전 제거 필요.

---

## 2026-06-30 작업 내역

### 섹션 occurrence별 독립 데이터 (가사/코드 손실 버그 근본 수정)
- **버그**: `LyricsStore`가 `song -> sectionName -> SectionData`로만 키를 가져서, 같은 이름 섹션이 여러 번 등장(occurrence)하면 전부 데이터를 공유. 길이(totalBars)가 다른 occurrence를 에디터에서 열면 공유 데이터를 자기 길이로 잘라서 보여주고, 셀 하나만 수정해도 잘린 길이로 원본을 덮어써서 **코드/가사 영구 손실**.
- **해결**: 저장 키를 occurrence 단위(`"섹션명@@startBar"`)로 변경. 기본값은 "독립"이며, 드롭박스에서 "[섹션명] 자동 연결" 선택 시 같은 이름의 가장 이른(canonical) occurrence를 실시간으로 따라감 (`LyricsStore.resolve()`, `Models.swift`의 `SectionData.linked`)
- 마디 수 불일치 처리: 간주 코드는 앞마디부터 채우고 남으면 버림/모자라면 빈 마디(`WebServer.swift`의 `adaptSlides`/`adaptRawSlides`, 서버·클라이언트 동일 로직). 가사는 마디 무관하게 토큰 전체 미러링.
- **수정 시 자동 분리(fork-on-edit)**: "자동 연결" 상태에서 가사/코드를 직접 수정하면 자동으로 "독립적으로 편집"로 전환됨 (`setState`). 단, **노트(세션노트/싱어노트)는 가사/코드 연결 여부와 무관하게 항상 occurrence 자기 자신의 값만 사용** — `setNote`로 별도 분리, fork 안 시킴.
- `loadState()`가 linked occurrence를 열 때마다 캐노니컬의 **최신** 상태(세션 중 캐노니컬을 수정했어도)를 즉시 재계산해서 보여줌 — 드롭박스를 다시 누를 필요 없음 (`buildLinkedPreview`)
- 레거시 호환: 기존 `master.json`(occurrence 구분 없음)은 첫 occurrence가 자동으로 그 데이터를 쓰고(독립), 나머지 occurrence는 자동으로 "연결" 상태로 시작 — 마이그레이션 스크립트 불필요, 동적 폴백으로 처리

### 가사/코드 표시 버그 다수 수정
- **race condition**: `fetchLyricCache` 완료 전 첫 SSE 렌더가 빈 캐시로 fallback text를 그리고, 이후 `isPlaying=false`(정지)면 새 SSE 이벤트가 안 와서 영영 갱신 안 됨 → `lastKnownState` 저장 후 캐시 완료 시 재렌더링
- **2번째 슬라이드 미표시**: `realtimeBar()`가 `anchorMTC`(앱 시작 시점 고정) 기준이라 5초 후 `anchorBar`(섹션 시작)에 고정되던 버그 → `sectionEntryMTC`+`sectionEntryBar` 기준으로 재작성
- **슬라이드 탐색**: 섹션 occurrence 매칭 로직 제거, 곡 전체 슬라이드를 절대 bar 기준 flat 정렬 배열(`lyricSlides`)로 만들어 순서대로만 탐색 (`findCurrentEntry`/`findNextEntry`)
- **간주 코드 그리드**: `flex-wrap:wrap`이라 마디 많으면 2번째 줄로 넘어가 부모 `overflow:hidden`에 잘리던 버그 → `nowrap`+고정 최소너비+가로스크롤로 변경, `justify-content:center` 추가
- **ghost 토큰 높이 버그**: 글자 부분이 일반 공백이라 줄 높이 계산에서 collapse되어 코드 라벨이 아래로 밀리던 문제 → 줄바꿈 없는 공백(NBSP)으로 교체
- 가사 토큰 칸 높이 통일: 코드 있는 줄에서만 모든 토큰에 빈 칸(투명) 예약 (코드 없는 줄까지 높이 늘리면 다른 레이아웃 깨짐 주의)
- `IndicatorState`에 `singerNote`/`nextSingerNote` 필드 누락 + `StateEngine`이 존재하지 않는 `.note` 필드를 읽던 버그(에디터는 `sessionNote`에 저장) → 필드 추가 + `state.note = curData.sessionNote`로 수정

### 사전 스캔 기능 (실연 안정성 — v2, 진행 중)
> 플랜: `/Users/heehan/.claude/plans/pre-scan-schedule-cache.md`

- **목적**: 조명 콘솔의 타임코드 동기화와 같은 원리. AX(화면읽기)는 마커를 "한 번 읽어오는 용도"로만 쓰고, 실제 진행은 MTC(타임코드) 기반 결정론적 계산으로 전환해 라이브 중 AX 의존도를 최소화.
- **v1 실패**: "스캔 유효하면 AX 디바운스 생략"으로 구현했다가 **실연 테스트에서 카운터가 완전히 틀어지는 회귀** 발생, 즉시 롤백. 디바운스는 마커 위치 신뢰성이 아니라 AX 매 순간 읽기의 노이즈를 거르는 장치였음 — 혼동이 원인.
- **v2 설계**: `ScheduleStore.swift`(신규) — 마커+BPM+박자 변경 이벤트까지 스캔해 fingerprint로 검증. `StateEngine`에 `pinnedScheduleBar`/`pinnedScheduleMTC` 앵커를 세션당 1회만 고정(MTC 재생 시작 시), 이후 `onBeat()`에서 앵커+경과 MTC 시간으로 매번 현재 bar를 처음부터 재계산(드리프트 누적 없음) → `detectSectionIdx`로 섹션 즉시 확정. **기존 AX 디바운스 경로는 스캔 없거나 무효(마커/템포 변경)일 때 폴백으로 100% 그대로 보존** (onBeat의 else 분기).
- 메뉴바에 "사전 스캔" 체크리스트 항목 추가(초록=완료/주황=재스캔 필요/회색=안 함), 클릭 시 `LogicPoller.lastSnapshot`의 마커+BPM+박자를 스캔.
- **⚠️ 다음 컴퓨터에서 계속 디버깅 예정**: 스캔 기능에 에러 있음 — 현재까지는 빌드 성공 + 기본 동작 확인했지만 추가 에러 리포트 받는 중. 점프(seek) 직후 기존 디바운스 경로와 새 경로가 같은 `update(snapshot:)` 호출 내에서 잠깐 겹치는 부분 등 재검토 필요.

## 2026-06-29 작업 내역

### 밴드뷰 레이아웃 재설계
- `index.html`: `#main`(지금/다음 섹션)을 `flex:1`로 상단 지배, 아래에 현재가사 → 다음가사 → 진행바 → 타임라인 순 배치
- 지금/다음 섹션 가운데 세로 구분선(`#sec-divider-v`), 섹션-가사 사이 가로 구분선(`#sec-divider-h`) 추가
- 섹션명 폰트 크기 확대: 현재 `clamp(32px,7vw,64px)`, 다음 `clamp(24px,5.5vw,48px)`
- 카운트다운을 현재/다음 가사 사이에 소형으로 배치

### 슬라이드 표시 로직 전면 재설계
- `lyricSlides[songName]` — 곡 내 모든 슬라이드를 절대 bar 기준 flat 정렬 배열로 구성
- `findCurrentEntry(songName, barFloat)` — `absBar <= barFloat`인 마지막 슬라이드
- `findNextEntry(songName, barFloat)` — 그 바로 다음 슬라이드 (섹션명 동일 여부 무관)
- 기존 섹션 occurrence 매칭 로직 제거 → 단순 순서 기반으로 Verse1→Verse1→Interlude 정확히 동작

### Race condition 수정 (코드/가사 미표시)
- `fetchLyricCache` 완료 후 `lastKnownState`로 즉시 재렌더링
- 일시정지 상태(`isPlaying=false`)에서 SSE가 멈춰도 페이지 로드 시 코드·가사 정상 표시

### realtimeBar 버그 수정 (2번째 슬라이드 재생 중 미표시)
- 근본 원인: `realtimeBar()`가 `anchorMTC`(앱 시작 시점 고정) 기준 → 5초 후 `elapsed >= 5` 가드로 `anchorBar`(섹션 시작 bar)에 고정됨
- 수정: `sectionEntryMTC`(섹션 진입 시 MTC) + `sectionEntryBar`(섹션 시작 절대 bar) 기준으로 재작성 — 제한 없이 정확한 bar 계산

### 싱어뷰 "다음" 카드 슬라이드 기준으로 변경
- 기존: `nextSection` SSE 필드 기준 (다음 섹션 이름)
- 변경: `findNextEntry` — flat 배열 기준 바로 다음 슬라이드 (같은 섹션명 2번째 occurrence 포함)

---

### ⚠️ 미수정 버그 (다음 작업)
> 플랜: `/Users/heehan/.claude/plans/band-singer-fix-2026-06-29.md`

1. **간주 코드 일부만 표시**: `renderInstDisplay`의 `barCount` vs `instChords.length` 불일치, WebServer.swift 저장 시 빈 마디(`[]`) 누락 가능성
2. **노트 미표시 (밴드/싱어)**: 
   - 밴드뷰 JS가 `s.sessionNote`/`s.nextSessionNote`를 읽지만 `IndicatorState`에는 `note`/`nextNote`만 존재
   - 싱어뷰 JS가 `s.singerNote`를 읽지만 StateEngine이 `IndicatorState`에 `singerNote`를 채우지 않음
   - 수정: `Models.swift`에 `singerNote`/`nextSingerNote` 추가, StateEngine에서 채우기, index.html 필드명 수정
3. **밴드뷰 카운트다운 위치**: 현재 가사 사이 → 지금/다음 섹션 가운데로 이동 (index.html HTML/CSS 변경)

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
