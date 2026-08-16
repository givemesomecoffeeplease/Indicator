import Foundation

// LyricsStore와 같은 패턴 — 인메모리 저장, /edit(가사 편집기)의 곡별 "드럼 채보" 업로드로 채워진다.
// 채보(/chart)가 곡의 어느 마디에 대응하는지는 별도 오프셋 없이, "채보 1마디 = 그 곡의 #Song
// 마커 시작 마디"로 항상 고정한다(사용자가 채보를 만들 때부터 그렇게 맞춰 만듦) — WebServer가
// /api/drumChart 응답에 그 곡 시작 마디의 barPosition을 같이 실어 보낸다.
class DrumChartStore {
    static let shared = DrumChartStore()

    private var charts: [String: Data] = [:]   // song name -> 원본 .mai.json 그대로

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
