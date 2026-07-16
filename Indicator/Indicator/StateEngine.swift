import Foundation

// 디버그 로그: ~/Library/Logs/Indicator/indicator_debug.txt
// 실행할 때마다 새로 시작, 한 세션 최대 20MB (라이브 중 디스크 폭주 방지)
let debugLogURL: URL = {
    let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Indicator")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("indicator_debug.txt")
}()
var debugLogHandle: FileHandle? = {
    FileManager.default.createFile(atPath: debugLogURL.path, contents: nil)
    return try? FileHandle(forWritingTo: debugLogURL)
}()
private let debugLogMaxBytes: UInt64 = 20 * 1024 * 1024
private var debugLogBytes: UInt64 = 0
private var debugLogCapped = false
func debugLog(_ msg: String) {
    guard !debugLogCapped else { return }
    let line = "\(Date()) \(msg)\n"
    let data = line.data(using: .utf8) ?? Data()
    debugLogBytes += UInt64(data.count)
    if debugLogBytes > debugLogMaxBytes {
        debugLogCapped = true
        debugLogHandle?.write("--- 로그 용량 한도(20MB) 도달, 이후 기록 중단 ---\n".data(using: .utf8)!)
        return
    }
    debugLogHandle?.write(data)
}

class StateEngine {

    var onStateChange: ((IndicatorState) -> Void)?
    var onJump: (() -> Void)?
    var countdownThresholdBars: Int { SettingsStore.shared.countdownBars }

    // ── 입력 ──────────────────────────────────────────────
    private var snapshot   = LogicSnapshot()
    private var mtcTime: TimeInterval = 0
    private var prevMTCTime: TimeInterval = 0
    private var mtcIsPlaying = false

    // ── 현재 섹션 상태 ─────────────────────────────────────
    private var currentSectionIdx: Int = -1
    private var currentSectionName: String = ""
    private var sectionEntryMTC: TimeInterval = 0   // 이 섹션 진입 시점의 MTC
    private var sectionDurationSec: Double = 0

    // ── bar↔MTC 앵커 (재생 중 동시에 알고 있는 값으로 업데이트) ──
    private var anchorBar: Int = 0
    private var anchorMTC: TimeInterval = 0

    // ── 카운트다운 ─────────────────────────────────────────
    // 스캔된 템포맵 기준 진짜 박 그리드(MTC)로 표시 시각을 정하고,
    // 한 번 표시된 숫자는 절대 되돌아가지 않는 단방향 가드로 MTC 지터 깜빡임 차단.
    // (MIDI Clock 펄스는 재생 시작 위치에 따라 박 그리드와 어긋나므로 사용하지 않음)
    private var cdTargets: [(beat: Int, mtc: Double)] = []  // 섹션 진입 시 계산
    private var cdShown: Int = 0                             // 0 = 미표시
    private var currentSectionBeatsPerBar: Int = 4
    private var currentSectionBeatUnit: Int = 4

    // ── 표시 위치 단방향 가드 (MTC 지터로 화면이 되돌아가는 것 방지) ──
    private var lastSentBarFloat: Double = 0     // 마지막으로 내보낸 barFloat
    private var lastSentElapsedSec: Double = 0   // 마지막으로 내보낸 섹션 경과 초

    // ── 코드 beat-snap ────────────────────────────────────
    private var currentChordIdx: Int = -1
    private var nextChordMTC: TimeInterval = 0
    private var chordPending = false

    // ── 브로드캐스트 rate limit ────────────────────────────
    private var lastState = IndicatorState()
    private var lastBroadcast: TimeInterval = 0
    private let minInterval: TimeInterval = 0.05

    // ── MIDI Clock 중복 방지 + BPM 자동 측정 ────────────────
    private var lastBeatWall: TimeInterval = 0
    private var measuredBeatDuration: Double = 0  // MIDI Clock 간격 측정값 (0=미측정)

    // MARK: - AX 업데이트 (250ms)

