# Indicator

## 2026-08-24 (2차) — `/chart` 리얼드럼 악보 커서와 스텝 점 위치 불일치 버그 수정

### 증상
리얼드럼 모드에서 다른 마디로 넘어가면(특히 박 수가 더 적은 마디로), 악보 위에 표시되는 편집 커서(점선)는 마디 끝(또는 그 너머)에 가 있는데, 그 아래 입력 스텝 점 표시는 다른(정확한) 위치를 가리키는 경우가 있었음. 사용자가 실제 화면 스크린샷으로 재현해줌.

### 원인
- `refreshStepDots()`는 점을 그리기 전에 항상 `clampCursor()`로 `cursorB`/`cursorK`를 **지금 선택된 마디 기준 유효 범위**로 보정.
- 반면 악보 위 커서 선을 그리는 `updateEditCursor()`는 이 보정 없이 곧장 `cursorPos()`(=`cursorB + cursorK/entryDiv`)를 계산에 썼음.
- 박 수가 더 많은 마디에서 커서를 옮긴 뒤(예: `cursorB=3`), 박 수가 더 적은 마디로 선택이 넘어가면(예: 3/4박 마디, 유효 범위 0~2) `cursorB`가 그 마디 기준으론 범위를 벗어난 값으로 남아있는 상태에서 `updateEditCursor()`가 먼저 그 값을 그대로 써버려 마디 밖(끝 너머)에 커서가 그려짐 — 그 직후 `refreshStepDots()`가 `cursorB`를 보정해버리므로(전역 변수라 이후 값은 맞음) 점은 정확한데 커서 선만 어긋난 상태로 남음.
- `refreshAll()` 안에서도 `renderScore()`(→내부에서 `updateEditCursor()` 호출, 보정 전)가 `refreshStepDots()`(보정 담당)보다 먼저 실행되는 순서라 이 케이스를 특히 잘 유발함.

### 1차 수정 (부분적)
`updateEditCursor()` 맨 앞에 `clampCursor()` 호출 추가 — cursorB/K가 범위를 벗어난 경우는 해결됐지만, **사용자가 실제 스크린샷으로 재확인해보니 값이 이미 유효 범위 안인데도 여전히 어긋나는 경우가 있었음** → 원인이 하나 더 있었음이 드러남.

### 2차 수정 (진짜 원인)
- `GEO`(마디를 그릴 때 쓰는 슬롯 폭·간격 등)는 파일 전체가 공유하는 **단일 가변 변수**. `paintAutoScore()`가 마디를 하나씩 그릴 때마다 그 마디의 박 수에 맞게 `GEO.SLOT_W`를 계속 덮어씀 — 특히 "앞줄로" 등으로 **줄마다 마디 수가 달라지면**(예: 1번째 줄 5마디, 2번째 줄 3마디) 줄마다 압축 비율(scale)도 달라짐.
- `updateEditCursor()`/`scheduleVisual()`(재생 중 커서)은 **전체 악보를 다 그린 뒤** 실행되므로, 그 시점의 `GEO`는 **가장 마지막에 그려진 마디**(보통 마지막 줄) 기준 값으로 남아있음 — 커서가 있는 마디가 다른 줄에 있으면 그 줄과 무관한 압축 비율로 위치를 계산해 어긋남. (라이브 재현: 1번째 줄 5마디로 압축된 상태에서 커서 위치 계산 시 기대 위치 62.5%인데 실제 79.4%로 그려짐 — 마지막 줄(3마디, 압축 없음)의 SLOT_W가 잘못 섞여 들어간 것.)
- 수정: `paintAutoScore()`의 캐시(`o.cache[mi]`)에 그 마디를 그릴 때 실제로 쓴 `slot`/`gap`/`pad`를 같이 저장. `updateEditCursor()`·`scheduleVisual()` 둘 다 공유 `GEO`/`xAtPos()` 대신 이 캐시된 마디별 값으로 직접 좌표 계산하도록 변경 — 이제 줄마다 압축 비율이 달라도 항상 그 마디 고유의 값을 씀.
- 같은 패턴을 쓰는 다른 자리(`scrollScoreTo`, `logicHighlight`)도 점검 — 둘 다 마디 전체 폭(`L.w`)만 쓰고 세부 슬롯 위치 계산은 안 해서 영향 없음, 수정 불필요.
- 라이브 재현으로 수정 전/후 비교 확인: 수정 전 커서 위치 오차 79.4%(기대 62.5%) → 수정 후 63.9%(오차는 의도된 여백 보정뿐, 사실상 일치).

---

## 2026-08-24 — `/chart` 변박 시 강제 줄바꿈 제거 + 마디 폭 고정(비례 폭 폐지)

### 박자표(변박)가 줄 중간에서 바뀌어도 더 이상 강제로 줄이 안 끊김
- 기존엔 `buildLineGroups`(줄바꿈 로직, `notation.js`)가 박자표가 바뀌는 지점마다 무조건 새 줄을 시작했음(우회 방법 없음). 사용자 요청으로 이 강제 규칙 제거 — 이제 변박도 그냥 기본 4마디 그리드에 자연스럽게 섞여 들어가고, 특정 지점에서 줄을 끊고 싶으면 기존 "줄바꿈" 버튼으로 직접 지정.
- 표기 정확성을 위해 줄 중간에 박자표가 바뀌는 지점엔 정식 표기법대로 작은 인라인 박자표를 그 마디 시작 위치에 새로 그리도록 추가(`drawInlineTs()`, notation.js·chart.html 양쪽에 동일하게 추가).
- **인쇄/PNG·PDF 내보내기 경로(`chart.html`의 별도 `paint()` fixed-perLine 함수)는 이번 변경에서 제외** — 그 경로는 줄 안의 모든 마디가 항상 같은 고정 폭(`GEO.MEASURE_W`)이라는 다른 설계라 변박마다 새 줄로 강제 시작하는 게 여전히 필요함(구조가 다름, 나중에 필요해지면 별도로 통일 검토).

### 마디 폭을 박 수 비례 → 항상 고정 폭으로 변경
- 후속 논의: "마디가 실제 비율(박 수)에 맞게 작아질 필요가 있나?"는 사용자 질문에서 시작 — 그리드 기반 앱 특성상 마디마다 폭이 들쭉날쭉하면 스캔하기 산만하고, 좁아진 마디는 입력 탭 영역도 같이 좁아져 불리하다는 데 합의.
- `notation.js`(`paint()`)·`chart.html`(`paintAutoScore()`) 둘 다: 마디 폭 계산을 `bc*4*SLOT_W+...`(박 수 비례) → 항상 기준 4박 마디 폭(`FIXED_MW`)으로 통일. 그 안의 노트 간격(`SLOT_W`)만 마디별로 `slotFor(bc)`로 조절해서 박 수가 몇이든 같은 폭을 꽉 채우도록(엑셀 셀 너비 통일 + 내용만 다른 것과 같은 방식). 라이브로 4/4·3/4 섞인 마디들 렌더링해 폭이 정확히 동일한지 좌표까지 검증 완료.
- 인쇄/내보내기 경로는 원래부터 고정 폭이었어서(그 경로만 줄당 강제 ts-분리가 남아있는 이유이기도 함) 이번 변경과 무관.

