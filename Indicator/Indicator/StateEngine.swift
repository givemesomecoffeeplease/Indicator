import Foundation

let debugLogURL = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/indicator_debug.txt")
var debugLogHandle: FileHandle? = {
    FileManager.default.createFile(atPath: debugLogURL.path, contents: nil)
    return try? FileHandle(forWritingTo: debugLogURL)
}()
func debugLog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    debugLogHandle?.write(line.data(using: .utf8) ?? Data())
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
    private var countdownBeats: Int = 0
    private var currentSectionBeatsPerBar: Int = 4
    private var currentSectionBeatUnit: Int = 4

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
            let estimatedMTC = anchorMTC + barDiff * Double(currentSectionBeatsPerBar) * beatDuration()
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
            countdownBeats     = 0
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

        if nextChordMTC > 0 && mtcTime >= nextChordMTC - beatDuration() * 0.5 && !chordPending {
            chordPending = true
        }

        recompute()
    }

    func mtcStopped() {
        mtcIsPlaying   = false
        countdownBeats = 0
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

        // 비트마다 1씩 감소 (MTC 재계산 없이 — 같은 숫자 반복 방지)
        if countdownBeats > 0 { countdownBeats -= 1 }
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
        debugLog("[Apply] section='\(name)' idx=\(idx) start=\(String(format:"%.1f",bounds.start)) end=\(String(format:"%.1f",bounds.end)) retro=\(retroactive)")

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

        initCountdown()
    }

    // MARK: - 카운트다운

    // 섹션 진입 시 MTC로 초기 비트 수 계산 (이후 onBeat마다 -1)
    private func initCountdown() {
        guard let bounds = sectionBounds(idx: currentSectionIdx) else { return }
        let remainingSec = bounds.end - mtcTime
        countdownBeats = max(0, Int((remainingSec / beatDuration()).rounded()))
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
        let end   = idx + 1 < markers.count ? markers[idx + 1].mtcSeconds : start + 30.0
        return (start, end)
    }

    private func beatDuration() -> Double {
        // MIDI Clock 실측값 우선, 없으면 AX BPM 사용
        measuredBeatDuration > 0 ? measuredBeatDuration : 60.0 / max(1, snapshot.bpm)
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

    // MARK: - 코드 beat-snap

    private func chordsInCurrentSection() -> [ChordEvent] {
        guard let bounds = sectionBounds(idx: currentSectionIdx) else { return [] }
        // 코드는 bar/beat 기반이라 MTC로 직접 필터링 불가 — 섹션 내 상대 위치로 추정
        // sectionEntryMTC 기준으로 코드 bar를 초로 변환해서 비교
        let bpb = Double(currentBeatsPerBar())
        let bd  = beatDuration()
        return snapshot.chords.filter { ch in
            let chordMTC = sectionEntryMTC + (Double(ch.bar - 1) + Double(ch.beat - 1) / bpb) * bpb * bd
            return chordMTC >= bounds.start && chordMTC < bounds.end
        }
    }

    private func chordMTCTime(_ ch: ChordEvent) -> Double {
        let bpb = Double(currentBeatsPerBar())
        let bd  = beatDuration()
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

    // 섹션 내 상대 bar 위치 (슬라이드 표시용, index.html findCurrentEntry 기준)
    private func realtimeBarFloat() -> Double {
        guard sectionEntryMTC > 0 else { return 0 }
        let elapsed = mtcTime - sectionEntryMTC
        guard elapsed >= 0 else { return 0 }
        let bpb = Double(currentBeatsPerBar())
        let bd  = beatDuration()
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
        state.currentSectionIndexInSong = sections.firstIndex(of: cm) ?? -1

        // 진행률: MTC 기반
        if sectionDurationSec > 0 {
            let elapsed = mtcIsPlaying ? (mtcTime - sectionEntryMTC) : 0
            state.sectionProgress   = min(1, max(0, elapsed / sectionDurationSec))
            state.sectionLengthBars = sectionDurationSec / (Double(currentBeatsPerBar()) * beatDuration())
        }

        // 카운트다운 — MIDI Clock 비트마다 recalcCountdown()이 갱신한 값 사용
        // (MTC로 매번 재계산하면 beatDuration 오차로 버벅임 발생)
        let threshold = countdownThresholdBars * currentSectionBeatsPerBar
        state.countdownBars = (countdownBeats > 0 && countdownBeats <= threshold) ? countdownBeats : 0

        // 코드
        let sectionChords = chordsInCurrentSection()
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

        if nm != nil, let bounds = sectionBounds(idx: idx + 1) {
            let bpb = Double(currentBeatsPerBar())
            let bd  = beatDuration()
            let nextSectionEntry = bounds.start
            let nextChords = snapshot.chords.filter { ch in
                let chMTC = nextSectionEntry + (Double(ch.bar - 1) + Double(ch.beat - 1) / bpb) * bpb * bd
                return chMTC >= bounds.start && chMTC < bounds.end
            }
            state.nextSectionChords    = nextChords.map { $0.name }
            state.nextSectionChordBars = nextChords.map { $0.bar }
        }

        if let nextSong = markers.first(where: { $0.isSong && $0.mtcSeconds > mtcTime + 0.5 }) {
            state.nextSongName = nextSong.displayName
        }

        state.isPlaying       = mtcIsPlaying
        state.currentBarFloat = realtimeBarFloat()
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