    func update(snapshot: LogicSnapshot) {
        self.snapshot = snapshot
        debugLog("[AX] mtcTime=\(String(format:"%.3f",mtcTime)) markers=\(snapshot.markers.count) bpm=\(snapshot.bpm) playing=\(mtcIsPlaying)")

        // 재생 중에는 앵커 갱신
        if mtcIsPlaying && snapshot.transportBar > 0 && mtcTime > 0 {
            anchorBar = snapshot.transportBar
            anchorMTC = mtcTime
        }

        let detectedIdx: Int
        if mtcIsPlaying {
            detectedIdx = detectSectionIdx(at: mtcTime)
        } else if snapshot.transportMTC > 0 {
            // AX 타임코드 디스플레이 — 정지 상태에서도 읽힘, 점프 즉시 반영
            detectedIdx = detectSectionIdx(at: snapshot.transportMTC)
        } else if anchorBar > 0 {
            // 폴백: 앵커로 추산
            let barDiff = Double(snapshot.transportBar - anchorBar)
            let estimatedMTC = anchorMTC + barDiff * Double(currentSectionBeatsPerBar) * notatedBeatDuration()
            detectedIdx = detectSectionIdx(at: estimatedMTC)
        } else {
            detectedIdx = -1
        }

        debugLog("[AX] playing=\(mtcIsPlaying) transportBar=\(snapshot.transportBar) anchorBar=\(anchorBar) detectedIdx=\(detectedIdx) currentIdx=\(currentSectionIdx)")

        if detectedIdx != currentSectionIdx, detectedIdx >= 0 {
            let detectedMTC = markerMTC(at: detectedIdx)
            let currentMTC  = currentSectionIdx >= 0 ? markerMTC(at: currentSectionIdx) : 0
            if mtcIsPlaying ? detectedMTC >= currentMTC : true {
                debugLog("[Section] AX confirm → \(sectionName(at: detectedIdx))")
                applySection(idx: detectedIdx, retroactive: true)
            }
        } else {
            checkSectionEnd()
        }

        debugLog("[BPB] transportBar=\(snapshot.transportBar) bpb=\(currentSectionBeatsPerBar)")

        recalcNextChord()
        recompute()
    }

    // MARK: - MTC 업데이트 (10ms)

    func updateMTC(time: TimeInterval) {
        let jumped = (mtcIsPlaying && abs(time - prevMTCTime) > 2.0) || !mtcIsPlaying
        if jumped {
            currentSectionIdx  = -1
            currentSectionName = ""
            currentChordIdx    = -1
            chordPending       = false
            nextChordMTC       = 0
            cdTargets          = []
            cdShown            = 0
            lastSentBarFloat   = 0
            lastSentElapsedSec = 0
            onJump?()
        }
        prevMTCTime  = mtcTime
        mtcTime      = time
        mtcIsPlaying = true

        // MTC 기반 즉각 섹션 감지 (점프 직후 포함)
        let detectedIdx = detectSectionIdx(at: mtcTime)
        if detectedIdx != currentSectionIdx, detectedIdx >= 0 {
            let detectedMTC = markerMTC(at: detectedIdx)
            let currentMTC  = currentSectionIdx >= 0 ? markerMTC(at: currentSectionIdx) : 0
            if detectedMTC >= currentMTC || jumped {
                debugLog("[Section] MTC detect → \(sectionName(at: detectedIdx)) @ \(String(format:"%.1f",mtcTime))s")
                applySection(idx: detectedIdx, retroactive: true)
            }
        }

        if nextChordMTC > 0 && mtcTime >= nextChordMTC - notatedBeatDuration() * 0.5 && !chordPending {
            chordPending = true
        }

        recompute()
    }

    func mtcStopped() {
        mtcIsPlaying   = false
        cdShown        = 0
        let state = compute()
        lastState     = state
        lastBroadcast = 0
        onStateChange?(state)
    }

    // MARK: - MIDI Clock beat

