import Foundation

// ── 가사+코드 토큰 ──────────────────────────────────────────
struct LyricToken: Codable, Equatable {
    enum TokenType: String, Codable {
        case char, ghost, br
        // 미래에 새 타입이 추가돼도 파싱 실패 방지
        init(from decoder: Decoder) throws {
            let s = try decoder.singleValueContainer().decode(String.self)
            self = TokenType(rawValue: s) ?? .char
        }
    }
    var type: TokenType
    var char: String?
    var chord: String?

    enum CodingKeys: String, CodingKey { case type, char, chord }
    init(type: TokenType = .char, char: String? = nil, chord: String? = nil) {
        self.type = type; self.char = char; self.chord = chord
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type  = (try? c.decode(TokenType.self, forKey: .type)) ?? .char
        char  = try? c.decode(String.self, forKey: .char)
        chord = try? c.decode(String.self, forKey: .chord)
    }
}

struct InstChordSlot: Codable, Equatable {
    var pos: Int
    var name: String

    enum CodingKeys: String, CodingKey { case pos, name }
    init(pos: Int = 0, name: String = "") { self.pos = pos; self.name = name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pos  = (try? c.decode(Int.self,    forKey: .pos))  ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
    }
}

struct LyricSlide: Codable, Equatable {
    var startBar: Int
    var barCount: Int
    var isInstrumental: Bool
    var tokens: [LyricToken]
    var instChords: [[InstChordSlot]]  // 마디별 간주 코드 슬롯
    var singerNote: String

    enum CodingKeys: String, CodingKey { case startBar, barCount, isInstrumental, tokens, instChords, singerNote }
    init(startBar: Int = 0, barCount: Int = 0, isInstrumental: Bool = false, tokens: [LyricToken] = [], instChords: [[InstChordSlot]] = [], singerNote: String = "") {
        self.startBar = startBar; self.barCount = barCount; self.isInstrumental = isInstrumental
        self.tokens = tokens; self.instChords = instChords; self.singerNote = singerNote
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startBar        = (try? c.decode(Int.self,              forKey: .startBar))        ?? 0
        barCount        = (try? c.decode(Int.self,              forKey: .barCount))        ?? 0
        isInstrumental  = (try? c.decode(Bool.self,             forKey: .isInstrumental))  ?? false
        tokens          = (try? c.decode([LyricToken].self,     forKey: .tokens))          ?? []
        instChords      = (try? c.decode([[InstChordSlot]].self, forKey: .instChords))     ?? []
        singerNote      = (try? c.decode(String.self,           forKey: .singerNote))      ?? ""
    }
}

struct SectionData: Codable {
    var lyricCue: String
    var note: String
    var sessionNote: String
    var singerNote: String
    var slides: [LyricSlide]
    var linked: Bool   // true면 같은 이름의 가장 이른 독립(linked==false) occurrence를 동적으로 따라감

    init(lyricCue: String = "", note: String = "", sessionNote: String = "", singerNote: String = "", slides: [LyricSlide] = [], linked: Bool = false) {
        self.lyricCue = lyricCue
        self.note = note
        self.sessionNote = sessionNote
        self.singerNote = singerNote
        self.slides = slides
        self.linked = linked
    }

    // 하위 호환: 기존 필드 없으면 기본값
    enum CodingKeys: String, CodingKey { case lyricCue, note, sessionNote, singerNote, slides, linked }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lyricCue    = (try? c.decode(String.self, forKey: .lyricCue))    ?? ""
        note        = (try? c.decode(String.self, forKey: .note))        ?? ""
        sessionNote = (try? c.decode(String.self, forKey: .sessionNote)) ?? ""
        singerNote  = (try? c.decode(String.self, forKey: .singerNote))  ?? ""
        slides      = (try? c.decode([LyricSlide].self, forKey: .slides)) ?? []
        linked      = (try? c.decode(Bool.self, forKey: .linked))        ?? false
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
    let mtcSeconds: Double  // 마커 절대 위치 (MTC 타임코드 → 초)
    let bar: Int            // Logic 마디 번호 (변박 조회용)

    var isSong: Bool { name.hasPrefix("#") }
    var displayName: String { isSong ? String(name.dropFirst()) : name }
}

struct LogicSnapshot {
    var markers: [Marker] = []
    var chords: [ChordEvent] = []
    var timeSigEvents: [TimeSigEvent] = []   // 조표 및 박자표 목록에서 읽어온 박자 변경 이벤트
    var transportBar: Int = 1
    var transportBeat: Int = 1
    var transportMTC: Double = 0   // AX 타임코드 디스플레이 (정지 상태에서도 읽힘)
    var bpm: Double = 120.0
    var beatsPerBar: Int = 4
    var timeSignature: String = "4/4"
    var key: String = ""
    var capturedMTCTime: TimeInterval = 0
}

// 싱어/밴드뷰에 전달하는 슬라이드 단위 정보
struct SlideInfo: Codable, Equatable {
    var tokens: [LyricToken]
    var isInstrumental: Bool
    var instChords: [[InstChordSlot]]
    var barCount: Int
    var singerNote: String
    var sectionName: String
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
    var singerNote: String = ""
    var nextLyricCue: String = ""
    var nextNote: String = ""
    var nextSingerNote: String = ""
    var nextSectionIsSong: Bool = false
    var currentBarFloat: Double = 0
    var nextChordInMs: Double = 0
    var broadcastTimestampMs: Double = 0
    // 싱어 뷰
    var currentSlideTokens: [LyricToken] = []
    var nextSlideTokens: [LyricToken] = []
    var currentSlideInfo: SlideInfo? = nil
    var nextSlideInfo: SlideInfo? = nil
    var nextSongName: String = ""
    var nextSongKey: String = ""
    var chords: [String] = []
    var chordBars: [Int] = []
    var chordBeats: [Int] = []
    var currentChordIndex: Int = -1
    var nextSectionChords: [String] = []
    var nextSectionChordBars: [Int] = []
}
