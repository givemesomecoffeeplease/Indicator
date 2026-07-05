import Foundation
import CryptoKit

struct ScannedMarker: Codable, Equatable {
    let name: String
    let isSong: Bool
    let mtcSeconds: Double
    var barHint: Int = 0
}

struct ScannedTempo: Codable, Equatable {
    let bpm: Double
    let mtcSeconds: Double
    let barPosition: Double
}

struct ScannedTimeSig: Codable, Equatable {
    let numerator: Int
    let denominator: Int
    let mtcSeconds: Double
    // StateEngine 호환용
    var beatsPerBar: Int { numerator }
    var beatUnit: Int { denominator }
}

struct ScannedKeySig: Codable, Equatable {
    let name: String
    let mtcSeconds: Double
}

struct ScannedSchedule: Codable {
    var markers: [ScannedMarker]
    var tempos: [ScannedTempo]
    var timeSigs: [ScannedTimeSig]
    var keySigs: [ScannedKeySig]
    var scannedAt: Date
}

class ScheduleStore {
    static let shared = ScheduleStore()

    private(set) var current: ScannedSchedule?

    var onSaved: ((ScannedSchedule) -> Void)?

    private var saveURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = dir.appendingPathComponent("Indicator")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("schedule_v2.json")
    }

    init() { loadFromDisk() }

    // MARK: - Save (LogicPoller 호출)

    func save(schedule: ScannedSchedule) {
        current = schedule
        saveToDisk()
        onSaved?(schedule)
    }

    // MARK: - Query (StateEngine 호출)

    func bpmAt(mtcSeconds: Double) -> Double? {
        guard let tempos = current?.tempos, !tempos.isEmpty else { return nil }
        let t = tempos.last(where: { $0.mtcSeconds <= mtcSeconds }) ?? tempos[0]
        return t.bpm
    }

    /// 특정 SMPTE 시간이 몇 번째 마디인지 계산 (소수점 포함)
    /// 가장 가까운 템포 변화 지점의 마디 위치 + 그 이후 경과 시간으로 계산
    func barPositionAt(mtcSeconds: Double) -> Double? {
        guard let tempos = current?.tempos, !tempos.isEmpty else { return nil }
        let t = tempos.last(where: { $0.mtcSeconds <= mtcSeconds }) ?? tempos[0]
        let bpb = Double(beatsPerBarAt(mtcSeconds: mtcSeconds)?.beatsPerBar ?? 4)
        let barsElapsed = (mtcSeconds - t.mtcSeconds) * t.bpm / 60.0 / bpb
        return t.barPosition + barsElapsed
    }

    /// 두 SMPTE 시간 사이의 마디 수 (정수)
    func barsBetween(startMTC: Double, endMTC: Double) -> Int? {
        guard let startBar = barPositionAt(mtcSeconds: startMTC),
              let endBar = barPositionAt(mtcSeconds: endMTC) else { return nil }
        return max(0, Int(endBar - startBar))
    }

    func beatsPerBarAt(mtcSeconds: Double) -> (beatsPerBar: Int, beatUnit: Int)? {
        guard let timeSigs = current?.timeSigs, !timeSigs.isEmpty else { return nil }
        let ts = timeSigs.last(where: { $0.mtcSeconds <= mtcSeconds }) ?? timeSigs[0]
        return (ts.beatsPerBar, ts.beatUnit)
    }

    func clear() {
        current = nil
        if let url = saveURL { try? FileManager.default.removeItem(at: url) }
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
}