---

## 2026-08-22 — `/chart` 리핏 마디 기호 입력 기능 신설 + 데스크톱 창 레이아웃 채우기 버그 수정

### 리핏 마디(𝄎) 기호 — "바로 앞 마디와 똑같음" 표기
- 실제 드럼 표기법에서 "앞 마디를 그대로 반복"할 때 쓰는 기호(사선+점 2개, % 모양, SMuFL `repeat1Bar`와 같은 뜻)를 입력 기능으로 추가. Bravura 폰트 파일이 저장소에 없어 실제 외곽선 추출은 불가 — 기본 SVG 도형(선+원 2개)으로 동일한 모양 재현(`drawRepeatBarGlyph()`).
- **"반복(𝄎)" 버튼**(마디 복사 그룹, 단축키 **⌘D**) — 켜면 바로 앞 마디의 실제 음표 데이터를 통째로 복사해 넣고 `repeatPrev` 플래그만 얹는다. 재생·연습모드 등은 실제 복사된 데이터를 그대로 읽으므로 전혀 안 건드림 — 화면에만 음표 대신 기호가 그려짐(`drawMeasure`에서 분기). 줄바꿈 지정(`lineBreak`/`lineTarget`)은 복사 대상에서 제외(마디 "위치"에 속하는 값이라 내용 복사에 딸려오면 안 됨).
- 직접 편집(그리드 클릭·리얼드럼 패드 입력 둘 다)하면 자동으로 플래그가 풀리고 그 자리에서 바로 독립된 음표로 편집 계속 가능. 다시 누르면 플래그만 해제(내용 유지).
- `chart.html`의 자체 편집 렌더 엔진과 `notation.js`(`/drum` 뷰어 공유)에 동일한 그림 함수를 각각 추가 — 두 화면이 항상 같은 모양으로 보임. `normalizeMeasures()`에도 플래그 보존 추가(저장/로드 유지).

### 데스크톱/태블릿 폭 창에서 레이아웃이 창 높이에 안 맞던 버그 수정
- 증상: 창이 콘텐츠보다 작으면 스크롤이 필요하고, 크면 아래에 빈 검은 공간이 남음 — "예전엔 브라우저에 꽉 찼었는데" 리포트로 발견.
- 원인: 2026-08-15 세션에서 아이패드 좌우 2단 레이아웃(`applyEdition()`의 `ipad` 판정)을 의도적으로 껐는데(요청: 상/하 1단으로 통일), 그러면서 "창 높이에 맞춰 늘어나는" 성질(`body`를 `height:100dvh` flex column으로 고정)도 같이 없어졌었음 — 상/하 1단 자체는 유지하되 창 높이 채우기만 별도로 복구해야 했음.
- 수정: `body.edition-pad:not(.edition-ipad)`(아이패드 2단은 아니지만 데스크톱/태블릿 폭인 상태)에 아이패드 2단이 이미 쓰던 것과 같은 기법(`body`를 뷰포트 높이 flex column + `overflow:hidden`, `main`을 내부 스크롤 컨테이너로)을 좌우 분할 없이 그대로 적용. 폰 폭(좁은 화면)은 기존의 자연스러운 문서 스크롤 그대로 유지(2026-08-15 결정 유지). `initSafeTop()`의 스크롤 감지도 `window.scrollY`뿐 아니라 `main.scrollTop`까지 같이 보도록 수정(이 모드에선 문서가 아니라 main 안에서 스크롤되므로). 인쇄(`@media print`)에서는 이 flex+고정높이 기법이 다페이지 출력을 첫 페이지로 잘라버리므로, 기존 아이패드 2단과 동일하게 인쇄 시에는 되돌리는 예외 추가.
- 창 크기별로 라이브 검증 완료: 짧은 창(1000×560)→main 내부 스크롤만 생기고 문서 스크롤 없음, 큰 창(944×1306)→문서·main 둘 다 스크롤 없이 정확히 꽉 참.

---

## 2026-08-18 — 정지 상태 재생 위치 판정 근본 수정 + `/drum` 가사 표시 확대 + 메뉴·브랜딩 정리

### 정지(일시정지) 중 재생 헤드가 두 섹션 사이를 왔다갔다하던 버그 — 근본 원인 수정
- **원인**: `StateEngine.swift`의 `update()`/`currentSongMarker()`가 정지 상태에서 위치 판정 시, 화면에 표시되는 SMPTE 타임코드 문자열("01:05:54:18.63")을 매 250ms AX 폴링마다 다시 파싱(`parseMTC`)해서 썼음 — 로직 UI 리페인트 타이밍과 겹치면 파싱값이 미세하게 흔들려 감지되는 섹션이 왔다갔다했음. **재생 중(`mtcIsPlaying`)엔 이 문제가 전혀 없음** — 실제 MTC 신호(`mtcTime`) 기반이라 완전히 다른 코드 경로. 정지→재생 전환 시 `updateMTC()`의 `jumped` 리셋이 항상 무조건 발동해 정지 중 상태를 깨끗이 씻어내므로, 이 수정은 재생 중 로직과 구조적으로 격리되어 있음(if/else 상호배타 분기 + 재생 재개 시 강제 리셋, 이중으로 확인됨).
- **수정**: 정지 상태 판정을 문자열 타임코드 대신, AX로 안정적으로 읽히는 정수 마디 번호(`transportBar`)로 전환. 새 헬퍼 `markerBar()`(마커의 마디 번호, 반올림 — 마커는 늘 마디 경계라는 전제)·`detectSectionIdxByBar()` 추가. 마디 단위 판정으로 충분한 이유: 이 앱의 마커는 항상 마디 경계에 위치, `/drum`·`/singer` 하이라이트도 마디 단위만 표시하므로 박(beat) 이하 정밀도는 불필요.
- 이제 안 쓰는 `anchorBar`/`anchorMTC` 앵커 추정 메커니즘(기존 fallback)도 함께 제거.
- **참고**: 비슷하게 "정수 마디는 안정적, 문자열 타임코드는 불안정"이라는 원칙은 2026-08-17에 고친 `/drum` 캡션 조기표시 버그와도 같은 계열 — 로직 AX 읽기에서 타임코드 문자열 파싱이 필요한 경로는 항상 노이즈 가능성을 의심할 것.

