import Foundation

private let debugLogURL = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/indicator_debug.txt")
private var debugLogHandle: FileHandle? = {
    FileManager.default.createFile(atPath: debugLogURL.path, contents: nil)
    return try? FileHandle(forWritingTo: debugLogURL)
}()
private func debugLog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    debugLogHandle?.write(line.data(using: .utf8) ?? Data())
}

class StateEngine {

    var onStateChange: ((IndicatorState) -> Void)?
    var countdownThresholdBars: Int { SettingsStore.shared.countdownBars }

    // ── 입력 ──────────────────────────────────────────────
    private var snapshot   = LogicSnapshot()
    private var mtcTime: TimeInterval = 0
    private var prevMTCTime: TimeInterval = 0
    private var mtcIsPlaying = false

    // ── AX 앵커 (250ms마다 보정) ──────────────────────────
    // 마디 위치 계산에는 쓰지 않음 — 오직 섹션 감지와 전환 예측용
    private var anchorBar: Double = 0
    private var anchorMTC: TimeInterval = 0

    // ── 섹션 감지 안정화 (연속 2회 동일해야 전환) ───────────
    private var pendingSectionName: String = ""
    private var pendingCount: Int = 0

    // ── 현재 섹션 상태 ─────────────────────────────────────
    private var currentSectionName: String = ""
    private var sectionEntryMTC: TimeInterval = 0   // 이 섹션 시작 시점의 MTC
    private var sectionDurationSec: Double = 0       // 이 섹션 총 길이(초)

    // ── 다음 섹션 전환 예측 ───────────────────────────────
    private var transitionMTC: TimeInterval = 0      // 전환이 일어날 예상 MTC

    // ── 카운트다운 ─────────────────────────────────────────
    private var countdownBeats: Int = 0              // 남은 박자 수

    // ── 코드 beat-snap ────────────────────────────────────
    private var currentChordIdx: Int = -1
    private var nextChordMTC: TimeInterval = 0
    private var chordPending = false

    // ── 브로드캐스트 rate limit ────────────────────────────
    private var lastState = IndicatorState()
    private var lastBroadcast: TimeInterval = 0
    private let minInterval: TimeInterval = 0.05

    // ── MIDI Clock 중복 방지 ───────────────────────────────
    private var lastBeatWall: TimeInterval = 0

    // MARK: - AX 업데이트 (250ms)

    func update(snapshot: LogicSnapshot) {
        self.snapshot = snapshot

        let bar = Double(snapshot.transportBar)
                + Double(snapshot.transportBeat - 1) / Double(max(1, snapshot.beatsPerBar))
        anchorBar = bar
        anchorMTC = mtcTime

        debugLog("[AX] bar=\(String(format:"%.2f",bar)) mtcTime=\(String(format:"%.3f",mtcTime)) markers=\(snapshot.markers.count) bpm=\(snapshot.bpm) playing=\(mtcIsPlaying)")

        // 어느 섹션인지 감지 — 연속 2회 동일해야 전환 (1회짜리 AX 오독 방지)
        let detected = detectSectionName(at: anchorBar)

        if detected == pendingSectionName {
            pendingCount += 1
        } else {
            pendingSectionName = detected
            pendingCount = 1
        }

        // 재생 중엔 2회 연속 확인 (AX 오독 방지), 정지 상태엔 즉시 반영
        let confirmedSection = (mtcIsPlaying && pendingCount < 2) ? currentSectionName : detected

        if confirmedSection != currentSectionName {
            let detectedStart = sectionBounds(name: confirmedSection)?.start ?? 0
            let currentStart  = sectionBounds(name: currentSectionName)?.start ?? -1
            if detectedStart >= currentStart {
                applySection(name: confirmedSection, retroactive: true)
            }
        } else {
            // 같은 섹션인데 anchorBar가 섹션 끝을 지나쳤으면 강제 전환
            if let bounds = sectionBounds(name: currentSectionName), anchorBar >= bounds.end - 0.1 {
                executeTransition()
            } else {
                recalcTransition()
            }
        }

        recalcNextChord()
        recompute()
    }

    // MARK: - MTC 업데이트 (10ms)

