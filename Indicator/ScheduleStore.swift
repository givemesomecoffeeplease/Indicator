import Foundation
import CryptoKit

struct ScannedMarker: Codable, Equatable {
    let name: String
    let mtcSeconds: Double
    let isSong: Bool
}

struct ScannedTimeSig: Codable, Equatable {
    let mtcSeconds: Double
    let beatsPerBar: Int
    let beatUnit: Int
}

struct ScannedSchedule: Codable {
    var markers: [ScannedMarker]
    var timeSigs: [ScannedTimeSig]
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

    init() { loadFromDisk() }

    // MARK: - Scan

    func scan(markers: [Marker], timeSigEvents: [TimeSigEvent], anchorBar: Int, anchorMTC: Double, bpm: Double) {
        let scanned = markers.map { ScannedMarker(name: $0.name, mtcSeconds: $0.mtcSeconds, isSong: $0.isSong) }
        let scannedTimeSigs = convertTimeSigsToMTC(
            events: timeSigEvents,
            anchorBar: anchorBar,
            anchorMTC: anchorMTC,
            bpm: bpm
        )
        let fp = Self.fingerprint(scanned)
        current = ScannedSchedule(markers: scanned, timeSigs: scannedTimeSigs, scannedAt: Date(), fingerprint: fp)
        var log = "[Scan] anchorBar=\(anchorBar) anchorMTC=\(String(format:"%.2f",anchorMTC)) bpm=\(bpm)\n"
        for ts in scannedTimeSigs {
            log += "[Scan] timeSig \(ts.beatsPerBar)/\(ts.beatUnit) @ MTC=\(String(format:"%.2f",ts.mtcSeconds))s\n"
        }
        try? log.write(toFile: "/tmp/indicator_scan.log", atomically: true, encoding: .utf8)
        saveToDisk()
    }

    // MARK: - Validate

    func isValid(against liveMarkers: [Marker]) -> Bool {
        guard let s = current else { return false }
        let liveScanned = liveMarkers.map { ScannedMarker(name: $0.name, mtcSeconds: $0.mtcSeconds, isSong: $0.isSong) }
        return Self.fingerprint(liveScanned) == s.fingerprint
    }

    // MARK: - Query

    func beatsPerBarAt(mtcSeconds: Double) -> (beatsPerBar: Int, beatUnit: Int)? {
        guard let timeSigs = current?.timeSigs, !timeSigs.isEmpty else { return nil }
        let ts = timeSigs.last(where: { $0.mtcSeconds <= mtcSeconds }) ?? timeSigs[0]
        return (ts.beatsPerBar, ts.beatUnit)
    }

    func clear() {
        current = nil
        if let url = saveURL { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - bar→MTC 변환

    private func convertTimeSigsToMTC(
        events: [TimeSigEvent],
        anchorBar: Int,
        anchorMTC: Double,
        bpm: Double
    ) -> [ScannedTimeSig] {
        guard !events.isEmpty, bpm > 0 else { return [] }

        let sorted = events.sorted { $0.bar < $1.bar }

        func barDuration(_ bpb: Int, _ bu: Int) -> Double {
            Double(bpb) * (4.0 / Double(bu)) * (60.0 / bpm)
        }

        // 앵커가 속한 세그먼트 찾기
        let anchorIdx = sorted.indices.last(where: { sorted[$0].bar <= anchorBar }) ?? 0
        let anchorSeg = sorted[anchorIdx]

        // 앵커 세그먼트 시작 MTC 계산
        let barsFromSegStart = anchorBar - anchorSeg.bar
        let mtcAtAnchorSegStart = anchorMTC - Double(barsFromSegStart) * barDuration(anchorSeg.beatsPerBar, anchorSeg.beatUnit)

        // 각 이벤트의 MTC 계산
        var result: [ScannedTimeSig] = []

        // 앵커 세그먼트부터 앞으로
        var currentMTC = mtcAtAnchorSegStart
        for i in anchorIdx..<sorted.count {
            let ev = sorted[i]
            result.append(ScannedTimeSig(mtcSeconds: currentMTC, beatsPerBar: ev.beatsPerBar, beatUnit: ev.beatUnit))
            if i + 1 < sorted.count {
                let nextBar = sorted[i + 1].bar
                currentMTC += Double(nextBar - ev.bar) * barDuration(ev.beatsPerBar, ev.beatUnit)
            }
        }

        // 앵커 세그먼트 이전으로 (역방향)
        currentMTC = mtcAtAnchorSegStart
        for i in stride(from: anchorIdx - 1, through: 0, by: -1) {
            let ev = sorted[i]
            let nextBar = sorted[i + 1].bar
            currentMTC -= Double(nextBar - ev.bar) * barDuration(ev.beatsPerBar, ev.beatUnit)
            result.append(ScannedTimeSig(mtcSeconds: currentMTC, beatsPerBar: ev.beatsPerBar, beatUnit: ev.beatUnit))
        }

        return result.sorted { $0.mtcSeconds < $1.mtcSeconds }
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
        guard let url = saveURL, let raw = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        current = try? decoder.decode(ScannedSchedule.self, from: raw)
    }

    // MARK: - Helper

    private static func fingerprint(_ markers: [ScannedMarker]) -> String {
        let joined = markers.map { "\($0.name)@\($0.mtcSeconds)" }.joined(separator: "|")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