### `/drum` 가사 캡션이 첫 줄만 보이던 문제 수정
- 원인: 저장 시점(`/edit` "뷰어 적용")에 `sectionPayload()`가 `lyricCue: plain.split('\n')[0]`로 **첫 줄만 잘라서** 저장하고 있었음 — `/api/sections`가 그 잘린 값을 그대로 내려보내던 구조.
- 수정: `WebServer.swift`의 `handleSections()`가 `d.lyricCue`(잘린 값) 대신 `d.slides.first`의 토큰을 직접 평문으로 변환(`plainText(from:)` 신규, `br`→개행)해서 첫 슬라이드 **전체**를 보내도록 변경. `drum.html`의 캡션 CSS도 한 줄 말줄임(`nowrap`+`ellipsis`) → 여러 줄 표시(`white-space:pre-line`, `flex-direction:column`)로 변경, `.line svg`의 `margin-top`도 2줄 캡션이 들어갈 공간(56px)으로 확대.

### 메뉴·브랜딩 정리
- 상태바 메뉴: "가사·노트 편집 열기" → **"콘텐츠 편집 열기"**(가사·노트뿐 아니라 곡별 드럼 채보 업로드까지 다루는 화면이라), "채보 편집 열기" → **"드럼 스코어 편집 열기"**(`/drum` 뷰어와 이름 짝 맞춤, "채보"라는 낯선 단어 제거).
- **"설정..." 메뉴 항목 삭제**: `SettingsView.swift`가 실제 설정 기능 없이 "카운트다운은 이제 곡별로 설정해요"라는 안내문만 띄우는 죽은 화면이었음(예전 전역 설정 방식이 곡별 설정으로 옮겨가며 남은 리다이렉트 안내) — `openSettings()`/`settingsWindow`/`SettingsView.swift` 전부 삭제. `IndicatorApp.swift`의 SwiftUI `Settings{}` 씬도 확인해보니 이 앱이 `LSUIElement=YES`(Dock 아이콘·표준 메뉴 없음)라 애초에 열릴 경로가 없는 죽은 코드였음 — `EmptyView()`로 대체(SwiftUI `App` 프로토콜상 Scene은 최소 하나 필요해 완전 제거는 불가).
- `chart.html` 전체의 "Mai Drum"/"Mai Drum Studio" 브랜딩(포크 초기 이름, 탭 제목·정보 팝업·버전 문자열·파일형식 안내 메시지 등 5곳)을 **"드럼 스코어"/"드럼 스코어 스튜디오"**(아이패드 모드)로 통일.

---

## 2026-08-17 — `/drum` 라이브 뷰어 신설 완료 + 줄바꿈 수동 배치 재설계 + 버그 다수 수정

### `/drum` 라이브 드럼 뷰어 신설 (이전 세션에서 시작, 이번 세션에 완성·검증)
- `Models.swift`/`StateEngine.swift`: `IndicatorState.barPosition`(로직 실제 템포맵 기준 절대 마디 위치) 추가 — 마커 유무와 무관하게 항상 계산(과거 같은 함정 반복 방지 위치에 배치).
- `WebServer.swift`: `/api/sections`에 `barPosition`·`lyricCue`·`occurrenceIndex` 추가. `/drum` 라우트, `/api/drumChart`(GET)·`/save-drum-chart`(POST) 신설. `DrumChartStore.swift` 신규(LyricsStore와 동일하게 **인메모리 전용, 디스크 저장 없음** — 앱 재시작하면 업로드했던 채보가 사라짐, 재현 필요하면 매번 `/edit`에서 재업로드해야 함).
- `Resources/drum.html` 신규: `/edit`에 업로드된 `.mai.json`을 곡별로 자동 추적해 현재 재생 중인 곡의 채보를 실시간(SSE `/events`)으로 하이라이트하며 보여주는 읽기 전용 뷰어. 채보 1마디 = 그 곡 `#Song` 마커 시작 마디로 고정 매핑(별도 오프셋 입력 불필요).
- `Resources/notation.js` 신규: `chart.html`과 `drum.html`이 공유하는 렌더링 엔진(`paint`, `buildLineGroups` 등)을 IIFE로 분리해 `window.Notation`으로 노출 — 코드 중복 제거, 두 화면이 항상 같은 결과를 그림.

### ⚠️ `/drum`에서 발견·수정한 버그 3종
1. **화면이 전혀 안 그려지던 치명적 버그**: `drum.html`에서 `curSongName`/`loadingSong`/`measures`/`startBarPos`/`lineGroups`/`sectionLineMeta`가 전부 **선언 없이** 쓰이고 있어서, 첫 SSE 메시지가 도착해 `curSongName`을 읽으려는 순간 `ReferenceError`가 나며 매번 화면 갱신이 통째로 멈췄음(콘솔 에러로 확인 전까지는 "권한 문제"·"채보 없음" 등으로 오인하기 쉬움 — 비슷한 증상 재발 시 콘솔 에러부터 확인할 것). 상단에 `let` 선언 추가로 수정.
2. **섹션명·가사 캡션이 항상 정확히 한 마디 일찍 표시되던 버그**: `mi = Math.floor(o.barPosition - startBarPos)` 계산에서 `floor`가 한 마디 전으로 잘못 내림됨. 처음엔 순수 부동소수점 오차(1e-10 수준)로 추정해 `+1e-6` 보정을 넣었으나 재현됨 — `/api/sections` 실측 결과 `barPosition`이 정수 마디 경계보다 최대 **0.003(1e-3 수준)** 못 미치게 나오는 걸 확인(예: `2.9993`, `10.9997`, `26.9974`...), 로직 마커 타임코드 자체가 프레임 단위로 양자화되며 생기는 실제 오차였고 1e-6으론 1000배 부족했음. 보정값을 `+0.02`로 키워 최종 해결(캡션 계산에만 적용, 라이브 하이라이트는 매 틱 연속 재계산이라 이 문제와 무관해 그대로 둠). **비슷한 "정수 경계에서 아주 살짝 어긋나는" 버그를 마주치면 float epsilon(1e-6)이 아니라 실제 값을 찍어보고 오차 크기부터 확인할 것 — 로직 마커/타임코드 기반 계산은 1e-3 수준 오차가 정상 범위.**
3. **캡션이 줄 맨 앞에 고정 표시돼 실제보다 최대 3마디까지 일찍 보이던 문제**: 섹션이 줄 중간에서 시작해도 캡션은 항상 그 줄의 맨 앞(`.cap` 고정 위치)에 붙어 있었음. `renderLines()`를 `paint()`로 `posCache` 채운 뒤 그 섹션이 실제 시작하는 마디의 `x0` 좌표를 읽어 `.cap`을 `position:absolute`로 그 위치에 정확히 앉히도록 재작성(`g.metaMi`로 실제 마디 인덱스 추적). 섹션명·가사 폰트도 12px/11px → 16px/15px로 확대.
- **macOS 손쉬운 사용 권한 반복 초기화**: `dev-run.sh`가 재빌드마다 `tccutil reset Accessibility`를 실행(서명이 매번 바뀌어 권한이 무효화되므로) → 재빌드 후엔 항상 시스템 설정에서 Indicator 권한을 다시 켜고 로직을 재생시켜야 `/drum`이 데이터를 받음. 이 두 가지(권한 초기화 + 인메모리 채보 유실)가 겹쳐서 "재빌드 직후엔 뷰어가 계속 안 보인다"처럼 느껴지기 쉬움 — 디버깅 시 항상 함께 점검할 것.

