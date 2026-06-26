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

    func get(song: String, section: String) -> SectionData? {
        data[song]?[section]
    }

    func songNames() -> [String] {
        Array(data.keys).sorted()
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