    func updateMTC(time: TimeInterval) {
        if Int(time * 10) % 10 == 0 { debugLog("[MTC] time=\(String(format:"%.3f",time))") } // 1초마다만
        // 점프 감지 (되감기 / 재생헤드 이동)
        if mtcIsPlaying && abs(time - prevMTCTime) > 2.0 {
            currentSectionName = ""
            transitionMTC      = 0
            currentChordIdx    = -1
            chordPending       = false
            nextChordMTC       = 0
            pendingSectionName = ""
            pendingCount       = 0
        }
        prevMTCTime  = mtcTime
        mtcTime      = time
        mtcIsPlaying = true

        // 코드 전환 예약
        if nextChordMTC > 0 && mtcTime >= nextChordMTC - beatDuration() * 0.5 && !chordPending {
            chordPending = true
        }

        recompute()
    }

    func mtcStopped() {
        mtcIsPlaying       = false
        transitionMTC      = 0
        countdownBeats     = 0
        pendingSectionName = ""
        pendingCount       = 0
        let state = compute()
        lastState    = state
        lastBroadcast = 0
        onStateChange?(state)
    }

    // MARK: - MIDI Clock beat (박자 경계)

    func onBeat() {
        guard mtcIsPlaying else { return }
        let wall = Date().timeIntervalSinceReferenceDate
        guard wall - lastBeatWall >= 0.1 else { return }
        lastBeatWall = wall
        debugLog("[Beat] countdownBeats=\(countdownBeats)")

        if countdownBeats > 1 {
            countdownBeats -= 1
        } else if countdownBeats == 1 {
            countdownBeats = 0
            executeTransition()
        }

        if chordPending {
            chordPending = false
            currentChordIdx += 1
            recalcNextChord()
        }

        recompute()
    }

    // MARK: - 섹션 적용

    // retroactive: AX가 이미 섹션 중간에서 감지한 경우 → sectionEntryMTC를 역산
    private func applySection(name: String, retroactive: Bool) {
        guard let (startBar, endBar) = sectionBounds(name: name) else {
            debugLog("[Apply] sectionBounds nil for '\(name)'")
            return
        }
        debugLog("[Apply] section='\(name)' start=\(startBar) end=\(endBar) retro=\(retroactive)")

        currentSectionName = name
        currentChordIdx    = -1
        chordPending       = false
        nextChordMTC       = 0

        sectionDurationSec = calcDuration(from: startBar, to: endBar)

        if retroactive {
            let secElapsed  = calcDuration(from: startBar, to: anchorBar)
            sectionEntryMTC = anchorMTC - secElapsed
            countdownBeats  = calcBeats(from: anchorBar, to: endBar)
        } else {
            sectionEntryMTC = mtcTime
            countdownBeats  = calcBeats(from: startBar, to: endBar)
        }

        recalcTransition()
    }

    // MARK: - 전환 예측 재계산

    private func recalcTransition() {
        let markers  = markersInCurrentSong()
        guard let idx = markers.firstIndex(where: { $0.displayName == currentSectionName }),
              idx + 1 < markers.count else {
            transitionMTC = 0
            return
        }
        let nextBar = markerBarFloat(markers[idx + 1])
        transitionMTC = anchorMTC + calcDuration(from: anchorBar, to: nextBar)
    }

    // MARK: - 전환 실행 (MIDI Clock beat에서)

    private func executeTransition() {
        let markers = markersInCurrentSong()
        guard let idx = markers.firstIndex(where: { $0.displayName == currentSectionName }),
              idx + 1 < markers.count else { return }

        let nextMarker = markers[idx + 1]
        applySection(name: nextMarker.displayName, retroactive: false)
        recompute()
    }

    // MARK: - 마커 헬퍼

    private func markersInCurrentSong() -> [Marker] {
        let all   = snapshot.markers
        let songs = all.filter { $0.isSong }
        guard !songs.isEmpty else { return [] }
        // 현재 위치 이전의 마지막 곡 마커 — 없으면 첫 번째 곡으로 fallback
        let song = songs.last(where: { markerBarFloat($0) <= anchorBar + 0.5 }) ?? songs[0]
        guard let si = all.firstIndex(of: song) else { return [] }
        let ei = all.indices.first { i in i > si && all[i].isSong } ?? all.endIndex
        return Array(all[si..<ei])
    }