### `/chart` 줄바꿈 수동 배치 3종 버튼 전면 재설계 ("이름표 방식" → "일회성 재배열")
사용자 피드백: 기존 "8마디로 배치"가 `lineTarget` 값을 마디에 지속적으로 붙여두는 "이름표(정체성)" 방식이라, 서로 다른 곳에서 각각 8마디 지정한 두 구간이 우연히 인접하면 하나로 합쳐지는 등 예측 못한 부작용이 있었음. 전부 **일회성 재배열**(그 순간 배열만 바꾸고 지속되는 태그를 남기지 않음) 개념으로 통일:
- **뒷줄로**: 선택 구간을 현재 줄에서 떼어 **바로 다음 줄에만** 편입(그 줄만 커짐), 그 이후 줄은 전혀 안 움직임(비-캐스케이드). "줄바꿈"(중간에서 단순 절단)과는 명확히 다른 별개 동작으로 분리(기존엔 둘이 같은 함수를 썼음).
- **앞줄로**: 기존과 동일하게 유지 — 선택 구간을 앞줄에 합치고 그 뒤 전체가 4마디 그리드로 캐스케이드 재정렬(사용자가 이전에 명시적으로 확정한 동작).
- **4마디로 배치 / 8마디로 배치**: `lineTarget` 이름표 부여 방식 폐기 → 선택 구간 앞뒤에 강제 줄바꿈을 꽂고, 8마디처럼 기본(4) 그리드보다 큰 단위는 중간의 자연스러운 4마디 정지점들을 "앞줄로"와 같은 억제(`lineBreak=false`) 메커니즘으로 이어붙이는 방식(`arrangeInLine(a,b,n)` 공용 함수)으로 재구현. 선택 구간 밖은 전혀 안 건드리고, 자투리는 항상 구간 끝에 남음.
- **줄바꿈 초기화** 버튼 신규: 모든 마디의 `lineBreak`/`lineTarget`을 지우고 순수 기본 4마디 그리드로 되돌림. 사용자가 예전 알고리즘으로 테스트하며 남은 낡은 데이터로 의심되는 "저절로 생긴 짧은 줄" 문제의 해결책으로 추가.
- `notation.js`의 `buildLineGroups` 아일랜드 판정을 `lineTarget===4||===8` 고정값 → `typeof===number&&>0` 임의값으로 일반화(뒷줄로가 동적 크기의 섬을 만들 수 있어야 해서). `normalizeMeasures`(저장/로드)도 `lineBreak===false`가 그동안 저장 안 되고 유실되던 잠재 버그를 같이 수정(4/8/앞줄로가 재로드 후에도 정상 유지되도록).
- 모든 시나리오 Claude Browser로 실제 앱 버튼 클릭까지 라이브 검증 완료(수치까지 일치 확인).

### 가사 편집(`/edit` "뷰어 적용") 자동 반영 조사 — 진행 중, 결론 못 냄
사용자가 "가사 수정 후 뷰어 적용을 눌러도 뷰어에서 새로고침해야만 반영되는지" 질문 → 코드 추적 결과 서버(`handleSave`)는 저장 성공 시 `event: lyrics-updated` SSE를 보내고, `singer.html`도 이 이벤트를 구독해 `fetchLyricCache()`를 재호출하도록 이미 배선되어 있음(설계상 새로고침 불필요해야 함). 실제 재현 테스트를 시작했으나 사용자가 중단시켜 **결론 안 남** — 다음에 이어서 확인 필요.

---

## 2026-08-16 — 채보(/chart) 리얼드럼 입력 단위를 "마디 속성"에서 "입력 모드"로 재설계

### 배경
8비트/16비트 버튼이 지금까지는 **선택한 마디의 실제 저장 방식(div)을 즉시 바꾸는** 동작이었음 —
16비트로 저장된 마디에서 8비트를 누르면 정말로 그 마디 데이터가 바뀌고, 안 맞는 위치의 노트는
지워지기도 했음. 사용자 요청: 이건 "지금부터 내가 무슨 단위로 찍을지"를 정하는 **입력 모드**여야
하고, 마디 데이터 자체는 건드리지 않아야 함.

### 변경 (chart.html)
- `entryDiv`(입력 모드, 1=4비트/2=8비트/4=16비트)와 마디의 실제 저장 div를 완전히 분리.
  - `cursorDiv()` → 저장값이 아니라 `entryDiv`를 그대로 반환. `cursorK`는 이제 항상 "입력 모드
    기준 몇 번째 칸"이라는 뜻.
  - `cursorIdx(voice)` → `entryDiv` 기준 커서 위치를 **실제 저장 칸 수에 비례 매핑**해서 읽는다
    (발 악기를 손 격자에 비례 매핑하던 기존 패턴을 손·발 공통으로 확장).
  - `padHit()`의 실제 입력(쓰기) 순간에만 `entryDiv > 그 박의 저장 div`면 `setDiv()`로 **무손실
    확장**(기존에 이미 배수 관계는 무손실 확장하도록 되어 있었음, 그 인프라를 재사용) — 마디
    전체가 아니라 **그 박 하나만**, **실제로 찍을 때만** 확장됨.
  - `refreshStepDots()` — 표시하는 점 칸도 저장 칸이 아니라 `entryDiv` 기준으로 그림
    (`hasNoteAtStep()` 헬퍼로 비례 매핑해서 있는지 판정).
  - `setEntryDiv()` — 이제 `entryDiv = d` 한 줄과 UI 갱신뿐, `setDiv()` 호출도 `commit()`도 없음
    (데이터 변경이 아니므로).
  - `defaultDiv()` — 새 마디 저장 칸 수는 `Math.max(2, entryDiv)`로 바닥을 잡음(4비트=1이어도
    저장까지 1칸으로 줄이지 않음 — "박 머리만 짚는다"는 뜻이지 "1칸만 저장한다"는 뜻은 아님).
- **4비트 모드 추가**(박 머리만 짚음, 저장엔 영향 없음). 버튼 3개(4/8/16비트) 모두 `entryDiv` 값만
  그대로 비교해서 켜짐 표시 — 예전엔 "마디 안에 8/16이 섞여 있으면 판정 불가" 같은 복잡한 로직이
  있었는데, 분리 후엔 필요 없어져서 삭제됨.
