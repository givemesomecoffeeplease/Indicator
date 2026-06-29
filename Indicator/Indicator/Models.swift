import Foundation

// ── 가사+코드 토큰 ──────────────────────────────────────────
struct LyricToken: Codable, Equatable {
    enum TokenType: String, Codable { case char, ghost, br }
    var type: TokenType
    var char: String?   // type==char 일 때 글자
    var chord: String?  // 이 토큰 위에 붙는 코드 (옵셔널)
}

struct InstChordSlot: Codable, Equatable {
    var pos: Int     // 8분음표 그리드 위치 (0…7)
    var name: String
}

struct LyricSlide: Codable, Equatable {
    var startBar: Int
    var barCount: Int
    var isInstrumental: Bool
    var tokens: [LyricToken]
    var instChords: [[InstChordSlot]]  // 마디별 간주 코드 슬롯
    var singerNote: String
}

struct SectionData: Codable {
    var lyricCue: String
    var note: String
    var sessionNote: String
    var singerNote: String
    var slides: [LyricSlide]

    init(lyricCue: String = "", note: String = "", sessionNote: String = "", singerNote: String = "", slides: [LyricSlide] = []) {
        self.lyricCue = lyricCue
        self.note = note
        self.sessionNote = sessionNote
        self.singerNote = singerNote
        self.slides = slides
    }

    // 하위 호환: 기존 필드 없으면 기본값
    enum CodingKeys: String, CodingKey { case lyricCue, note, sessionNote, singerNote, slides }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lyricCue    = (try? c.decode(String.self, forKey: .lyricCue))    ?? ""
        note        = (try? c.decode(String.self, forKey: .note))        ?? ""
        sessionNote = (try? c.decode(String.self, forKey: .sessionNote)) ?? ""
        singerNote  = (try? c.decode(String.self, forKey: .singerNote))  ?? ""
        slides      = (try? c.decode([LyricSlide].self, forKey: .slides)) ?? []
    }
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
    var nextSectionIsSong: Bool = false
    var currentBarFloat: Double = 0
    var nextChordInMs: Double = 0
    var broadcastTimestampMs: Double = 0
    // 싱어 뷰
    var currentSlideTokens: [LyricToken] = []
    var nextSlideTokens: [LyricToken] = []
    var nextSongName: String = ""
    var nextSongKey: String = ""
    var chords: [String] = []
    var chordBars: [Int] = []
    var chordBeats: [Int] = []
    var currentChordIndex: Int = -1
    var nextSectionChords: [String] = []
    var nextSectionChordBars: [Int] = []
}