    func onBeat() {
        guard mtcIsPlaying else { return }
        let wall = Date().timeIntervalSinceReferenceDate
        guard wall - lastBeatWall >= 0.1 else { return }

        // MIDI Clock 간격으로 실제 BPM 측정 (지수 평균으로 노이즈 제거)
        let interval = wall - lastBeatWall
        if interval < 3.0 {
            measuredBeatDuration = measuredBeatDuration > 0
                ? 0.85 * measuredBeatDuration + 0.15 * interval
                : interval
        }
        lastBeatWall = wall

        checkSectionEnd()

        if chordPending {
            chordPending = false
            currentChordIdx += 1
            recalcNextChord()
            let state = compute()
            lastState     = state
            lastBroadcast = Date().timeIntervalSinceReferenceDate
            onStateChange?(state)
            return
        }

        recompute()
    }

    // MARK: - 섹션 적용

    private func applySection(idx: Int, retroactive: Bool) {
        guard let bounds = sectionBounds(idx: idx) else { return }
        let name = sectionName(at: idx)
        debugLog("[Apply] section='\(name)' idx=\(idx) start=\(String(format:"%.3f",bounds.start)) end=\(String(format:"%.3f",bounds.end)) retro=\(retroactive)")

        currentSectionIdx  = idx
        currentSectionName = name
        currentChordIdx    = -1
        chordPending       = false
        nextChordMTC       = 0
        sectionDurationSec = bounds.end - bounds.start

        // ScheduleStore MTC 기반으로 섹션 박자 즉시 확정 (AX 지연 없음)
        if let ts = ScheduleStore.shared.beatsPerBarAt(mtcSeconds: bounds.start) {
            currentSectionBeatsPerBar = ts.beatsPerBar
            currentSectionBeatUnit    = ts.beatUnit
        }

        if retroactive {
            sectionEntryMTC = bounds.start
        } else {
            sectionEntryMTC = mtcTime
        }

        // 새 섹션 진입: 표시 위치 가드 리셋
        lastSentBarFloat = 0
        lastSentElapsedSec = 0

        initCountdown()
    }

    // MARK: - 카운트다운

    // 섹션 진입 시 이 섹션 끝 기준 박 그리드 MTC를 미리 계산.
    // 카운트다운은 "같은 곡 안에서 다음 섹션으로 전환"만 알려주는 기능 — 곡의 마지막
    // 섹션(다음은 다른 곡)에서는 계산하지 않음. 안 그러면 sectionBounds가 다음 곡 마커까지
    // 내다보며 잡은 먼 경계를 향해 카운트다운이 섹션 중간에 뜬금없이 나타나게 됨.
    private func initCountdown() {
        cdShown = 0
        let markers = markersInCurrentSong()
        guard currentSectionIdx + 1 < markers.count,
              let bounds = sectionBounds(idx: currentSectionIdx) else { cdTargets = []; return }
        cdTargets = ScheduleStore.shared.countdownBeatMTCs(
            sectionEndMTC: bounds.end, barsBack: countdownThresholdBars)
    }

    // 섹션 끝 지났는지 확인 (onBeat에서 호출)
    private func checkSectionEnd() {
        guard let bounds = sectionBounds(idx: currentSectionIdx) else { return }
        if mtcTime > bounds.end + 0.1 {
            let markers = markersInCurrentSong()
            let nextIdx = currentSectionIdx + 1
            if nextIdx < markers.count {
                applySection(idx: nextIdx, retroactive: true)
            }
        }
    }

    // MARK: - 마커 헬퍼

    private func markersInCurrentSong() -> [Marker] {
        let all   = snapshot.markers
        let songs = all.filter { $0.isSong }
        guard !songs.isEmpty else { return [] }
        let refMTC: Double
        if mtcIsPlaying {
            refMTC = mtcTime
        } else if snapshot.transportMTC > 0 {
            refMTC = snapshot.transportMTC
        } else if anchorBar > 0 {
            let barDiff = Double(snapshot.transportBar - anchorBar)
            refMTC = anchorMTC + barDiff * Double(currentSectionBeatsPerBar) * beatDuration()
        } else {
            refMTC = mtcTime
        }
        let song = songs.last(where: { $0.mtcSeconds <= refMTC + 0.5 }) ?? songs[0]
        guard let si = all.firstIndex(of: song) else { return [] }
        let ei = all.indices.first { i in i > si && all[i].isSong } ?? all.endIndex
        return Array(all[si..<ei])
    }