- 단축키: `4`→4비트, `8`→8비트, `8`을 350ms 안에 두 번→16비트(더블탭 판정, `last8PressAt`).
- ⚠️ **Shift+1/2 마디 이동이 원래 안 되던 진짜 버그를 발견·수정**: `e.key`는 Shift가 눌리면 물리
  키 그대로가 아니라 바뀐 문자(예: Shift+2 → `"@"`)로 오기 때문에, 기존의 `e.key==='2'` 체크가
  Shift와 같이 눌렸을 때 전혀 안 잡혔음. `e.code==='Digit2'`(물리 키, Shift 여부와 무관)를 같이
  검사하도록 수정. 비슷한 패턴(문자 키를 Shift와 함께 검사)이 다른 곳에도 있으면 같은 함정이
  있을 수 있음 — 필요시 `e.code` 병행 확인할 것.

### 검증
자동화 브라우저 테스트로 전부 확인: 4비트 모드에서 입력해도 저장 div 불변, 16비트 모드에서
8비트로 저장된 박에 입력하면 기존 노트 보존한 채 div만 4로 확장, 단축키 4/8/8더블탭 각각
entryDiv 1/2/4로 정확히 전환, Shift+Digit2/Digit1(시뮬레이션)으로 마디 이동 확인.

---

## 2026-08-15 — 채보(/chart) UI 전면 재배치 + 로직 재생 동기화(마디 하이라이트) 신설

### UI 재배치 (chart.html, 사용자가 직접 채보하는 워크플로에 맞춰 정리)
- 화면을 **상(악보)/하(입력단)** 1단 레이아웃으로 통일 — 기존 좌우 2단("iPad 가로") 모드는 꺼버림
  (`applyEdition()`의 `ipad` 판정을 항상 false로). 악보 영역 높이도 46%→64%로 키움.
- 리얼드럼 탭: 드럼 패드 박스를 실제 패드 크기만큼만 차지하도록 축소·고정폭화하고 왼쪽으로 배치,
  오른쪽 빈 공간에 **표기 → 입력 단위(8비트/16비트) → 찍은 뒤(자동 이동) → 로직 동기화** 순서로
  위계를 지켜 세로 배치. ⚠️ 표기·8비트16비트 버튼이 리얼드럼 전용 영역으로 옮겨가면서
  **그리드 탭에서는 더 이상 이 두 기능에 접근할 수 없음** — 다음에 필요하면 공용 위치로 되돌리거나
  중복 배치할 것.
- 마디 추가 도구 재설계: "+마디"(무조건 뒤에 추가) → **박자표 셀렉트 + 앞에추가/적용/뒤에추가** 3버튼
  조합으로. 셀렉트는 더 이상 선택 마디를 즉시 바꾸지 않음(적용을 눌러야 반영) — 변박 마디를 미리
  골라보다 실수로 원래 마디가 바뀌는 사고 방지. "적용" 버튼은 복제·복사·붙여넣기와 같은 필 안에서
  둥근 알약 윤곽(같은 색, 여백만 곡선)으로 살짝 부풀어 보이도록 스타일링.
- 8비트/16비트 변환 시 데이터 손실 최소화: `setDiv()`가 배수 관계(2↔4, 3↔6 등)면 자리를 그대로
  옮겨 심어 무손실 처리, 배수 아니면 기존처럼 손실 처리.
- 프리셋 드롭다운·24/32마디 버튼·곡 목록 버튼·연습(Practice) 탭·녹음 기능·안내 문구 전부 숨김/제거
  (팀 내부 전용 + JSON 파일로 직접 백업하는 방식으로 워크플로 확정).
- 단축키: ⌘Backspace(선택 마디 전체 삭제), ⌘C/⌘V(마디 복사/붙여넣기, 입력창 포커스 시 예외),
  ⌘Z는 이미 있었음(재확인). Enter(악보 맨 처음으로), 방향키/1·2(스텝 이동, 마디 경계에서 멈춤),
  Shift+방향키(마디 경계 무시하고 바로 옆 마디로 점프), ↑/↓(그 마디 첫 칸/마지막 칸).
- 악보 드래그 시 텍스트 선택 방지(`user-select:none`)를 악보 영역만이 아니라 `body` 전체로 확장.
- 리얼드럼 재생 커서가 쉼표(빈 칸)를 건너뛰던 버그 수정 — `measureEvents()`가 소리 나는 칸만 예약하던
  걸 모든 칸을 예약하도록 바꿈(소리는 여전히 값 있는 칸에서만 남).

### 로직 재생 위치 → 채보 마디 동기화 (신규)
목적: 로직 클릭트랙에 레퍼런스 음원을 올려두고 들으면서 채보할 때, 지금 로직이 곡의 어느 마디를
지나는지 악보에서 바로 보여줌(사운드는 안 냄, 시각 표시만).

- `Models.swift`: `IndicatorState`에 `mtcSeconds`(로직 트랜스포트 원시 위치, 초) 필드 추가.
- `StateEngine.swift`: `compute()`에서 `isPlaying`/`mtcSeconds`를 마커 유무와 무관하게 **함수 맨 위에서**
  채우도록 함 — ⚠️ **처음엔 기존 코드 흐름 따라 아래쪽(마커 있을 때만 실행되는 구간)에 넣었다가 실제
  버그로 이어짐**: 채보(/chart)는 가사 마커를 안 쓰므로 `guard !markers.isEmpty else { return state }`에
  걸려 이 값들이 영원히 0/false로만 나갔음. **정지 상태에서 기준점을 잡을 수 있도록** `mtcIsPlaying`이면
  MTC 원시값을, 아니면 AX 타임코드 표시값(`snapshot.transportMTC`, 정지 중에도 갱신됨)을 씀 — 단, 이
  AX 폴백은 아직 실사용 확인 전(아래 미해결 참고).
- `chart.html`: `/events` SSE(index.html/singer.html과 동일)를 구독해 로직 위치를 받고,
  `mtcToChartPos()`로 이 채보의 마디/박(그 박의 입력 격자에 스냅, 계단식 이동)으로 환산.
  ⚠️ **두 번째로 찾은 실제 버그**: 처음엔 `requestAnimationFrame`으로 매 프레임 갱신했는데, 이 창이
  포커스를 잃으면(로직 창을 조작하느라 딴 데를 보는, 바로 이 기능이 필요한 그 상황) 브라우저가
  rAF를 아예 멈춰버려서 "안 움직이는 것처럼" 보였음. `setInterval(…, 100)`로 교체해 백그라운드에서도
  계속 돌게 함.
  - "여기를 1마디로" 버튼(리얼드럼 탭, 로직 동기화 섹션): 누른 순간의 로직 위치를 이 채보의 1마디
    기준점(`logicOffsetSec`)으로 저장 — 곡 처음이 아니라 중간 마커부터 재생하는 경우가 많아서 필요.
    세션 메모리에만 있음(새로고침하면 초기화, 영구 저장 아님).
  - 표시 방식: 가는 세로 커서선 대신, **지금 마디 전체를 옅게 깔아주는 사각형**(민트색, `#logicHighlight`,
    `renderScore()`가 SVG를 다시 그릴 때마다 같이 사라지므로 매 틱마다 없으면 재생성)으로 바꿈 —
    선이 계속 움직이는 게 산만하다는 피드백 반영.
  - 채보 자체의 ▶ 재생(`playing`)이 켜져 있으면 로직 동기화 쪽은 잠시 멈춤(우선순위: 채보 자체 재생 > 로직 따라가기).

