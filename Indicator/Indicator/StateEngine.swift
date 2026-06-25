import Foundation

// Combines LogicSnapshot + MTC time → IndicatorState
// All methods called on main thread.
class StateEngine {

    var onStateChange: ((IndicatorState) -> Void)?

    // How many whole bars before a transition to show the countdown
    var countdownThresholdBars: Int {
        get { SettingsStore.shared.countdownBars }
    }

    private var snapshot  = LogicSnapshot()
    private var mtcTime: TimeInterval = 0
    private var lastState = IndicatorState()
    private var lastBroadcast: TimeInterval = 0
    private let minBroadcastInterval: TimeInterval = 0.05  // max 20fps to browser
    private var lastCountdown: Int? = nil          // only allow countdown to decrease

    // MARK: - Input

    func update(snapshot: LogicSnapshot) {
        var s = snapshot
        s.capturedMTCTime = mtcTime
        self.snapshot = s
        recompute()
    }

    func updateMTC(time: TimeInterval) {
        mtcTime = time
        recompute()
    }

    // MARK: - Computation

    private func recompute() {
        let state = compute()
        guard state != lastState else { return }
        lastState = state
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastBroadcast >= minBroadcastInterval else { return }
        lastBroadcast = now
        onStateChange?(state)
    }

    private func compute() -> IndicatorState {
        var state = IndicatorState()
        let markers = snapshot.markers
        guard !markers.isEmpty else { return state }

        // Current position in fractional bars (1-based, anchored from transport poll)
        let currentBarFloat = interpolatedBar()

        // Split markers into song markers (#) and section markers
        // Build setlist from song markers
        let songMarkers = markers.filter { $0.isSong }
        state.songs = songMarkers.map { $0.displayName }

        // Find current song marker (last song marker at or before currentBar)
        let currentSongMarker = songMarkers.last { markerBarFloat($0) <= currentBarFloat + 0.5 }
        state.currentSongIndex = currentSongMarker.flatMap { sm in songMarkers.firstIndex(of: sm) } ?? -1

        // Collect section markers for current song
        // Sections = markers between current song marker and next song marker (exclusive)
        let currentSongSections: [Marker]
        if let sm = currentSongMarker {
            let smIdx = markers.firstIndex(of: sm)!
            let nextSongIdx = markers.indices.first { i in
                i > smIdx && markers[i].isSong
            }
            let endIdx = nextSongIdx ?? markers.endIndex
            currentSongSections = Array(markers[(smIdx+1)..<endIdx])
        } else {
            currentSongSections = []
        }
        state.currentSongSections = currentSongSections.map { $0.displayName }

        // All markers relevant to current position (song marker + its sections)
        // Current section = last marker (any kind) at or before currentBar
        let allCurrentSongMarkers: [Marker]
        if let sm = currentSongMarker {
            let smIdx = markers.firstIndex(of: sm)!
            let nextSongIdx = markers.indices.first { i in i > smIdx && markers[i].isSong }
            let endIdx = nextSongIdx ?? markers.endIndex
            allCurrentSongMarkers = Array(markers[smIdx..<endIdx])
        } else {
            allCurrentSongMarkers = []
        }

        let currentMarker = allCurrentSongMarkers.last { markerBarFloat($0) <= currentBarFloat + 0.1 }
        let nextMarker    = allCurrentSongMarkers.first { markerBarFloat($0) > currentBarFloat + 0.1 }

        // Current section display
        state.currentSection = currentMarker?.displayName ?? "--"
        state.nextSection    = nextMarker?.displayName

        // Which section index within current song's section list
        if let cm = currentMarker {
            state.currentSectionIndexInSong = currentSongSections.firstIndex(of: cm) ?? -1
        }

        // Progress within current section (0–1)
        if let cm = currentMarker, let nm = nextMarker {
            let start = markerBarFloat(cm)
            let end   = markerBarFloat(nm)
            let span  = end - start
            state.sectionProgress    = span > 0 ? min(1, max(0, (currentBarFloat - start) / span)) : 0
            state.sectionLengthBars  = span
        } else {
            state.sectionProgress   = 0
            state.sectionLengthBars = 0
        }

        // Countdown: show beat count (4→3→2→1) during the last N bars before next marker
        if let nm = nextMarker {
            let barsLeft = markerBarFloat(nm) - currentBarFloat
            let threshold = Double(countdownThresholdBars)
            if barsLeft <= threshold && barsLeft > 0 {
                let beatsLeft = barsLeft * Double(snapshot.beatsPerBar)
                let raw = max(1, Int(ceil(beatsLeft - 0.55)))
                // Only allow countdown to decrease — prevents flickering at beat boundaries
                if let prev = lastCountdown {
                    state.countdownBars = min(prev, raw)
                } else {
                    state.countdownBars = raw
                }
                lastCountdown = state.countdownBars
            } else {
                lastCountdown = nil
            }
        } else {
            lastCountdown = nil
        }

        state.isPlaying  = mtcTime > 0
        state.bpm        = snapshot.bpm
        state.beatsPerBar = snapshot.beatsPerBar

        return state
    }

    // MARK: - Bar position helpers

    // Interpolated bar position using MTC time delta since last transport poll
    private func interpolatedBar() -> Double {
        let anchorBar  = Double(snapshot.transportBar) + Double(snapshot.transportBeat - 1) / Double(snapshot.beatsPerBar)
        let secsSince  = mtcTime - snapshot.capturedMTCTime
        // Only interpolate forward up to a reasonable amount (5 bars max to avoid drift errors)
        guard secsSince > 0, secsSince < 30 else { return anchorBar }
        let beatsPerSec = snapshot.bpm / 60.0
        let barsElapsed = beatsPerSec * secsSince / Double(snapshot.beatsPerBar)
        return anchorBar + barsElapsed
    }

    private func markerBarFloat(_ m: Marker) -> Double {
        Double(m.bar) + Double(m.beat - 1) / Double(snapshot.beatsPerBar)
    }
}