    private func detectSectionIdx(at mtcSec: Double) -> Int {
        let markers = markersInCurrentSong()
        guard let last = markers.indices.last(where: { markers[$0].mtcSeconds <= mtcSec + 0.1 }) else { return -1 }
        return last
    }


    private func sectionName(at idx: Int) -> String {
        let markers = markersInCurrentSong()
        guard idx >= 0, idx < markers.count else { return "" }
        return markers[idx].displayName
    }

    private func markerMTC(at idx: Int) -> Double {
        let markers = markersInCurrentSong()
        guard idx >= 0, idx < markers.count else { return 0 }
        return markers[idx].mtcSeconds
    }

    private func sectionBounds(idx: Int) -> (start: Double, end: Double)? {
        let markers = markersInCurrentSong()
        guard idx >= 0, idx < markers.count else { return nil }
        let start = markers[idx].mtcSeconds
        if idx + 1 < markers.count {
            return (start, markers[idx + 1].mtcSeconds)
        }
        // 곡의 마지막 섹션 — markersInCurrentSong()엔 다음 곡 마커가 안 들어있어서
        // "다음이 없다"고 오판하면 안 됨. 전체 마커 목록에서 다음 곡의 시작 마커를 찾아
        // 진짜 경계로 사용 (진행률·섹션 길이 정확도용). 그것도 없으면(진짜 세트리스트
        // 마지막) 30초를 최후의 추정값으로만 사용.
        if let lastMarker = markers.last,
           let allIdx = snapshot.markers.firstIndex(of: lastMarker),
           allIdx + 1 < snapshot.markers.count {
            return (start, snapshot.markers[allIdx + 1].mtcSeconds)
        }
        return (start, start + 30.0)
    }

    // 4분음표 하나의 길이. MIDI Clock은 박자표와 무관하게 항상 4분음표당 24펄스이므로
    // 이 값 자체는 분모(beatUnit)에 영향받지 않음 — 스케일링은 notatedBeatDuration()에서 처리.
    private func beatDuration() -> Double {
        // MIDI Clock 실측값 우선, 없으면 AX BPM 사용
        measuredBeatDuration > 0 ? measuredBeatDuration : 60.0 / max(1, snapshot.bpm)
    }

    // 박자표에 "표기된" 박 하나의 실제 길이. 분모가 4(3/4, 5/4 등)면 4분음표 길이와 같지만,
    // 분모가 8(6/8, 9/8, 12/8 등)이면 그 절반 — Logic BPM은 항상 4분음표 기준이므로
    // 분모가 4가 아닌 겹박자에서는 4/beatUnit 배율로 환산해야 마디·박 길이가 실제와 맞음.
    private func notatedBeatDuration() -> Double {
        beatDuration() * 4.0 / Double(max(1, currentBeatUnit()))
    }

    private func beatsPerBarAt(bar: Int) -> Int {
        let events = snapshot.timeSigEvents
        guard !events.isEmpty else { return max(1, snapshot.beatsPerBar) }
        return events.last(where: { $0.bar <= bar })?.beatsPerBar ?? events[0].beatsPerBar
    }

    // ScheduleStore MTC 기반 조회 (사전 스캔 시), 없으면 AX timeSigEvents 폴백
    private func currentBeatsPerBar() -> Int {
        if let ts = ScheduleStore.shared.beatsPerBarAt(mtcSeconds: mtcTime) {
            return ts.beatsPerBar
        }
        return currentSectionBeatsPerBar
    }

    private func currentBeatUnit() -> Int {
        if let ts = ScheduleStore.shared.beatsPerBarAt(mtcSeconds: mtcTime) {
            return ts.beatUnit
        }
        return currentSectionBeatUnit
    }

    // MARK: - 코드 beat-snap

    private func chordsInCurrentSection() -> [ChordEvent] {
        return chordsInSection(idx: currentSectionIdx)
    }