### 미해결
- **정지 상태에서 "여기를 1마디로"가 잘 안 잡히는 문제** — 사용자 확인 결과 손쉬운 사용 권한은
  켜져 있는데도(메뉴바 초록불) `indicator_debug.txt`에 `[AX]` 로그가 한 줄도 안 찍힘 → LogicPoller의
  AX 스냅샷 폴링(`update(snapshot:)`)이 아예 안 돌고 있다는 뜻. `LogicPoller.swift:139`의
  `guard !mtcActive else { return }`(재생 중엔 AX 스킵, MIDI Stop 또는 무신호 2초 후 자동 해제되는
  구조) 쪽은 원인이 아닐 가능성이 높음(설계상 2초 안에 풀림). 권한 팝업을 실제로 허용했는지, 아니면
  다른 이유로 폴링 타이머 자체가 안 도는지 다음에 `debugLog`를 LogicPoller의 타이머 콜백 진입 지점에
  더 넣어서 확인 필요. 사용자가 "일단 이렇게 두자"고 해서 보류.
- `/edit`에 `.mai.json` 채보 파일 연결하는 기능 — 아직 시작 안 함(2026-08-14 계획 그대로 유효).
- `/drum` 라이브 뷰어(2단 컨베이어벨트) — 아직 시작 안 함. 사용자가 "채보 플로우부터 완성하고
  그 다음에 뷰어"라고 순서를 확정함(2026-08-15).
- 그리드 탭에 표기·8비트/16비트 재노출 여부 — 사용자에게 물어본 상태에서 다음으로 넘어감.

---

## 2026-08-14 — 드럼 채보 기능(/chart) 신설, 다음 단계는 /drum 뷰어

### 지금까지 한 것
- 친구가 만든 드럼 채보 웹앱(Mai Drum, 별도 사이트)을 **본인 허락받고** 소스 통째로 가져와
  `Indicator/Indicator/Resources/chart.html`로 편입. `/chart` 라우트, 메뉴 "채보 편집 열기" 추가.
  절대 원본 사이트(maidrum.com)는 안 건드림 — 우리 사본만 수정.
- 우리 쪽 수정: 타이틀/피드백바 제거(라이선스 고지 '정보' 버튼만 유지), **박자표(6/8·3/4 등 + 곡 중간
  변박) 지원 추가**(원래 데이터엔 `ts` 필드가 있었지만 UI·로직이 없었음 — 새로 만듦), 잠겨있던
  넓은 화면 "Studio" 레이아웃(`PUBLIC_STUDIO`) 항상 켜기.
- ⚠️ 찾아서 고친 진짜 중요한 버그: 불러오기(`normalizeMeasures`)가 박자표를 무조건 4/4로
  리셋시켜서, 저장했다 다시 열면 변박 마디가 사라지는 데이터 손실 버그였음. 고침.

### 아직 안 한 것 (다음 단계)
1. **`/edit`에 악보 가져오기**: 채보 앱에서 만든 `.mai.json` 파일을 가사 편집 화면에서 곡에 연결하는
   기능. 곡 매칭은 자동(제목 문자열 비교) 말고 **드롭다운으로 사람이 직접 지정**. 편곡 변경(마디 수
   불일치) 경고도 가사 쪽 패턴 재사용. **악보 데이터도 "전체 내보내기/가져오기" 백업 파일에 같이
   실리도록** — 안 그러면 가사처럼 재시작 때마다 날아감.
2. **`/drum` 뷰어 신설**: 싱어/밴드뷰처럼. 화면을 상/하 두 단으로 나눠 한 단에 4마디씩, **섹션(마커)
   경계를 절대 넘지 않고** 그 안에서 4마디씩 묶음(마지막 그룹은 모자라도 됨). 재생 중인 그룹 하이라이트,
   그 줄이 끝나 하이라이트가 다른 줄로 넘어가는 순간 방금 끝난 줄이 "그 다음다음 그룹"으로 미리 갱신
   (한 발 앞서 계속 채워지는 방식 — 페이지 넘길 때 안 끊기게). 마디 위치는 사람이 안 찍어도 됨 —
   Logic 템포맵으로 이미 정확한 실시간 위치를 알고 있으므로 자동 동기화.
3. 랜딩 화면(`/`, 지금 싱어·밴드 버튼 있는 곳)에 "드럼" 버튼 추가.
4. (선택) 마이드럼에 이미 그려둔 기존 곡들 — 브라우저 콘솔 추출 스크립트로 뽑아서 새 버전으로 이전.

### 참고
- 채보 JSON 구조: `{v:2, title, bpm, measures:[{ts:[num,den], div:[...], crash/hihat/ride/tom1/tom2/snare/ftom/kick:[16칸 배열]}]}`
- 마디당 칸 수는 `ts[0] * 8/ts[1]` (분모 4=박당 2칸, 분모 8=박당 1칸) — 인디케이터 본체의 겹박자
  타이밍 수정(`notatedBeatDuration`)과 동일한 원리.

---

## 다음 작업 계획: 슬라이드 전환을 MTC 시간 기반 "찍기"로 전면 개편 (2026-07-16 확정)

### 작업 재개 시 Claude에게 할 말
"슬라이드 찍기 작업 이어서 하자. CLAUDE.md의 슬라이드 계획 섹션 읽어봐."

### 배경 / 왜 바꾸나
- 현재: 슬라이드 전환 위치를 **마디 단위**(`LyricSlide.startBar`, 섹션 내 분할)로 입력 → 사용자가 마디를 계산해서 가사를 나눠야 해서 어려움.
- 검토했다 폐기한 안: Logic 미디 트랙 노트로 슬라이드 넘기기 (곡마다 미디를 다시 찍어야 하고 재사용 불가 → 폐기).
- **확정안**: 전환 시점을 **순수 시간(MTC 초)** 으로 저장. 사용자가 Logic 클릭트랙을 재생하면서 편집 화면에서 원하는 순간에 "전환 버튼"을 탭 → 그 순간이 기록됨. 마디/비트 어떤 단위에도 스냅하지 않음 (탭한 순간 그 자체가 정답).
- 가사 데이터에 같이 저장되므로 같은 곡을 다음 예배에서 또 할 때 타이밍 재사용 가능.

