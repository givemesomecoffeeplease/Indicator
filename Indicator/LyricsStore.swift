import Foundation

class LyricsStore {
    static let shared = LyricsStore()

    private var data: [String: [String: SectionData]] = [:]

    private var autoSaveURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = dir.appendingPathComponent("Indicator")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("master.json")
    }

    init() {
        loadFromDisk()
    }

    // MARK: - Query

    // 하위호환: occurrence 구분 없는 옛 조회 (legacy flat key)
    func get(song: String, section: String) -> SectionData? {
        data[song]?[section]
    }

    func songNames() -> [String] {
        Array(data.keys).sorted()
    }

    // MARK: - Occurrence 기반 조회 (섹션 동일 이름 여러 occurrence 독립/연결 지원)

    private func occKey(_ section: String, _ startBar: Int) -> String { "\(section)@@\(startBar)" }

    /// 특정 occurrence의 데이터를 해석한다.
    /// - linked==true인 occurrence는 canonicalStartBar(같은 이름의 가장 이른 occurrence)의 데이터를 따라간다.
    /// - 명시적 occurrence 데이터가 없으면: 첫 occurrence는 레거시(이름만) 데이터로, 나머지는 자동으로 첫 occurrence를 따라간다(linked=true).
    /// - 반환값의 `linked`는 드롭박스 UI에 표시할 "현재 설정 상태"이다.
    // 노트(sessionNote/singerNote)는 가사/코드 연결 여부와 무관하게 항상 occurrence 자기 자신의 값만 사용한다.
    func resolve(song: String, section: String, startBar: Int, canonicalStartBar: Int) -> (data: SectionData, linked: Bool) {
        let key = occKey(section, startBar)
        if let exact = data[song]?[key] {
            if exact.linked {
                var canonicalData = data[song]?[occKey(section, canonicalStartBar)] ?? data[song]?[section] ?? SectionData()
                canonicalData.sessionNote = exact.sessionNote
                canonicalData.singerNote  = exact.singerNote
                return (canonicalData, true)
            }
            return (exact, false)
        }
        if startBar == canonicalStartBar {
            return (data[song]?[section] ?? SectionData(), false)
        } else {
            var canonicalData = data[song]?[occKey(section, canonicalStartBar)] ?? data[song]?[section] ?? SectionData()
            canonicalData.sessionNote = ""
            canonicalData.singerNote  = ""
            return (canonicalData, true)
        }
    }

    // MARK: - Write

    func merge(_ dict: [String: [String: SectionData]]) {
        for (song, sections) in dict {
            if data[song] == nil { data[song] = [:] }
            for (sec, val) in sections {
                data[song]?[sec] = val
            }
        }
        saveToDisk()
    }

    // MARK: - Export

    // 전체 (master.json)
    func exportAll() -> Data? {
        encode(data)
    }

    // 현재 세트리스트 곡만
    func exportSetlist(markers: [Marker]) -> Data? {
        var result: [String: [String: SectionData]] = [:]
        var currentSong: String? = nil
        for marker in markers {
            if marker.isSong {
                currentSong = marker.displayName
                result[marker.displayName] = data[marker.displayName] ?? [:]
            } else if let song = currentSong {
                let val = data[song]?[marker.displayName] ?? SectionData(lyricCue: "", note: "")
                result[song]?[marker.displayName] = val
            }
        }
        return encode(result)
    }

    // 곡 하나만
    func exportSong(name: String) -> Data? {
        guard let sections = data[name] else { return nil }
        return encode([name: sections])
    }

    // 리더용 빈 템플릿 (현재 마커 기준)
    func exportTemplate(markers: [Marker]) -> Data? {
        var template: [String: [String: SectionData]] = [:]
        var currentSong: String? = nil
        for marker in markers {
            if marker.isSong {
                currentSong = marker.displayName
                template[marker.displayName] = [:]
            } else if let song = currentSong {
                let existing = data[song]?[marker.displayName]
                template[song]?[marker.displayName] = existing ?? SectionData(lyricCue: "", note: "")
            }
        }
        return encode(template)
    }

    // MARK: - Import

    @discardableResult
    func importJSON(from url: URL) -> Bool {
        guard let raw = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String: SectionData]].self, from: raw)
        else { return false }
        merge(decoded)
        return true
    }

    // MARK: - Auto save/load

    private func saveToDisk() {
        guard let url = autoSaveURL, let data = exportAll() else { return }
        try? data.write(to: url)
    }

    private func loadFromDisk() {
        guard let url = autoSaveURL,
              let raw = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String: SectionData]].self, from: raw)
        else { return }
        data = decoded
    }

    // MARK: - Helper

    private func encode(_ val: [String: [String: SectionData]]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(val)
    }
}