    private func chordsInSection(idx: Int) -> [ChordEvent] {
        guard let bounds = sectionBounds(idx: idx) else { return [] }
        // 코드는 bar/beat 기반이라 MTC로 직접 필터링 불가 — 섹션 시작 기준 상대 위치로 추정
        let bpb = Double(currentBeatsPerBar())
        let bd  = notatedBeatDuration()
        return snapshot.chords.filter { ch in
            let chordMTC = bounds.start + (Double(ch.bar - 1) + Double(ch.beat - 1) / bpb) * bpb * bd
            return chordMTC >= bounds.start && chordMTC < bounds.end
        }
    }

    private func chordMTCTime(_ ch: ChordEvent) -> Double {
        let bpb = Double(currentBeatsPerBar())
        let bd  = notatedBeatDuration()
        return sectionEntryMTC + (Double(ch.bar - 1) + Double(ch.beat - 1) / bpb) * bpb * bd
    }

    private func recalcNextChord() {
        let chords = chordsInCurrentSection()
        guard !chords.isEmpty else { currentChordIdx = -1; nextChordMTC = 0; return }

        if currentChordIdx == -1 {
            currentChordIdx = chords.indices.last(where: { chordMTCTime(chords[$0]) <= mtcTime + 0.1 }) ?? 0
        }

        let nextIdx = currentChordIdx + 1
        guard nextIdx < chords.count else { nextChordMTC = 0; return }
        nextChordMTC = chordMTCTime(chords[nextIdx])
    }

    // 섹션 내 상대 bar 위치 (진행률·레거시 표시용)
    private func realtimeBarFloat() -> Double {
        guard sectionEntryMTC > 0 else { return 0 }
        let elapsed = mtcTime - sectionEntryMTC
        guard elapsed >= 0 else { return 0 }
        let bpb = Double(currentBeatsPerBar())
        let bd  = notatedBeatDuration()
        return elapsed / (bpb * bd)
    }

    // occurrence 인덱스 계산 (같은 이름 섹션이 몇 번째인지)
    private func occurrenceIdx(of marker: Marker, in markers: [Marker]) -> Int {
        let sections = markers.filter { !$0.isSong }
        guard let pos = sections.firstIndex(of: marker) else { return 0 }
        return sections[0..<pos].filter { $0.displayName == marker.displayName }.count
    }

    // MARK: - 계산 & 브로드캐스트

    private func recompute() {
        let state = compute()
        guard state != lastState else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastBroadcast >= minInterval else { return }
        lastState = state   // 실제 브로드캐스트할 때만 업데이트
        lastBroadcast = now
        onStateChange?(state)
    }