### 데이터 모델 변경
- `LyricSlide.startBar`(Int, 마디) → **`startSec`(Double, 초)** 로 교체: **자기 섹션 마커 시작 기준 오프셋**.
  - 섹션 첫 슬라이드는 항상 0 (마커 진입과 동시에 표시). 슬라이드 N개 = 전환 신호 N−1개.
  - 곡 마커 기준이 아니라 **섹션 마커 기준**인 이유: 앞쪽 편곡이 바뀌어도 뒤 섹션들의 타이밍이 살아남음.
- `LyricSlide`에 **`sessionNote` 추가** (singerNote는 이미 슬라이드 필드에 있음).
  - 세션/싱어 노트는 **마커(섹션) 기반 → 슬라이드 기반으로 전환**. 섹션 헤더의 노트 입력칸을 슬라이드 카드 안으로 이동.
  - 기존 섹션 노트(`SectionData.sessionNote/singerNote`)는 그 섹션 **첫 슬라이드로 자동 이전** (마이그레이션).
- **기존 저장본(마디 기반) 호환**: 로드 시 `startSec` 없고 `startBar` 있으면 스캔된 섹션 길이로 `startBar/totalBars × 섹션길이(초)` 환산해 초기값 생성.
- 편곡 변경 감지: 기존 `totalBars` 저장·경고 유지 (+ 섹션 길이(초)도 저장해두면 더 정확 — 구현 시 판단).

### 뷰어 (index.html 밴드 / singer.html 싱어)
- `IndicatorState`에 **`sectionElapsedSec`**(섹션 진입 후 경과 초) 추가 (StateEngine: `mtcTime - sectionEntryMTC`).
- 슬라이드 선택 로직: `barFloat` 비교 → **초 비교**(`startSec <= sectionElapsedSec`)로 교체 (`findCurrentEntry`/`findNextEntry` 및 관련 함수).
- **조기 전환(slideEarlyEighths) 설정·로직 완전 제거** (StateEngine의 dispAdvanced/earlySec 래치 포함). 찍은 시각 자체가 정답이므로 불필요.
- 노트 표시: 섹션 단위(state.note/singerNote) → **현재/다음 슬라이드의 노트**로 교체.
- 유지: 카운트다운(마커 전환 기준 — 슬라이드와 무관), 진행률, 곡휠, 섹션휠, 간주 그리드, 코드 표시, 곡명(다음 곡) 표시.

### 가사 편집 화면 (/edit, WebServer.swift 내장 JS) — 세로 타임라인 UI
- 기존 **마디 그리드(bar-tl)·구분선 클릭/◀▶ 이동 제거** → 섹션마다 **세로 타임라인**:
  - 슬라이드들이 시간 비례 높이 블록으로 세로로 쌓임. 블록 사이 경계에 **전환 아이콘(핸들)**.
  - 재생 중 **재생헤드 라인**이 실시간 표시(SSE `sectionElapsedSec` + broadcastTimestampMs로 클라이언트 보간), 현재 표시 중인 슬라이드 블록 강조.
  - **찍기**: 재생 중 전환 버튼(화면 버튼 + 스페이스바) 탭 → 그 순간이 "현재 슬라이드→다음 슬라이드" 경계로 기록, 아이콘 생성. 곡을 들으며 순서대로 탭탭탭. 중간부터 재생해 다시 탭하면 해당 경계만 갱신 (재찍기).
  - **드래그 조절**: 아이콘을 위(일찍)/아래(늦게)로 드래그. 이웃 경계 넘지 못하게 제한. 앞뒤 블록 높이 변화로 간격을 눈으로 감 잡는 방식. 보정 오프셋 없음 (사용자 확정).
  - 아직 안 찍은 경계: 섹션 길이 균등 분할 위치에 **반투명 아이콘**으로 표시 (임시값임을 시각적으로 구분).
- 가사/코드/간주 입력 카드 UI는 유지. 슬라이드 추가/삭제 버튼으로 장수 조절 (마디 계산 없이 장수만 정하고 가사 입력).
- **재생 따라가기 토글**: 편집 화면이 SSE 구독 → 재생 위치가 다른 곡으로 넘어가면 자동 곡 전환 + 연주 중 섹션 하이라이트/스크롤. 사용자가 화면 조작 시 일시 해제.
- **복사 기능**: 가사·코드와 함께 **전환 타이밍(초)도 복사** (사용자 확정: "일단 복사하고 필요시 수정"). 섹션 길이가 다르면 비례 환산.
- 유지: 트랜스포즈, HTML 내보내기/가져오기(팀 공유), 드래그앤드롭 가져오기 — slides에 startSec 포함해서 그대로.

### 삭제 대상
- `SettingsStore.slideEarlyEighths` + SettingsView 해당 행
- StateEngine의 조기 전환 래치 (`dispAdvanced`, `earlySec`, dispIdx/dispBounds 분기)
- 편집 화면 마디 그리드 렌더링(`renderBarTl`)과 splits 기반 분할 로직 (splits 개념 자체가 startSec 배열로 대체됨)

### 확정된 사용자 결정 사항
1. 전환 시점 = 탭한 순간의 MTC 그대로, 어떤 단위에도 스냅 안 함. 반응속도 보정 오프셋 **없음**.
2. 조절 UI = 타임라인 아이콘 드래그 (또는 그냥 다시 찍기). 단위 이동 버튼 없음.
3. 카운트다운은 마커 전환 기준 유지 (슬라이드 아님).
4. 세션/싱어 노트는 슬라이드 귀속으로 변경.
5. 같은 이름 섹션 복사 시 타이밍도 같이 복사.
6. 롤백 지점: `pre-midi-slide` 태그 (= 118b4e0, 이 계획 착수 직전 안정 버전, 릴리즈 적용됨).

### 구현 순서 제안
1. Models: `startSec`/`sessionNote` 추가 (+startBar 하위호환 디코딩) → 2. StateEngine: `sectionElapsedSec` 추가, 조기 전환 제거 → 3. 뷰어 2개: 초 기반 슬라이드 선택 + 슬라이드 노트 → 4. 편집 화면: 타임라인 UI·찍기·드래그·따라가기 (가장 큰 작업) → 5. 복사/내보내기/가져오기 경로 startSec 반영 → 6. 마이그레이션(마디→초 환산, 섹션 노트→첫 슬라이드) → 7. 빌드·실사용 검증 후 릴리즈.

