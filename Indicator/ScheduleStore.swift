import Foundation
import CryptoKit

struct ScannedMarker: Codable, Equatable {
    let name: String
    let bar: Int
    let beat: Int
    let isSong: Bool
}

struct ScannedTimeSigEvent: Codable, Equatable {
    let bar: Int
    let beatsPerBar: Int
}

struct ScannedSchedule: Codable {
    var markers: [ScannedMarker]
    var bpm: Double
    var beatsPerBar: Int
    var timeSigEvents: [ScannedTimeSigEvent]
    var scannedAt: Date
    var fingerprint: String
}

class ScheduleStore {
    static let shared = ScheduleStore()

    private(set) var current: ScannedSchedule?

    private var saveURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = dir.appendingPathComponent("Indicator")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("schedule.json")
    }

    init() {
        loadFromDisk()
    }

    // MARK: - Scan

    func scan(markers: [Marker], bpm: Double, beatsPerBar: Int, timeSigEvents: [TimeSigEvent]) {
        let scanned = markers.map { ScannedMarker(name: $0.name, bar: $0.bar, beat: $0.beat, isSong: $0.isSong) }
        let scannedTS = timeSigEvents.map { ScannedTimeSigEvent(bar: $0.bar, beatsPerBar: $0.beatsPerBar) }
        current = ScannedSchedule(markers: scanned, bpm: bpm, beatsPerBar: beatsPerBar, timeSigEvents: scannedTS,
                                   scannedAt: Date(), fingerprint: Self.fingerprint(scanned))
        saveToDisk()
    }

    func clear() {
        current = nil
        if let url = saveURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Validate

    // 마커 목록(이름·bar·beat) + 템포·박자가 라이브 상태와 정확히 일치해야 신뢰됨
    // (마디↔시간 환산이 템포/박자에 의존하므로 마커만 맞고 템포가 다르면 위험)
    func isValid(against liveMarkers: [Marker], bpm: Double, beatsPerBar: Int, timeSigEvents: [TimeSigEvent]) -> Bool {
        guard let s = current else { return false }
        let liveScanned = liveMarkers.map { ScannedMarker(name: $0.name, bar: $0.bar, beat: $0.beat, isSong: $0.isSong) }
        guard Self.fingerprint(liveScanned) == s.fingerprint else { return false }
        guard abs(bpm - s.bpm) < 0.01, beatsPerBar == s.beatsPerBar else { return false }
        let liveTS = timeSigEvents.map { ScannedTimeSigEvent(bar: $0.bar, beatsPerBar: $0.beatsPerBar) }
        return liveTS == s.timeSigEvents
    }

    // MARK: - Persistence

    private func saveToDisk() {
        guard let url = saveURL, let current else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(current) else { return }
        try? data.write(to: url)
    }

    private func loadFromDisk() {
        guard let url = saveURL,
              let raw = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        current = try? decoder.decode(ScannedSchedule.self, from: raw)
    }

    // MARK: - Helper

    private static func fingerprint(_ markers: [ScannedMarker]) -> String {
        let joined = markers.map { "\($0.name)@\($0.bar).\($0.beat)" }.joined(separator: "|")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