    private func detectSectionName(at bar: Double) -> String {
        markersInCurrentSong().last { markerBarFloat($0) <= bar + 0.1 }?.displayName ?? ""
    }

    private func sectionBounds(name: String) -> (start: Double, end: Double)? {
        let markers = markersInCurrentSong()
        guard let idx = markers.firstIndex(where: { $0.displayName == name }) else { return nil }
        let start = markerBarFloat(markers[idx])
        let end   = idx + 1 < markers.count ? markerBarFloat(markers[idx + 1]) : start + 8
        return (start, end)
    }

    private func markerBarFloat(_ m: Marker) -> Double {
        Double(m.bar) + Double(m.beat - 1) / Double(max(1, snapshot.beatsPerBar))
    }

    private func beatDuration() -> Double {
        60.0 / max(1, snapshot.bpm)
    }

    // 특정 마디의 박자 — timeSigEvents 기준, 없으면 snapshot.beatsPerBar
    private func beatsPerBarAt(bar: Double) -> Int {
        let evs = snapshot.timeSigEvents
        guard !evs.isEmpty else { return snapshot.beatsPerBar }
        return evs.last { Double($0.bar) <= bar }?.beatsPerBar ?? snapshot.beatsPerBar
    }

    // startBar ~ endBar 구간의 총 길이(초) — 변박 구간별 합산
    private func calcDuration(from startBar: Double, to endBar: Double) -> Double {
        guard endBar > startBar else { return 0 }
        let changes = snapshot.timeSigEvents.filter { Double($0.bar) > startBar && Double($0.bar) < endBar }
        var total = 0.0
        var cur   = startBar
        for ev in changes {
            total += (Double(ev.bar) - cur) * Double(beatsPerBarAt(bar: cur)) * beatDuration()
            cur    = Double(ev.bar)
        }
        total += (endBar - cur) * Double(beatsPerBarAt(bar: cur)) * beatDuration()
        return total
    }

    // startBar ~ endBar 구간의 총 박자 수 — 변박 구간별 합산
    private func calcBeats(from startBar: Double, to endBar: Double) -> Int {
        guard endBar > startBar else { return 0 }
        let changes = snapshot.timeSigEvents.filter { Double($0.bar) > startBar && Double($0.bar) < endBar }
        var total = 0
        var cur   = startBar
        for ev in changes {
            total += Int(round((Double(ev.bar) - cur) * Double(beatsPerBarAt(bar: cur))))
            cur    = Double(ev.bar)
        }
        total += Int(round((endBar - cur) * Double(beatsPerBarAt(bar: cur))))
        return total
    }

    // ── 코드 beat-snap 헬퍼 ──────────────────────────────

    private func chordsInSection(name: String) -> [ChordEvent] {
        guard let bounds = sectionBounds(name: name) else { return [] }
        let bpb = Double(max(1, snapshot.beatsPerBar))
        return snapshot.chords.filter { ch in
            let bar = Double(ch.bar) + Double(ch.beat - 1) / bpb
            return bar >= bounds.start && bar < bounds.end
        }
    }

    private func chordsInCurrentSection() -> [ChordEvent] {
        chordsInSection(name: currentSectionName)
    }

    private func chordBarFloat(_ ch: ChordEvent) -> Double {
        Double(ch.bar) + Double(ch.beat - 1) / Double(max(1, snapshot.beatsPerBar))
    }

    private func recalcNextChord() {
        let chords = chordsInCurrentSection()
        guard !chords.isEmpty else { currentChordIdx = -1; nextChordMTC = 0; return }

        // 처음 진입 시 현재 위치에서 코드 인덱스 계산
        if currentChordIdx == -1 {
            currentChordIdx = chords.indices.last(where: { i in
                chordBarFloat(chords[i]) <= anchorBar + 0.1
            }) ?? 0
        }

        // 다음 코드 MTC 예측
        let nextIdx = currentChordIdx + 1
        guard nextIdx < chords.count else { nextChordMTC = 0; return }
        let nextBar  = chordBarFloat(chords[nextIdx])
        let barsLeft = nextBar - anchorBar
        let secsLeft = barsLeft * Double(snapshot.beatsPerBar) * beatDuration()
        nextChordMTC = anchorMTC + secsLeft
    }