### 진행 상황 (2026-07-16, 2차 — 마커/슬라이드 트랙 분리 + 곡 단위 연속 타임라인)
- **사용자 피드백 반영**: 슬라이드는 마커와 무관하게 원하는 타이밍에 넘어가야 함 → 편집 화면을 "곡 하나 = 끊기지 않는 세로 타임라인"으로 재설계. 마커(섹션 경계)는 눈금(`.tl-marker`, 고정 — Logic이 결정)으로, 슬라이드는 색 블록(`.tl-slide`)으로 **트랙을 시각적으로 분리**하되 같은 시간축 위에 표시. 섹션 첫 슬라이드도 이제 `startSec` 오프셋을 가짐(0=마커와 동시, 음수=마커보다 먼저) — 유일한 제약은 "이전 섹션 마지막 슬라이드보다 늦어야 함"(순서 고정).
- **용어 변경**: "전환 찍기" → **"여기서 넘김"**, 키를 스페이스바 → **Enter**로 변경.
- 서버(WebServer.swift)에 섹션의 **`startInSong`**(곡 시작 마커 기준 절대 초) 추가 — 편집 화면이 섹션을 넘나드는 연속 타임라인을 그리는 데 사용.
- 편집 화면 핵심 함수: `songSlideList(song)`(곡 전체 슬라이드를 곡 내 절대 초로 펼쳐 정렬) → `renderSongTimeline`(마커 눈금 + 슬라이드 블록 + 드래그 핸들 렌더) → `attachHandleDrag`/`tap()`은 이제 섹션 인덱스가 아니라 **곡 전체 리스트 인덱스(g)** 기준으로 동작.
- 1~6단계 전부 구현 완료, **빌드 성공, /Applications에 설치됨** (문제 생기면 `git checkout pre-midi-slide` 후 재빌드).
- **검증 완료** (JS 콘솔 시뮬레이션): 곡 타임라인 렌더(마커 13개·슬라이드 13개·핸들 12개), 섹션 첫 슬라이드 음수 오프셋(−0.5초) 정상 반영 + 툴팁("마커 대비 −0.5초") 정확, Enter 넘김 기록(5초→10초 순차 기록), 곡 처음으로 되감기 시 커서 1로 리셋 후 재찍기(5초였던 위치가 3초로 재기록) 정상.
- 참고: LyricsStore는 메모리 전용이라 앱 재시작 시 가사 비어 있음 — 검증 시 HTML 가져오기로 데이터 로드 후 테스트. 타임라인 좌측 마커 라벨이 촘촘한 곡(섹션 짧고 많음)에서는 겹침 가능 — 실사용 중 거슬리면 라벨 축약/겹침 방지 로직 추가 검토.

### 진행 상황 (2026-07-16, 3차 — 타임라인 독립 스크롤 + 마커 조기 전환 버그 수정)
- **버그**: 편집 화면 타임라인에서 섹션 첫 슬라이드에 음수 오프셋(마커보다 먼저 전환)을 줘도 뷰어(밴드/싱어)에서는 정박(마커 시각)에만 바뀌었음.
  - **원인**: 뷰어의 `findCurrentEntry`가 "현재 섹션(secIdx) 안에서만" 슬라이드를 찾았음 — 아직 마커를 안 넘은 상태(이전 섹션 재생 중)에선 다음 섹션 슬라이드는 애초에 조회 대상이 아니었음. 편집 화면은 곡 전체를 연속 타임라인으로 보므로 이 문제가 없었음.
  - **수정**: index.html·singer.html 둘 다 "곡 전체 절대 초(abs)" 기준으로 슬라이드를 찾도록 변경. `fetchLyricCache`가 각 슬라이드의 `abs = sec.startInSong + 섹션내오프셋`을 계산해 곡 전체를 하나의 정렬된 배열로 만들고(`songSections` 캐시 추가), `findCurrentEntry/findNextEntry`는 이제 `(songName, absSec)`만 받아 secIdx 구분 없이 전체에서 검색. `applyState`에서 `absSec = songSections[song][secIdx].startInSong + sectionElapsedSec`로 계산해 넘겨줌. 마커 자체(카운트다운·진행률·상단 섹션명)는 여전히 서버가 판정한 실제 섹션 기준 그대로 — 슬라이드 조회 방식만 바뀜.
  - **검증**: 실사용자가 동시에 라이브 테스트 중이라 공유 데이터 대신 격리된 합성 데이터로 순수 함수 테스트 — 마커 10초 기준 오프셋 −0.8초(=9.2초)로 지정 후, 9.1초 경과 시 이전 섹션 유지·9.3초 경과 시 조기 전환 정상 확인.
- **타임라인 독립 스크롤(A안, 자동 추적) 구현**: `#song-tl`에 `position:sticky`+자체 `overflow-y:auto` 적용 — 카드(`#sections-list`)를 내려도 타임라인은 화면에 고정되고 자기 영역 안에서만 스크롤됨. 재생 따라가기 켜짐+재생 중일 때 `tickPlayhead`가 매 프레임 재생헤드를 타임라인 컨테이너 중앙에 오도록 `scrollTop` 갱신 — 카드 쪽 자동 스크롤과 동일한 원리.
- 빌드 성공, /Applications 설치·재시작 완료. 3개 페이지(edit/band/singer) JS 문법 검증 통과.
- **다음에 확인할 것**: Logic 실제 재생으로 ① 타임라인 sticky 동작 및 자동 스크롤 체감 ② 조기 전환이 뷰어에 실제 반영되는지 ③ 기존 나머지 항목(핸들 드래그, Enter 찍기, 따라가기 곡 전환) → 이상 없으면 릴리즈 여부 확인.

---

## 2026-07-06 작업 내역

### 마디 수 계산 개선 + 스캔 버튼 복원 + 결과 표시 (v0.2.2)

#### 마디 수 계산 개선 (`ScheduleStore.swift`, `WebServer.swift`)
- **기존 문제**: 가사 편집 화면에서 섹션 마디 수를 섹션 시작 지점의 BPM 하나로만 계산 → 레퍼런스 곡 기반 제작처럼 BPM이 매 마디마다 바뀌는 곡에서 오차 발생
- **수정**: `ScheduleStore`에 `barPositionAt(mtcSeconds:)` / `barsBetween(startMTC:endMTC:)` 메서드 추가. 스캔된 모든 템포 변화 지점의 SMPTE 시간과 마디 위치를 활용해 정확하게 계산
- **템포 데이터 없을 때**: BPM 120 폴백 대신 마디 그리드 자리에 주황색 `⚠️ 템포 스캔 필요` 경고 표시

#### 스캔 버튼 복원 (`AppDelegate.swift`)
- **원인**: `c66f00a` 커밋("ScheduleStore 구조 통합") 에서 `scanSchedule()`이 전체 스캔(`performScan`) 대신 마커만 읽는 `refreshMarkers()`를 호출하도록 잘못 교체됨
- **수정**: `scanSchedule()` → `performScan()` 호출로 복원 (마커/템포/박자표/조표 모두 스캔)

#### 스캔 결과 표시 (`AppDelegate.swift`, `ScheduleStore.swift`)
- `ScheduleStore.onSaved` 콜백 추가
- 스캔 완료 후 메뉴 항목이 `사전 스캔 완료 · 마커 66 / 템포 21 / 박자 7 / 조표 4` 형식으로 업데이트
- 앱 재시작 후에도 저장된 스캔 결과 항목 수 그대로 표시

---

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