    private func compute() -> IndicatorState {
        var state   = IndicatorState()
        let markers = snapshot.markers
        guard !markers.isEmpty else { return state }

        let songMarkers = markers.filter { $0.isSong }
        state.songs = songMarkers.map { $0.displayName }

        let inSong = markersInCurrentSong()
        guard !inSong.isEmpty else { return state }

        let currentSong = songMarkers.last { $0.mtcSeconds <= mtcTime + 0.5 }
        state.currentSongIndex = currentSong.flatMap { songMarkers.firstIndex(of: $0) } ?? -1

        let sections = inSong.filter { !$0.isSong }
        state.currentSongSections = sections.map { $0.displayName }

        guard currentSectionIdx >= 0, currentSectionIdx < inSong.count else { return state }
        let idx = currentSectionIdx

        // 섹션명·노트 등 카드 표시는 실제 섹션 기준
        let cm = inSong[idx]
        let nm = idx + 1 < inSong.count ? inSong[idx + 1] : nil

        let songName = currentSong?.displayName ?? ""
        state.currentSection = cm.displayName
        if let nm = nm {
            state.nextSection = nm.displayName
        } else {
            if let nextSong = markers.first(where: { $0.isSong && $0.mtcSeconds > mtcTime + 0.5 }) {
                state.nextSection       = nextSong.displayName
                state.nextSectionIsSong = true
            }
        }

        // occurrence 인덱스로 LyricsStore 조회
        let curOccIdx = occurrenceIdx(of: cm, in: inSong)
        let (curData, _) = LyricsStore.shared.resolve(song: songName, section: cm.displayName, occIdx: curOccIdx)
        state.lyricCue   = curData.lyricCue
        state.note       = curData.sessionNote
        state.singerNote = curData.singerNote

        if let nm = nm {
            let nxtOccIdx = occurrenceIdx(of: nm, in: inSong)
            let (nxtData, _) = LyricsStore.shared.resolve(song: songName, section: nm.displayName, occIdx: nxtOccIdx)
            state.nextLyricCue   = nxtData.lyricCue
            state.nextNote       = nxtData.sessionNote
            state.nextSingerNote = nxtData.singerNote
        }
        state.currentSectionIndexInSong = sections.firstIndex(of: inSong[idx]) ?? -1

        // 진행률: MTC 기반 — 항상 실제 섹션 기준
        if sectionDurationSec > 0 {
            let elapsed = mtcIsPlaying ? (mtcTime - sectionEntryMTC) : 0
            state.sectionProgress    = min(1, max(0, elapsed / sectionDurationSec))
            state.sectionLengthBars  = sectionDurationSec / (Double(currentBeatsPerBar()) * notatedBeatDuration())
            state.sectionDurationSec = sectionDurationSec
        }

        // 카운트다운 — 스캔된 박 그리드(MTC) 도달 시점에 표시.
        // 단방향 가드: 한 번 표시된 숫자는 커지지 않음 (MTC 지터로 시간이 뒤로 튀어도 깜빡임 없음)
        if mtcIsPlaying, !cdTargets.isEmpty,
           let bounds = sectionBounds(idx: idx), mtcTime < bounds.end,
           let cur = cdTargets.last(where: { mtcTime >= $0.mtc }) {
            if cdShown == 0 || cur.beat < cdShown { cdShown = cur.beat }
        }
        state.countdownBars = cdShown

        // 코드
        let sectionChords = chordsInSection(idx: idx)
        state.chords      = sectionChords.map { $0.name }
        state.chordBars   = sectionChords.map { $0.bar }
        state.chordBeats  = sectionChords.map { $0.beat }
        let displayChordIdx: Int
        if chordPending, nextChordMTC > 0, (nextChordMTC - mtcTime) * 1000 < 80 {
            displayChordIdx = currentChordIdx + 1
        } else {
            displayChordIdx = currentChordIdx
        }
        state.currentChordIndex = (displayChordIdx >= 0 && displayChordIdx < sectionChords.count) ? displayChordIdx : -1

        if nm != nil {
            let nextChords = chordsInSection(idx: idx + 1)
            state.nextSectionChords    = nextChords.map { $0.name }
            state.nextSectionChordBars = nextChords.map { $0.bar }
        }

        if let nextSong = markers.first(where: { $0.isSong && $0.mtcSeconds > mtcTime + 0.5 }) {
            state.nextSongName = nextSong.displayName
        }

        state.isPlaying       = mtcIsPlaying
        var barFloat = realtimeBarFloat()
        // 단방향 가드: MTC 지터로 시간이 살짝 뒤로 튀어도 슬라이드가 되돌아가지 않도록
        // (섹션 전환/점프 시 리셋)
        if mtcIsPlaying {
            if barFloat < lastSentBarFloat { barFloat = lastSentBarFloat }
            else { lastSentBarFloat = barFloat }
        }
        state.currentBarFloat = barFloat

        // 섹션 진입 후 경과 초 — MTC 시간 기반 슬라이드 전환의 기준 (동일한 단방향 가드)
        var elapsedSec = sectionEntryMTC > 0 ? max(0, mtcTime - sectionEntryMTC) : 0
        if mtcIsPlaying {
            if elapsedSec < lastSentElapsedSec { elapsedSec = lastSentElapsedSec }
            else { lastSentElapsedSec = elapsedSec }
        }
        state.sectionElapsedSec = elapsedSec
        state.bpm             = snapshot.bpm
        state.beatsPerBar   = currentSectionBeatsPerBar
        state.timeSignature = "\(currentSectionBeatsPerBar)/\(currentSectionBeatUnit)"
        state.key             = snapshot.key

        if nextChordMTC > 0 && mtcIsPlaying {
            state.nextChordInMs = max(0, (nextChordMTC - mtcTime) * 1000)
        }
        state.broadcastTimestampMs = Date().timeIntervalSince1970 * 1000

        return state
    }
}