    // MTC 경과 시간으로 보간한 현재 bar 위치
    private func realtimeBar() -> Double {
        guard anchorMTC > 0 else { return anchorBar }
        let elapsed = mtcTime - anchorMTC
        guard elapsed >= 0, elapsed < 5 else { return anchorBar }
        return anchorBar + elapsed / beatDuration() / Double(max(1, snapshot.beatsPerBar))
    }

    // MARK: - 계산 & 브로드캐스트

    private func recompute() {
        let state = compute()
        guard state != lastState else { return }
        lastState = state
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastBroadcast >= minInterval else { return }
        lastBroadcast = now
        onStateChange?(state)
    }

    private func compute() -> IndicatorState {
        var state   = IndicatorState()
        let markers = snapshot.markers
        guard !markers.isEmpty else { return state }

        let songMarkers = markers.filter { $0.isSong }
        state.songs = songMarkers.map { $0.displayName }

        let inSong  = markersInCurrentSong()
        guard !inSong.isEmpty else { return state }

        let currentSong = songMarkers.last { markerBarFloat($0) <= anchorBar + 0.5 }
        state.currentSongIndex = currentSong.flatMap { songMarkers.firstIndex(of: $0) } ?? -1

        let sections = inSong.filter { !$0.isSong }
        state.currentSongSections = sections.map { $0.displayName }

        guard let idx = inSong.firstIndex(where: { $0.displayName == currentSectionName }) else {
            return state
        }

        let cm = inSong[idx]
        let nm = idx + 1 < inSong.count ? inSong[idx + 1] : nil

        let songName = currentSong?.displayName ?? ""
        state.currentSection = cm.displayName
        state.nextSection    = nm?.displayName

        if let d = LyricsStore.shared.get(song: songName, section: cm.displayName) {
            state.lyricCue = d.lyricCue ?? ""
            state.note     = d.note     ?? ""
        }
        if let nm = nm, let d = LyricsStore.shared.get(song: songName, section: nm.displayName) {
            state.nextLyricCue = d.lyricCue ?? ""
            state.nextNote     = d.note     ?? ""
        }
        state.currentSectionIndexInSong = sections.firstIndex(of: cm) ?? -1

        // ── 진행률: MTC 있으면 MTC 기반, 없으면 AX 위치 기반 ──
        if sectionDurationSec > 0, let bounds = sectionBounds(name: currentSectionName) {
            let elapsed: Double
            if mtcIsPlaying {
                elapsed = mtcTime - sectionEntryMTC
            } else {
                elapsed = calcDuration(from: bounds.start, to: anchorBar)
            }
            state.sectionProgress   = min(1, max(0, elapsed / sectionDurationSec))
            state.sectionLengthBars = sectionDurationSec / (Double(snapshot.beatsPerBar) * beatDuration())
        }

        // ── 카운트다운: MIDI Clock beat 기반 (없으면 AX 위치로 근사) ──
        let threshold = countdownThresholdBars * max(1, snapshot.beatsPerBar)
        let displayBeats: Int
        if mtcIsPlaying {
            displayBeats = countdownBeats
        } else if let bounds = sectionBounds(name: currentSectionName) {
            displayBeats = calcBeats(from: anchorBar, to: bounds.end)
        } else {
            displayBeats = 0
        }
        state.countdownBars = (displayBeats > 0 && displayBeats <= threshold) ? displayBeats : 0

        // ── 코드: beat-snap으로 타이밍 고정 ──
        let sectionChords = chordsInCurrentSection()
        state.chords = sectionChords.map { $0.name }
        state.currentChordIndex = (currentChordIdx >= 0 && currentChordIdx < sectionChords.count)
            ? currentChordIdx : -1
        // 다음 섹션 코드 (현재 섹션 마지막 그룹에서 미리 보기용)
        if let nm = nm {
            state.nextSectionChords = chordsInSection(name: nm.displayName).map { $0.name }
        }

        state.isPlaying     = mtcIsPlaying
        state.bpm           = snapshot.bpm
        state.beatsPerBar   = snapshot.beatsPerBar
        state.timeSignature = snapshot.timeSignature
        state.key           = snapshot.key

        return state
    }
}
