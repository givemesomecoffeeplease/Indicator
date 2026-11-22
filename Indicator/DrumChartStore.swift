import Foundation

// LyricsStore와 같은 패턴 — 인메모리 저장, /edit(가사 편집기)의 곡별 "드럼 채보" 업로드로 채워진다.
// 채보(/chart)가 곡의 어느 마디에 대응하는지는 별도 오프셋 없이, "채보 1마디 = 그 곡의 #Song
// 마커 시작 마디"로 항상 고정한다(사용자가 채보를 만들 때부터 그렇게 맞춰 만듦) — WebServer가
// /api/drumChart 응답에 그 곡 시작 마디의 barPosition을 같이 실어 보낸다.
class DrumChartStore {
    static let shared = DrumChartStore()

    private var charts: [String: Data] = [:]   // song name -> 원본 .drum.json 그대로

    init() {}

    func get(song: String) -> Data? {
        charts[song]
    }

    func set(song: String, json: Data) {
        charts[song] = json
    }

    func has(song: String) -> Bool {
        charts[song] != nil
    }

    func songNames() -> [String] {
        Array(charts.keys).sorted()
    }
}

// 드럼 영상 — 파일을 복사하지 않고 "경로"와 "시작점(영상 몇 초가 곡 1박인지)"만 곡 이름으로 보관한다.
// 영상은 예배 당일 클릭 프로젝트 폴더에 이미 있는 파일을 그대로 쓰고(용량·복사 없음), 경로·시작점은
// 앱을 껐다 켜도 남도록 디스크에 저장한다(채보와 달리 영상은 매번 다시 연결하기 번거로워서).
class VideoStore {
    static let shared = VideoStore()

    struct Entry: Codable {
        var path: String
        var offset: Double
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    private var saveURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = dir.appendingPathComponent("Indicator")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("drum_videos.json")
    }

    init() {
        guard let url = saveURL, let raw = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: raw) else { return }
        entries = decoded
    }

    private func persist() {
        guard let url = saveURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url)
    }

    func get(song: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[song]
    }

    // 같은 곡에 다시 연결하면 경로만 바꾸고 시작점은 그대로 둔다(같은 영상을 다시 받은 경우가 대부분)
    func link(song: String, path: String) {
        lock.lock(); defer { lock.unlock() }
        entries[song] = Entry(path: path, offset: entries[song]?.offset ?? 0)
        persist()
    }

    func setOffset(song: String, offset: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var e = entries[song], offset.isFinite else { return false }
        e.offset = offset
        entries[song] = e
        persist()
        return true
    }
}
