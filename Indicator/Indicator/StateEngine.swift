import Foundation

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

    // ── 현재 섹션 상태 ─────────────────────────────────────
    private var currentSectionName: String = ""
    private var sectionEntryMTC: TimeInterval = 0   // 이 섹션 시작 시점의 MTC
    private var sectionDurationSec: Double = 0       // 이 섹션 총 길이(초)

    // ── 다음 섹션 전환 예측 ───────────────────────────────
    private var transitionMTC: TimeInterval = 0      // 전환이 일어날 예상 MTC

    // ── 카운트다운 ─────────────────────────────────────────
    private var countdownBeats: Int = 0              // 남은 박자 수

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

        // 어느 섹션인지 감지
        let detected = detectSectionName(at: anchorBar)

        if detected != currentSectionName {
            // AX가 섹션 변경을 감지했을 때만 업데이트
            // 단, MIDI Clock이 이미 앞으로 전환한 경우 되돌리지 않음
            let detectedStart = sectionBounds(name: detected)?.start ?? 0
            let currentStart  = sectionBounds(name: currentSectionName)?.start ?? -1

            if detectedStart >= currentStart {
                applySection(name: detected, retroactive: true)
            }
        } else {
            // 같은 섹션이면 전환 예측 시간만 재보정
            recalcTransition()
        }

        recompute()
    }

    // MARK: - MTC 업데이트 (10ms)

    func updateMTC(time: TimeInterval) {
        // 점프 감지 (되감기 / 재생헤드 이동)
        if mtcIsPlaying && abs(time - prevMTCTime) > 0.5 {
            currentSectionName = ""
            transitionMTC      = 0
        }
        prevMTCTime  = mtcTime
        mtcTime      = time
        mtcIsPlaying = true

        recompute()
    }

    func mtcStopped() {
        mtcIsPlaying   = false
        transitionMTC  = 0
        countdownBeats = 0
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

        if countdownBeats > 1 {
            countdownBeats -= 1
        } else if countdownBeats == 1 {
            countdownBeats = 0
            executeTransition()
        }
        recompute()
    }

    // MARK: - 섹션 적용

    // retroactive: AX가 이미 섹션 중간에서 감지한 경우 → sectionEntryMTC를 역산
    private func applySection(name: String, retroactive: Bool) {
        guard let (startBar, endBar) = sectionBounds(name: name) else { return }

        currentSectionName = name

        let totalBars      = endBar - startBar
        sectionDurationSec = totalBars * Double(snapshot.beatsPerBar) * beatDuration()

        if retroactive {
            // 지금 위치가 섹션 시작에서 얼마나 지났는지 역산
            let barsElapsed  = anchorBar - startBar
            let secElapsed   = max(0, barsElapsed * Double(snapshot.beatsPerBar) * beatDuration())
            sectionEntryMTC  = anchorMTC - secElapsed

            let barsLeft     = endBar - anchorBar
            countdownBeats   = max(0, Int(round(barsLeft * Double(snapshot.beatsPerBar))))
        } else {
            // 전환 직후 — 지금이 섹션 시작
            sectionEntryMTC = mtcTime
            countdownBeats  = Int(round(totalBars * Double(snapshot.beatsPerBar)))
        }

        recalcTransition()
    }

    // MARK: - 전환 예측 재계산

    private func recalcTransition() {
        let markers = markersInCurrentSong()
        guard let idx = markers.firstIndex(where: { $0.displayName == currentSectionName }),
              idx + 1 < markers.count else {
            transitionMTC = 0
            return
        }
        let nextBar  = markerBarFloat(markers[idx + 1])
        let barsLeft = nextBar - anchorBar
        let secLeft  = barsLeft * Double(snapshot.beatsPerBar) * beatDuration()
        transitionMTC = anchorMTC + secLeft
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
        let all  = snapshot.markers
        let songs = all.filter { $0.isSong }
        guard let song = songs.last(where: { markerBarFloat($0) <= anchorBar + 0.5 }),
              let si   = all.firstIndex(of: song) else { return [] }
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

        // ── 진행률: MTC 경과 시간 기반 (부드러움 보장) ──
        if sectionDurationSec > 0 && sectionEntryMTC > 0 {
            let elapsed = mtcTime - sectionEntryMTC
            state.sectionProgress   = min(1, max(0, elapsed / sectionDurationSec))
            state.sectionLengthBars = sectionDurationSec / (Double(snapshot.beatsPerBar) * beatDuration())
        }

        // ── 카운트다운: MIDI Clock beat 기반, 임계값 내에서만 표시 ──
        let threshold = countdownThresholdBars * max(1, snapshot.beatsPerBar)
        state.countdownBars = (countdownBeats > 0 && countdownBeats <= threshold) ? countdownBeats : 0

        state.isPlaying     = mtcIsPlaying
        state.bpm           = snapshot.bpm
        state.beatsPerBar   = snapshot.beatsPerBar
        state.timeSignature = snapshot.timeSignature
        state.key           = snapshot.key

        return state
    }
}
