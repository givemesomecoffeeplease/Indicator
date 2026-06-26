import Foundation

struct SectionData: Codable {
    var lyricCue: String
    var note: String
}

struct TimeSigEvent {
    let bar: Int        // 변경 시작 마디
    let beatsPerBar: Int  // 분자 (3, 4, 5, 6 …)
    let beatUnit: Int     // 분모 (4, 8 …)
}

struct ChordEvent {
    let name: String  // formatted, e.g. "Am7", "G/B"
    let bar: Int
    let beat: Int
}

struct Marker: Equatable {
    let name: String
    let bar: Int
    let beat: Int

    var isSong: Bool { name.hasPrefix("#") }
    var displayName: String { isSong ? String(name.dropFirst()) : name }
}

struct LogicSnapshot {
    var markers: [Marker] = []
    var chords: [ChordEvent] = []
    var timeSigEvents: [TimeSigEvent] = []   // 조표 및 박자표 목록에서 읽어온 박자 변경 이벤트
    var transportBar: Int = 1
    var transportBeat: Int = 1
    var bpm: Double = 120.0
    var beatsPerBar: Int = 4
    var timeSignature: String = "4/4"
    var key: String = ""
    var capturedMTCTime: TimeInterval = 0
}

struct IndicatorState: Codable, Equatable {
    var songs: [String] = []
    var currentSongIndex: Int = -1
    var currentSection: String = "--"
    var nextSection: String? = nil
    var sectionProgress: Double = 0
    var countdownBars: Int? = nil
    var currentSongSections: [String] = []
    var currentSectionIndexInSong: Int = -1
    var isPlaying: Bool = false
    var bpm: Double = 120.0
    var beatsPerBar: Int = 4
    var timeSignature: String = "4/4"
    var key: String = ""
    var sectionLengthBars: Double = 0
    var lyricCue: String = ""
    var note: String = ""
    var nextLyricCue: String = ""
    var nextNote: String = ""
    var chords: [String] = []
    var currentChordIndex: Int = -1
    var nextSectionChords: [String] = []
}
