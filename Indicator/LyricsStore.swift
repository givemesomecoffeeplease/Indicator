import Foundation

class LyricsStore {
    static let shared = LyricsStore()

    private var data: [String: [String: SectionData]] = [:]

    init() {}

    // MARK: - Query

    // 하위호환: occurrence 구분 없는 옛 조회 (legacy flat key)
    func get(song: String, section: String) -> SectionData? {
        data[song]?[section]
    }

    func songNames() -> [String] {
        Array(data.keys).sorted()
    }

    // MARK: - Occurrence 기반 조회 (섹션 동일 이름 여러 occurrence 독립/연결 지원)

    private func occKey(_ section: String, _ occIdx: Int) -> String { "\(section)@@\(occIdx)" }

    /// 특정 occurrence의 데이터를 해석한다.
    /// - occIdx: 곡 내에서 같은 이름 섹션의 등장 순서 (0-based)
    /// - linked==true이면 occIdx=0(캐노니컬)의 슬라이드를 따라감. 노트는 항상 자기 occurrence 값 사용.
    func resolve(song: String, section: String, occIdx: Int) -> (data: SectionData, linked: Bool) {
        let key = occKey(section, occIdx)
        if let exact = data[song]?[key] {
            if exact.linked {
                var canonicalData = data[song]?[occKey(section, 0)] ?? data[song]?[section] ?? SectionData()
                canonicalData.sessionNote = exact.sessionNote
                canonicalData.singerNote  = exact.singerNote
                return (canonicalData, true)
            }
            return (exact, false)
        }
        if occIdx == 0 {
            return (data[song]?[section] ?? SectionData(), false)
        } else {
            var canonicalData = data[song]?[occKey(section, 0)] ?? data[song]?[section] ?? SectionData()
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

    // MARK: - Helper

    private func encode(_ val: [String: [String: SectionData]]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(val)
    }
}
