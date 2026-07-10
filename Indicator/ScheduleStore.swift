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
    var fps: Double = 25.0   // 스캔 당시 SMPTE 프레임레이트 (MTC 수신 fps와 불일치 시 재스캔 필요)
}

// 프로젝트 SMPTE 프레임레이트 공유 상태
// MTC 수신부가 rateCode를 디코딩해 갱신하고, 스캔 파서(parseMTC)가 읽어 사용
enum SMPTEConfig {
    static var fps: Double = 25.0
}

class ScheduleStore {
    static let shared = ScheduleStore()

    private(set) var current: ScannedSchedule?

    var onSaved: ((ScannedSchedule) -> Void)?

    // 디스크 영속화: 앱 재시작 후에도 (목록 창이 닫혀 있어도) 스캔 데이터 유지
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

    private func saveToDisk() {
        guard let url = saveURL, let current else { return }
        let encoder = JSONEncoder()
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
        return max(0, Int((endBar - startBar).rounded()))
    }

    func beatsPerBarAt(mtcSeconds: Double) -> (beatsPerBar: Int, beatUnit: Int)? {
        guard let timeSigs = current?.timeSigs, !timeSigs.isEmpty else { return nil }
        let ts = timeSigs.last(where: { $0.mtcSeconds <= mtcSeconds }) ?? timeSigs[0]
        return (ts.beatsPerBar, ts.beatUnit)
    }

    /// 카운트다운 박 단위 MTC 배열 (스캔된 템포맵 기준 진짜 박 그리드)
    /// 섹션 끝에서부터 한 박씩 거슬러 올라가며 그 시점의 실제 bpm으로 박 길이 계산 (변박 대응)
    /// 반환값: MTC 오름차순. beat = 남은 박 수 (예: 8→1).
    func countdownBeatMTCs(sectionEndMTC: Double, barsBack: Int) -> [(beat: Int, mtc: Double)] {
        // 박자표는 섹션 끝 직전 기준 (끝 경계에 다음 섹션 변박이 걸려있을 수 있음)
        guard barsBack > 0, let ts = beatsPerBarAt(mtcSeconds: sectionEndMTC - 0.01) else { return [] }
        let totalBeats = barsBack * ts.beatsPerBar
        var t = sectionEndMTC
        var result: [(beat: Int, mtc: Double)] = []
        for i in 1...totalBeats {
            let bpm = bpmAt(mtcSeconds: t - 0.01) ?? 120
            t -= 60.0 / bpm
            result.append((beat: i, mtc: t))
        }
        return result.reversed()  // MTC 오름차순 (beat 큰 수부터)
    }

    func clear() {
        current = nil
        if let url = saveURL { try? FileManager.default.removeItem(at: url) }
    }
}
