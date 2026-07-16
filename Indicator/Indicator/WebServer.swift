import Foundation
import Network

class WebServer {

    private var listener: NWListener?
    private let broadcaster = SSEBroadcaster()

    // 현재 SSE로 연결된 뷰어 수 (메뉴 표시용)
    var viewerCount: Int { broadcaster.count }
    private var bandContent: String = ""
    private var singerContent: String = ""

    // Wired up by AppDelegate after init
    var getMarkers: (() -> [Marker])? = nil
    var getLyric: ((_ song: String, _ section: String) -> SectionData?)? = nil
    // occurrence 기반 조회: (song, section, occIdx) -> (resolved data, linked 여부)
    var getLyricOcc: ((_ song: String, _ section: String, _ occIdx: Int) -> (SectionData, Bool))? = nil
    var saveLyrics: ((_ dict: [String: [String: SectionData]]) -> Void)? = nil
    var exportSetlist: ((_ markers: [Marker]) -> Data?)? = nil
    var exportSong: ((_ name: String) -> Data?)? = nil
    var getSongNames: (() -> [String])? = nil
    var onLyricsSaved: (() -> Void)? = nil
    var getSongCountdownBars: ((_ song: String) -> Int)? = nil
    var saveSongCountdownBars: ((_ song: String, _ bars: Int) -> Void)? = nil

    func start(port: UInt16) {
        loadHTML()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        listener = try? NWListener(using: params, on: nwPort)
        listener?.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener?.start(queue: .global(qos: .utility))
        print("[WebServer] Listening on port \(port)")
    }

    func stop() { listener?.cancel() }

    // 마커/박자표 등이 바뀌는 이벤트(사전 스캔 완료 등)에서도 호출 — 이미 열려 있는
    // 뷰어가 /edit DATA(섹션 길이·박자표 등)를 다시 받아오도록 함. 편집 화면 저장 시와
    // 동일한 이벤트를 재사용(뷰어는 'lyrics-updated'만 구독하고 있음).
    func notifyDataChanged() {
        broadcaster.send("event: lyrics-updated\ndata: {}\n\n")
    }

    func broadcast(state: IndicatorState) {
        guard let data = try? JSONEncoder().encode(state),
              let json = String(data: data, encoding: .utf8) else { return }
        broadcaster.send("data: \(json)\n\n")
    }

    // MARK: - Connection

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        receiveRequest(conn)
    }

    private func receiveRequest(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { conn.cancel(); return }

            // Split header / body on \r\n\r\n (binary-safe)
            let sep = Data("\r\n\r\n".utf8)
            guard let sepRange = data.range(of: sep) else { conn.cancel(); return }
            let headerData = data[data.startIndex..<sepRange.lowerBound]
            let bodyData   = data[sepRange.upperBound...]

            let headerStr  = String(data: headerData, encoding: .utf8) ?? ""
            let firstLine  = headerStr.components(separatedBy: "\r\n").first ?? ""
            let parts      = firstLine.split(separator: " ")
            let method     = parts.count >= 1 ? String(parts[0]) : "GET"
            let path       = parts.count >= 2 ? String(parts[1]) : "/"

            // Content-Length로 바디가 더 있으면 추가 수신
            let contentLength: Int = {
                for line in headerStr.components(separatedBy: "\r\n") {
                    let lower = line.lowercased()
                    if lower.hasPrefix("content-length:") {
                        return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }
                return 0
            }()

            let alreadyHave = bodyData.count
            if method == "POST", contentLength > alreadyHave {
                // 남은 바디 추가 수신
                let remaining = contentLength - alreadyHave
                var accumulated = Data(bodyData)
                self.receiveRemaining(conn, accumulated: accumulated, remaining: remaining) { fullBody in
                    self.dispatch(conn, method: method, path: path, body: fullBody)
                }
            } else {
                self.dispatch(conn, method: method, path: path, body: Data(bodyData))
            }
        }
    }

    private func receiveRemaining(_ conn: NWConnection, accumulated: Data, remaining: Int, completion: @escaping (Data) -> Void) {
        guard remaining > 0 else { completion(accumulated); return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, _, _ in
            var acc = accumulated
            if let data { acc.append(data) }
            let stillNeeded = remaining - (data?.count ?? 0)
            if stillNeeded <= 0 {
                completion(acc)
            } else {
                self?.receiveRemaining(conn, accumulated: acc, remaining: stillNeeded, completion: completion)
            }
        }
    }

    private func dispatch(_ conn: NWConnection, method: String, path: String, body: Data) {
        switch (method, path) {
        case ("GET", "/events"):                      handleSSE(conn)
        case ("GET", "/band"):                        handleBand(conn)
        case ("GET", "/singer"):                      handleSinger(conn)
        case ("GET", "/api/sections"):                handleSections(conn)
        case ("GET", "/edit"):                        handleEdit(conn)
        case ("POST", "/save"):                       handleSave(conn, body: body)
        case ("POST", "/save-song-meta"):             handleSaveSongMeta(conn, body: body)
        case ("GET", "/export/setlist"):              handleExportSetlist(conn)
        case _ where path.hasPrefix("/export/song/"): handleExportSong(conn, path: path)
        case ("GET", "/export.csv"):                  handleExportCSV(conn)
        case ("POST", "/import.csv"):                 handleImportCSV(conn, body: body)
        default:                                      handleLanding(conn)
        }
    }

    // MARK: - Pages

    private func handleLanding(_ conn: NWConnection) {
        let html = """
        <!DOCTYPE html><html lang='ko'><head>
        <meta charset='UTF-8'>
        <meta name='viewport' content='width=device-width,initial-scale=1,maximum-scale=1'>
        <meta name='apple-mobile-web-app-capable' content='yes'>
        <meta name='apple-mobile-web-app-status-bar-style' content='black-translucent'>
        <title>Indicator</title>
        <style>
          *{box-sizing:border-box;margin:0;padding:0}
          body{background:#14141a;color:#f0f0f0;font-family:-apple-system,sans-serif;
               height:100dvh;display:flex;flex-direction:column;align-items:center;
               justify-content:center;gap:24px;user-select:none}
          h1{font-size:28px;font-weight:700;letter-spacing:0.04em;color:#5dcaa5}
          .btn{display:block;width:220px;padding:18px 0;border-radius:16px;border:none;
               font-size:18px;font-weight:600;cursor:pointer;text-align:center;
               text-decoration:none;transition:opacity .15s}
          .btn:active{opacity:.7}
          .band{background:#1e1e2e;color:#c0c0e0}
          .singer{background:#5dcaa5;color:#14141a}
          .sub{font-size:12px;color:#555;margin-top:-12px}
        </style></head><body>
        <h1>Indicator</h1>
        <a class='btn singer' href='/singer'>싱어</a>
        <a class='btn band' href='/band'>밴드</a>
        <p class='sub'>선택 후 홈 화면에 추가하면 다음엔 바로 열려요</p>
        </body></html>
        """
        send(conn, body: html.data(using: .utf8) ?? Data(), contentType: "text/html; charset=utf-8")
    }

    private func handleBand(_ conn: NWConnection) {
        send(conn, body: bandContent.data(using: .utf8) ?? Data(), contentType: "text/html; charset=utf-8")
    }

    private func handleSinger(_ conn: NWConnection) {
        send(conn, body: singerContent.data(using: .utf8) ?? Data(), contentType: "text/html; charset=utf-8")
    }

    private func handleSections(_ conn: NWConnection) {
        let markers = getMarkers?() ?? []
        var result: [[String: Any]] = []
        var currentSong = ""
        for m in markers {
            if m.isSong { currentSong = m.displayName }
            else { result.append(["song": currentSong, "section": m.displayName, "mtcSeconds": m.mtcSeconds]) }
        }
        let data = (try? JSONSerialization.data(withJSONObject: result)) ?? Data()
        send(conn, body: data, contentType: "application/json; charset=utf-8")
    }

    // MARK: - SSE

    private func handleSSE(_ conn: NWConnection) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        conn.send(content: header.data(using: .utf8), completion: .contentProcessed { _ in })
        broadcaster.add(conn)
    }

    // MARK: - /edit  (웹 에디터)

    private func handleEdit(_ conn: NWConnection) {
        let markers = getMarkers?() ?? []
        let html = buildEditHTML(markers: markers)
        send(conn, body: html.data(using: .utf8) ?? Data(), contentType: "text/html; charset=utf-8")
    }

    private func buildSongExportButtons(songs: [(name: String, sections: [String])]) -> String {
        songs.map { song in
            let enc = song.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? song.name
            return "<a href='/export/song/\(enc)' class='btn btn-sm' style='background:#5856d6'>\(esc(song.name))</a>"
        }.joined(separator: "\n")
    }

    private func buildEditHTML(markers: [Marker]) -> String {
        // JSON string escape
        func j(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "\n", with: "\\n")
             .replacingOccurrences(of: "\r", with: "")
             .replacingOccurrences(of: "\t", with: "\\t")
        }

        // Encode array to JSON string
        func encodeJSON<T: Encodable>(_ val: T) -> String {
            guard let data = try? JSONEncoder().encode(val),
                  let s = String(data: data, encoding: .utf8) else { return "[]" }
            return s
        }

        // 슬라이드 마이그레이션 + 정리:
        // ① 마디 기반 구버전(startSec 없음, startBar만 있음) → 섹션 길이 비례로 초 환산
        // ② 섹션 노트(세션/싱어) → 첫 슬라이드 노트로 이전 (노트의 슬라이드 귀속화)
        // ③ 순서 보장: startSec(없으면 startBar) 기준 정렬, 첫 슬라이드는 0초 고정
        func migrateSlides(_ raw: [LyricSlide], totalBars: Int, durationSec: Double,
                           secSessionNote: String, secSingerNote: String) -> [LyricSlide] {
            var slides = raw
            let anyStartSec = slides.contains { $0.startSec != nil }
            if anyStartSec {
                slides.sort { ($0.startSec ?? Double.greatestFiniteMagnitude) < ($1.startSec ?? Double.greatestFiniteMagnitude) }
            } else {
                slides.sort { $0.startBar < $1.startBar }
                // 구버전 전체 환산 (섹션 길이·마디 수를 알 때만 — 모르면 nil 유지 = 미확정 표시)
                if totalBars > 0, durationSec > 0 {
                    for i in slides.indices {
                        slides[i].startSec = Double(slides[i].startBar) / Double(totalBars) * durationSec
                    }
                }
            }
            if !slides.isEmpty {
                // 첫 슬라이드 오프셋: 미기록이면 0(마커와 동시). 음수 = 마커보다 먼저 전환.
                if slides[0].startSec == nil { slides[0].startSec = 0 }
                if slides[0].sessionNote.isEmpty { slides[0].sessionNote = secSessionNote }
                if slides[0].singerNote.isEmpty  { slides[0].singerNote  = secSingerNote }
            }
            return slides
        }

        // Build songs data (with slides + totalBars + durationSec + startInSong)
        struct SecInfo {
            var sec: String; var occIdx: Int; var totalBars: Int; var storedBars: Int
            var durationSec: Double; var startInSong: Double
            var beatsPerBar: Int; var beatUnit: Int
            var slidesJson: String; var sessionNote: String; var singerNote: String; var linked: Bool
        }
        var songs: [(name: String, sections: [SecInfo])] = []
        var curSong = ""
        var curSongStartMTC: Double = 0
        var occCount: [String: Int] = [:]  // "song|||sec" -> 다음 occurrence 인덱스
        for (i, m) in markers.enumerated() {
            if m.isSong {
                curSong = m.displayName
                curSongStartMTC = m.mtcSeconds
                songs.append((name: curSong, sections: []))
                occCount = [:]
            } else if !curSong.isEmpty {
                let occKey = "\(curSong)|||\(m.displayName)"
                let occIdx = occCount[occKey] ?? 0
                occCount[occKey] = occIdx + 1
                // 세트리스트의 진짜 마지막 마커는 다음이 없어 nextMTC를 알 수 없음 — 0으로 두면
                // 그 섹션 타임라인이 완전히 비어(길이 0) 편집이 불가능해지므로 30초를 최후의
                // 추정값으로 사용 (StateEngine.sectionBounds의 마지막 폴백과 동일한 값)
                let nextMTC = (i + 1 < markers.count) ? markers[i + 1].mtcSeconds : m.mtcSeconds + 30.0
                let totalBars = ScheduleStore.shared.barsBetween(startMTC: m.mtcSeconds, endMTC: nextMTC) ?? -1
                let durationSec = max(0, nextMTC - m.mtcSeconds)
                let startInSong = max(0, m.mtcSeconds - curSongStartMTC)
                // 간주 코드 그리드가 박자표(분모 포함)에 맞게 그려지도록 섹션 시작 시점의 박자표 전달
                let ts = ScheduleStore.shared.beatsPerBarAt(mtcSeconds: m.mtcSeconds)
                let (d, linked) = getLyricOcc?(curSong, m.displayName, occIdx) ?? (SectionData(), false)
                let migrated = migrateSlides(d.slides, totalBars: d.totalBars > 0 ? d.totalBars : totalBars,
                                             durationSec: durationSec,
                                             secSessionNote: d.sessionNote, secSingerNote: d.singerNote)
                let slidesJson = encodeJSON(migrated)
                songs[songs.count - 1].sections.append(
                    SecInfo(sec: m.displayName, occIdx: occIdx, totalBars: totalBars, storedBars: d.totalBars,
                            durationSec: durationSec, startInSong: startInSong,
                            beatsPerBar: ts?.beatsPerBar ?? 4, beatUnit: ts?.beatUnit ?? 4,
                            slidesJson: slidesJson, sessionNote: d.sessionNote, singerNote: d.singerNote, linked: linked)
                )
            }
        }

        // Embed as JSON
        let songsJson = "[" + songs.map { song in
            let secs = "[" + song.sections.map { sec in
                "{\"sec\":\"\(j(sec.sec))\",\"occIdx\":\(sec.occIdx),\"totalBars\":\(sec.totalBars),\"storedBars\":\(sec.storedBars),\"durationSec\":\(String(format: "%.3f", sec.durationSec)),\"startInSong\":\(String(format: "%.3f", sec.startInSong)),\"beatsPerBar\":\(sec.beatsPerBar),\"beatUnit\":\(sec.beatUnit),\"slides\":\(sec.slidesJson),\"sessionNote\":\"\(j(sec.sessionNote))\",\"singerNote\":\"\(j(sec.singerNote))\",\"linked\":\(sec.linked)}"
            }.joined(separator: ",") + "]"
            let countdownBars = getSongCountdownBars?(song.name) ?? 1
            return "{\"song\":\"\(j(song.name))\",\"countdownBars\":\(countdownBars),\"sections\":\(secs)}"
        }.joined(separator: ",") + "]"

        return """
        <!DOCTYPE html>
        <html lang="ko">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>가사 편집</title>
        <style>
        *{box-sizing:border-box;margin:0;padding:0}
        :root{--accent:#007aff;--bg:#f2f2f7;--card:#fff;--border:#d1d1d6;--text:#1d1d1f;--sub:#6e6e73;--teal:#5DCAA5;--red:#ff453a;--purple:#5856d6;--orange:#ff9500}
        body{font-family:-apple-system,sans-serif;background:var(--bg);height:100vh;display:flex;flex-direction:column;overflow:hidden}
        #hdr{display:flex;align-items:center;gap:12px;padding:12px 20px;background:var(--card);border-bottom:1px solid var(--border);flex-shrink:0}
        #hdr h1{font-size:17px;font-weight:700;flex:1}
        #save-msg{font-size:13px;color:#34c759;font-weight:600;opacity:0;transition:opacity .3s}
        .btn{padding:7px 18px;background:var(--accent);color:#fff;border:none;border-radius:8px;font-size:14px;font-weight:600;cursor:pointer}
        .btn-sm{padding:5px 12px;font-size:13px;border-radius:7px}
        .btn-ghost{background:transparent;color:var(--accent);border:1.5px solid var(--accent)}
        .btn-purple{background:var(--purple)}
        .btn-red{background:transparent;color:var(--red);border:1.5px solid var(--red)}
        .btn-red:hover{background:var(--red);color:#fff}
        #layout{display:flex;flex:1;overflow:hidden}
        #sidebar{width:190px;flex-shrink:0;overflow-y:auto;background:var(--card);border-right:1px solid var(--border);padding:8px 0}
        .sb-hd{padding:10px 14px 3px;font-size:11px;font-weight:700;color:var(--sub);letter-spacing:.5px;text-transform:uppercase}
        .sb-song{padding:9px 16px;font-size:14px;color:var(--text);cursor:pointer;border-left:3px solid transparent}
        .sb-song:hover{background:#f0f0f5}
        .sb-song.active{background:#e5eeff;color:var(--accent);border-left-color:var(--accent);font-weight:600}
        .sb-song.dirty::after{content:"●";font-size:8px;color:var(--accent);margin-left:6px;vertical-align:middle}
        #main{flex:1;overflow-y:auto}
        #empty{display:flex;align-items:center;justify-content:center;height:100%;color:var(--sub);font-size:15px}
        #song-view{display:none;padding:24px;flex-direction:column;gap:20px}
        #song-title{font-size:22px;font-weight:700;color:var(--text);display:flex;align-items:center;gap:8px}
        #export-box{border-top:1px solid var(--border);padding:16px 24px;flex-shrink:0;background:var(--card)}
        #export-box h2{font-size:11px;font-weight:700;color:var(--sub);margin-bottom:8px;text-transform:uppercase;letter-spacing:.5px}
        .btn-row{display:flex;gap:8px;flex-wrap:wrap}
        .btn-sec{background:var(--purple)}
        .sec-block{background:var(--card);border-radius:14px;overflow:hidden;border:1px solid var(--border)}
        .sec-hdr{display:flex;align-items:center;gap:8px;padding:12px 18px;flex-wrap:wrap}
        .sec-arrow{font-size:11px;color:var(--sub);flex-shrink:0;width:14px}
        .sec-name{font-size:16px;font-weight:700;color:var(--text)}
        .sec-bars-info{font-size:12px;color:var(--sub)}
        .transpose-wrap{display:flex;align-items:center;gap:4px;font-size:13px;color:var(--sub);margin-left:auto}
        .transpose-btn{width:24px;height:24px;border:1px solid var(--border);border-radius:6px;background:var(--bg-elev,#fff);cursor:pointer;font-size:14px;line-height:1;display:flex;align-items:center;justify-content:center}
        .transpose-btn:active{opacity:.7}
        .transpose-val{min-width:28px;text-align:center;font-weight:700;color:var(--text)}
        .transpose-apply{font-size:12px;padding:3px 8px}
        .note-pair{display:flex;gap:6px}
        .note-inp-sm{border:1px solid var(--border);border-radius:7px;padding:5px 9px;font-size:12px;outline:none;width:130px}
        .note-inp-sm:focus{border-color:var(--accent)}
        /* ── 곡 단위 연속 타임라인 (MTC 시간 기반 전환 찍기/조절) ──
           슬라이드 트랙(색 블록)과 마커 트랙(눈금)을 같은 시간축 위에 분리 표시 —
           슬라이드 경계는 마커와 무관하게 어디든 위치 가능 (섹션 첫 슬라이드 포함) */
        #song-flex{display:flex;gap:18px;align-items:flex-start}
        /* 타임라인은 카드 스크롤과 분리 — sticky로 화면에 고정 + 자체 스크롤.
           곡이 길면 .tl-rail이 sticky 컨테이너보다 커지므로 내부에서만 스크롤됨 */
        #song-tl{width:264px;flex-shrink:0;user-select:none;padding-left:56px;
          position:sticky;top:12px;max-height:calc(100vh - 90px);overflow-y:auto;overflow-x:visible}
        #sections-list{flex:1;min-width:0;display:flex;flex-direction:column;gap:20px}
        .tl-rail{position:relative;width:168px;border-radius:10px;background:#ececf4;overflow:visible}
        /* 상단 padding을 넉넉히 줘서 경계에 겹치는 시간 배지(.grip)와 텍스트가 겹치지 않게 하고,
           줄바꿈 허용(word-break)으로 좌우 잘림 없이 여러 줄로 표시 */
        .tl-slide{position:absolute;left:0;width:168px;border-radius:6px;display:flex;align-items:flex-start;justify-content:center;padding:15px 8px 4px;font-size:12px;font-weight:700;line-height:1.35;color:#fff;overflow:hidden;white-space:normal;word-break:keep-all;text-align:center;cursor:pointer}
        .tl-slide.playing-slide{outline:3px solid var(--orange);outline-offset:-3px}
        .tl-handle{position:absolute;left:0;width:168px;height:20px;margin-top:-10px;display:flex;align-items:center;justify-content:center;cursor:ns-resize;z-index:5;touch-action:none}
        .tl-handle .grip{background:#fff;border:2px solid var(--purple);color:var(--purple);font-size:10px;font-weight:700;border-radius:10px;padding:1px 9px;box-shadow:0 1px 4px rgba(0,0,0,.18);white-space:nowrap;pointer-events:none}
        .tl-handle.guess .grip{opacity:.45;border-style:dashed}
        .tl-handle:hover .grip{background:#f3f1ff}
        .tl-playhead{position:absolute;left:-8px;width:184px;height:0;border-top:2px solid var(--red);z-index:6;pointer-events:none;display:none}
        .tl-playhead::after{content:'';position:absolute;left:-2px;top:-4px;width:6px;height:6px;border-radius:50%;background:var(--red)}
        /* 마커 트랙: Logic 마커 위치 눈금 + 섹션명 (움직일 수 없음 — Logic이 결정) */
        .tl-marker{position:absolute;left:-56px;width:264px;height:0;border-top:1.5px dashed #a8a8bc;pointer-events:none}
        .tl-marker-lbl{position:absolute;left:-56px;width:50px;transform:translateY(2px);font-size:9px;font-weight:700;color:#77778a;text-align:left;line-height:1.2;pointer-events:none;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .tl-marker-time{position:absolute;left:174px;transform:translateY(-50%);font-size:9px;color:#aaa;white-space:nowrap;pointer-events:none}
        .cards-col{display:flex;flex-direction:column;gap:10px;min-width:0;padding:12px 18px 16px;border-top:1px solid var(--border)}
        .seg-time{font-size:11px;font-weight:700;color:var(--purple);white-space:nowrap}
        .seg-time.guess{color:#aaa;font-weight:600}
        .seg-card.playing-slide{border-color:var(--orange);box-shadow:0 0 0 2px rgba(255,149,0,.25)}
        .sec-block.playing{border-color:var(--accent);box-shadow:0 0 0 2px rgba(0,122,255,.18)}
        .add-slide-btn{align-self:flex-start;background:transparent;color:var(--accent);border:1.5px dashed var(--accent);border-radius:8px;padding:6px 14px;font-size:13px;font-weight:600;cursor:pointer}
        #tap-btn{background:var(--orange);font-size:14px;font-weight:700;padding:8px 20px;border-radius:10px}
        #tap-btn:active{transform:scale(.94)}
        #tap-btn.flash{animation:tapFlash .25s ease}
        @keyframes tapFlash{0%{transform:scale(1.15);background:#ff3b30}100%{transform:scale(1)}}
        #follow-wrap{display:flex;align-items:center;gap:5px;font-size:13px;color:var(--sub);cursor:pointer;white-space:nowrap}
        #now-playing{font-size:12px;color:var(--sub);white-space:nowrap;max-width:220px;overflow:hidden;text-overflow:ellipsis}
        .seg-card{border:1.5px solid var(--border);border-radius:10px;overflow:hidden}
        .seg-hdr{display:flex;align-items:center;gap:8px;padding:7px 12px;background:#f8f8fc;border-bottom:1px solid var(--border)}
        .seg-dot{width:12px;height:12px;border-radius:50%;flex-shrink:0}
        .seg-info{flex:1;font-size:12px;font-weight:600;color:var(--text)}
        .seg-ed{padding:10px 12px;display:flex;flex-direction:column;gap:8px}
        .mode-row{display:flex;gap:6px}
        .lyric-ta{width:100%;min-height:72px;border:1.5px solid var(--border);border-radius:8px;padding:10px 12px;font-size:16px;line-height:1.8;font-family:-apple-system,sans-serif;outline:none;resize:vertical}
        .lyric-ta:focus{border-color:var(--accent)}
        .chord-grid{background:#1c1c1e;border-radius:10px;padding:14px 16px;min-height:60px}
        .tok-line{display:flex;flex-wrap:wrap;align-items:flex-end;min-height:50px;margin-bottom:2px;gap:2px}
        .tok{display:inline-flex;flex-direction:column;align-items:center;position:relative;border-radius:4px;padding:2px 4px;cursor:pointer;min-width:18px}
        .tok:hover{background:rgba(255,255,255,.09)}
        .tok.editing{background:rgba(93,202,165,.15);outline:1.5px solid var(--teal)}
        .tok-ca{font-size:13px;color:var(--teal);font-weight:700;line-height:1;white-space:nowrap;min-height:16px;text-align:center}
        .tok-ch{font-size:22px;color:#e8e8ed;line-height:1.3;text-align:center}
        .tok-ghost{min-width:72px}
        .tok-ghost .tok-ch{color:#555;font-size:18px}
        .tok-del{position:absolute;top:-6px;right:-6px;width:16px;height:16px;background:var(--red);border-radius:50%;color:#fff;font-size:11px;display:flex;align-items:center;justify-content:center;cursor:pointer;z-index:2}
        .chord-inp-pop{font-size:13px;background:#2c2c2e;border:1.5px solid var(--teal);border-radius:5px;color:var(--teal);font-weight:700;text-align:center;outline:none;padding:2px 6px;width:64px;position:absolute;bottom:calc(100% + 3px);left:50%;transform:translateX(-50%);z-index:20}
        .add-ghost-btn{display:inline-flex;align-items:center;justify-content:center;min-width:32px;height:36px;background:rgba(255,255,255,.07);border-radius:5px;color:#666;font-size:18px;cursor:pointer;align-self:flex-end;margin-bottom:4px;padding:0 6px;flex-shrink:0}
        .add-ghost-btn:hover{background:rgba(255,255,255,.16);color:#bbb}
        .inst-table{display:flex;flex-direction:column;gap:3px;overflow-x:auto}
        .inst-row{display:flex;align-items:center;gap:2px}
        .inst-bar-lbl{width:64px;font-size:11px;color:var(--sub);font-weight:600;flex-shrink:0}
        .inst-beat-hdr{width:42px;font-size:10px;color:var(--sub);font-weight:700;text-align:center;flex-shrink:0}
        .inst-beat-on .inst-beat-inp{background:#f0faf7;border-color:rgba(93,202,165,.3)}
        .inst-beat-off .inst-beat-inp{background:#fafafa}
        .inst-beat-inp{width:42px;padding:4px 2px;font-size:13px;font-weight:700;text-align:center;border:1.5px solid var(--border);border-radius:5px;outline:none;font-family:-apple-system,sans-serif}
        .inst-beat-inp:focus{border-color:var(--teal)}
        .hidden{display:none!important}
        #main.drop-hover{outline:3px dashed #0055ff;outline-offset:-4px;background:rgba(0,85,255,0.04)}
        </style>
        </head>
        <body>
        <div id="hdr">
          <h1>가사 편집</h1>
          <button id="tap-btn" class="btn" title="재생 중 이 순간을 슬라이드가 넘어가는 시점으로 기록 (Enter)">여기서 넘김 ⏎</button>
          <label id="follow-wrap"><input type="checkbox" id="follow-chk">재생 따라가기</label>
          <span id="now-playing"></span>
          <span id="save-msg"></span>
          <input type="file" id="import-file-inp" accept=".html" style="display:none" onchange="handleImportFile(this.files[0],null)">
          <input type="file" id="import-song-inp" accept=".html" style="display:none" onchange="handleImportFile(this.files[0],pendingImportSong)">
          <button id="btn-import" class="btn btn-sm btn-sec" onclick="document.getElementById('import-file-inp').click()">전체 가져오기</button>
          <button id="btn-export" class="btn btn-sm btn-sec" onclick="exportForTeam()">전체 내보내기</button>
          <button class="btn" onclick="STANDALONE?standaloneDownload():saveAll()">뷰어 적용</button>
        </div>
        <div id="layout">
          <div id="sidebar"><div class="sb-hd">곡 목록</div></div>
          <div id="main">
            <div id="empty">← 곡을 선택하세요</div>
            <div id="song-view">
              <div id="song-title"></div>
              <div id="song-flex">
                <div id="song-tl"></div>
                <div id="sections-list"></div>
              </div>
            </div>
          </div>
        </div>
        <script>
        const DATA=\(songsJson);//EXPORT_DATA_LINE
        const STANDALONE=false;//EXPORT_STANDALONE_LINE
        const EXPORT_FILENAME='';//EXPORT_FILENAME_LINE
        const COLORS=['#007aff','#34c759','#5856d6','#ff9500','#bf5af2','#30b0c7','#ff453a'];
        const $=id=>document.getElementById(id);
        let curSong=null;
        const dirty={};
        const secUI={};

        function normChord(s){
          if(!s)return'';s=s.trim();if(!s)return'';
          let out=s[0].toUpperCase()+s.slice(1);
          out=out.replace(/([A-G])s(?!u)/g,'$1#');
          out=out.replace(/([A-G])b(?!b)/g,'$1♭');
          return out;
        }

        // ── 트랜스포즈: 코드 텍스트의 근음(+슬래시 베이스)을 반음수만큼 이조 ──
        const NOTE_IDX={C:0,'C#':1,'D♭':1,Db:1,D:2,'D#':3,'E♭':3,Eb:3,E:4,F:5,'F#':6,'G♭':6,Gb:6,G:7,'G#':8,'A♭':8,Ab:8,A:9,'A#':10,'B♭':10,Bb:10,B:11};
        const SHARP_NAMES=['C','C#','D','D#','E','F','F#','G','G#','A','A#','B'];
        function transposeChord(chord,semi){
          if(!chord||!semi)return chord;
          const m=chord.match(/^([A-G])([#♭]?)/);
          if(!m)return chord;
          const rootLen=m[0].length;
          const rootKey=m[1]+m[2];
          const idx=NOTE_IDX[rootKey];
          if(idx===undefined)return chord;
          const rest=chord.slice(rootLen);
          const newRoot=SHARP_NAMES[((idx+semi)%12+12)%12];
          const sm=rest.match(/^([^/]*)\\/([A-G][#♭]?)(.*)$/);
          if(sm){
            const bIdx=NOTE_IDX[sm[2]];
            const newBass=bIdx!==undefined?SHARP_NAMES[((bIdx+semi)%12+12)%12]:sm[2];
            return newRoot+sm[1]+'/'+newBass+sm[3];
          }
          return newRoot+rest;
        }
        // 곡 하나의 모든 코드(가사 토큰 + 간주 슬롯)를 실제로 이조 (일회성 액션)
        function transposeSong(song,semi){
          if(!semi)return;
          const songData=DATA.find(s=>s.song===song);
          if(!songData)return;
          songData.sections.forEach(sec=>{
            const cur=loadState(song,sec.sec,sec.occIdx);
            const newSegData=cur.segData.map(sd=>({
              ...sd,
              tokens:(sd.tokens||[]).map(t=>t.chord?{...t,chord:transposeChord(t.chord,semi)}:t),
              instChords:(sd.instChords||[]).map(bar=>(bar||[]).map(slot=>({...slot,name:transposeChord(slot.name,semi)})))
            }));
            setState(song,sec.sec,sec.occIdx,{segData:newSegData});
          });
        }

        // occurrence(occIdx) 기반 키 — 같은 이름 섹션이 여러 번 등장해도 독립적으로 식별됨
        function dkOf(song,sec,occIdx){return song+'|||'+sec+'@@'+occIdx;}
        function ukOf(song,sec,idx){return song+'|||'+sec+'|||'+idx;}
        function origSecOf(song,sec,occIdx){
          const secs=DATA.find(s=>s.song===song)?.sections||[];
          if(occIdx!==undefined){const exact=secs.find(s=>s.sec===sec&&s.occIdx===occIdx);if(exact)return exact;}
          return secs.find(s=>s.sec===sec)||{};
        }

        // ── 시간 유틸 ──
        function fmtSec(s){
          if(s==null)return'—';
          const m=Math.floor(s/60);const r=s-m*60;
          return m+':'+(r<10?'0':'')+r.toFixed(1);
        }

        // 슬라이드 전환 위치 해석: segData[i].startSec = 섹션 마커 시작 기준 오프셋(초).
        // 첫 슬라이드도 오프셋 가능 (0=마커와 동시, 음수=마커보다 먼저).
        // null(아직 안 찍음)은 앞뒤 확정 위치 사이를 균등 분할한 임시값(guess) — 뷰어와 동일 규칙
        function resolvePositions(segData,dur){
          const n=segData.length;const out=new Array(n);
          if(n===0)return out;
          out[0]={sec:segData[0].startSec??0,guess:false};
          let i=1;
          while(i<n){
            const v=segData[i].startSec;
            if(v!=null){out[i]={sec:v,guess:false};i++;continue;}
            let j=i;while(j<n&&segData[j].startSec==null)j++;
            const endSec=j<n?segData[j].startSec:(dur>0?dur:out[i-1].sec+(n-i+1)*5);
            const span=Math.max(0,endSec-out[i-1].sec);const cnt=j-i+1;
            for(let k=i;k<j;k++)out[k]={sec:out[i-1].sec+span*(k-i+1)/cnt,guess:true};
            i=j;
          }
          for(let k=1;k<n;k++)if(out[k].sec<out[k-1].sec+0.05)out[k]={sec:out[k-1].sec+0.05,guess:out[k].guess};
          return out;
        }

        function emptySlide(){return{startSec:null,isInstrumental:false,tokens:[],instChords:[],sessionNote:'',singerNote:''};}

        // 상태 = {segData:[슬라이드...]} — 슬라이드 순서 = 배열 순서, 첫 슬라이드 startSec은 항상 0
        function loadState(song,sec,occIdx){
          const k=dkOf(song,sec,occIdx);
          if(dirty[k])return dirty[k];
          const o=origSecOf(song,sec,occIdx);
          const slides=(o.slides||[]);
          const segData=slides.length?slides.map(sl=>({
            startSec:(sl.startSec===undefined?null:sl.startSec),
            isInstrumental:!!sl.isInstrumental,
            tokens:sl.tokens||[],
            instChords:sl.instChords||[],
            sessionNote:sl.sessionNote||'',
            singerNote:sl.singerNote||''
          })):[{...emptySlide(),startSec:0}];
          if(segData[0].startSec==null)segData[0].startSec=0;
          return{segData};
        }

        function setState(song,sec,occIdx,st){
          if(st.segData&&st.segData.length&&st.segData[0].startSec==null)st.segData[0].startSec=0;
          dirty[dkOf(song,sec,occIdx)]=st;
          document.querySelectorAll('.sb-song').forEach(el=>{if(el.dataset.song===song)el.classList.add('dirty');});
        }

        function setSlideField(song,sec,occIdx,segIdx,field,value){
          const cur=loadState(song,sec,occIdx);
          const segData=cur.segData.map(s=>({...s}));
          segData[segIdx]={...segData[segIdx],[field]:value};
          setState(song,sec,occIdx,{segData});
        }

        // "복사" 드롭다운: 선택하는 순간 원본의 현재 내용(가사·코드·노트·전환 타이밍)을 스냅샷 복사.
        // 섹션 길이가 다르면 전환 타이밍은 길이 비례로 환산. 이후 원본이 바뀌어도 따라가지 않음.
        function copyFromSection(song,destSec,destOccIdx,srcSec,srcOccIdx){
          const srcState=loadState(song,srcSec,srcOccIdx);
          const srcDur=origSecOf(song,srcSec,srcOccIdx).durationSec||0;
          const destDur=origSecOf(song,destSec,destOccIdx).durationSec||0;
          const ratio=(srcDur>0&&destDur>0)?destDur/srcDur:1;
          const segData=srcState.segData.map(sd=>({
            ...sd,
            startSec:sd.startSec==null?null:Math.round(sd.startSec*ratio*100)/100,
            tokens:(sd.tokens||[]).map(t=>({...t})),
            instChords:(sd.instChords||[]).map(bar=>(bar||[]).map(s=>({...s})))
          }));
          setState(song,destSec,destOccIdx,{segData});
        }

        function tokensToPlain(toks){return(toks||[]).map(t=>t.type==='br'?'\\n':t.type==='char'?(t.char||''):'').join('');}
        function textToTokens(text){return[...text].map(c=>c==='\\n'?{type:'br'}:{type:'char',char:c});}

        function renderSidebar(){
          const sb=$('sidebar');sb.innerHTML='<div class="sb-hd">곡 목록</div>';
          const songs=[...new Map(DATA.map(s=>[s.song,s])).values()];
          songs.forEach(s=>{
            const el=document.createElement('div');
            el.className='sb-song'+(curSong===s.song?' active':'')+(Object.keys(dirty).some(k=>k.startsWith(s.song+'|||'))?' dirty':'');
            el.dataset.song=s.song;el.textContent=s.song;
            el.addEventListener('click',()=>selectSong(s.song));
            sb.appendChild(el);
          });
        }

        function selectSong(song){
          curSong=song;renderSidebar();
          $('empty').style.display='none';
          const sv=$('song-view');sv.style.display='flex';
          const titleEl=$('song-title');
          titleEl.innerHTML='';
          const nameSpan=document.createElement('span');nameSpan.textContent=song;titleEl.appendChild(nameSpan);

          // 트랜스포즈: 반음 값을 정하고 '적용'을 누르면 이 곡의 모든 코드가 실제로 이조됨 (일회성)
          const tW=document.createElement('div');tW.className='transpose-wrap';
          let tVal=0;
          const tLabel=document.createElement('span');tLabel.textContent='트랜스포즈';
          const minusBtn=document.createElement('button');minusBtn.className='transpose-btn';minusBtn.textContent='－';minusBtn.type='button';
          const valSpan=document.createElement('span');valSpan.className='transpose-val';valSpan.textContent='0';
          const plusBtn=document.createElement('button');plusBtn.className='transpose-btn';plusBtn.textContent='＋';plusBtn.type='button';
          const applyBtn=document.createElement('button');applyBtn.className='btn btn-sm btn-sec transpose-apply';applyBtn.textContent='적용';applyBtn.disabled=true;
          const updateT=d=>{tVal=Math.max(-11,Math.min(11,tVal+d));valSpan.textContent=(tVal>0?'+':'')+tVal;applyBtn.disabled=tVal===0;};
          minusBtn.onclick=()=>updateT(-1);
          plusBtn.onclick=()=>updateT(1);
          applyBtn.onclick=()=>{
            if(!tVal)return;
            transposeSong(song,tVal);
            tVal=0;valSpan.textContent='0';applyBtn.disabled=true;
            renderSections(song);
            showMsg('코드를 이조했어요. 뷰어 적용을 눌러 반영하세요.');
          };
          tW.appendChild(tLabel);tW.appendChild(minusBtn);tW.appendChild(valSpan);tW.appendChild(plusBtn);tW.appendChild(applyBtn);
          titleEl.appendChild(tW);

          // 카운트다운 표시 시작 (곡별, 즉시 저장) — 0=사용 안 함, 기본 1마디 전
          const songDataForCd=DATA.find(s=>s.song===song);
          const cdWrap=document.createElement('div');cdWrap.style.cssText='display:flex;align-items:center;gap:6px;font-size:13px;color:var(--sub);margin-left:12px';
          const cdLabel=document.createElement('span');cdLabel.textContent='카운트다운';
          const cdSel=document.createElement('select');cdSel.style.cssText='border:1px solid var(--border);border-radius:7px;padding:4px 8px;font-size:13px';
          cdSel.innerHTML='<option value="0">사용 안 함</option><option value="1">1마디 전</option><option value="2">2마디 전</option>';
          cdSel.value=String(songDataForCd?.countdownBars??1);
          cdSel.addEventListener('change',()=>{
            const bars=parseInt(cdSel.value)||0;
            if(songDataForCd)songDataForCd.countdownBars=bars;
            fetch('/save-song-meta',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({song,countdownBars:bars})});
            showMsg('카운트다운 설정 저장됐어요');
          });
          cdWrap.appendChild(cdLabel);cdWrap.appendChild(cdSel);
          titleEl.appendChild(cdWrap);

          if(!STANDALONE){
            const actDiv=document.createElement('div');actDiv.style.cssText='display:flex;gap:6px;margin-left:12px';
            const exportBtn=document.createElement('button');
            exportBtn.className='btn btn-sm btn-sec';exportBtn.textContent='내보내기';
            exportBtn.onclick=()=>exportSongAsHtml(song);
            const importBtn=document.createElement('button');
            importBtn.className='btn btn-sm btn-sec';importBtn.textContent='가져오기';
            importBtn.onclick=()=>{pendingImportSong=song;$('import-song-inp').click();};
            actDiv.appendChild(exportBtn);actDiv.appendChild(importBtn);
            titleEl.appendChild(actDiv);
          }
          renderSections(song);
        }

        function renderSections(song){
          const list=$('sections-list');list.innerHTML='';
          const songData=DATA.find(s=>s.song===song);
          if(!songData)return;
          songData.sections.forEach((sec,secIdx)=>{
            const ukey=ukOf(song,sec.sec,secIdx);
            if(!secUI[ukey])secUI[ukey]={open:STANDALONE};
            list.appendChild(createSecBlock(song,sec,secIdx));
          });
          renderSongTimeline(song);
        }

        function createSecBlock(song,sec,gidx){
          const ukey=ukOf(song,sec.sec,gidx);
          const ui=secUI[ukey];
          const st=loadState(song,sec.sec,sec.occIdx);
          const dur=sec.durationSec||0;
          const block=document.createElement('div');
          block.className='sec-block';block.dataset.ukey=ukey;

          const hdr=document.createElement('div');hdr.className='sec-hdr';hdr.style.cursor='pointer';
          hdr.addEventListener('click',()=>{ui.open=!ui.open;refreshBlock(block,song,sec,gidx);});

          const arrow=document.createElement('span');arrow.className='sec-arrow';arrow.textContent=ui.open?'▾':'▸';
          const nameEl=document.createElement('span');nameEl.className='sec-name';nameEl.textContent=sec.sec;
          const barsEl=document.createElement('span');barsEl.className='sec-bars-info';
          barsEl.textContent=(dur>0?fmtSec(dur):'길이 미상')+' · 슬라이드 '+st.segData.length+'장';
          if(sec.totalBars===-1){
            barsEl.textContent+=' · ⚠️ 템포 스캔 필요';barsEl.style.color='#e05c00';
          }else if(sec.storedBars>0&&sec.totalBars>0&&sec.storedBars!==sec.totalBars){
            // 편곡 변경 감지 — 저장 당시와 마디 수가 다르면 전환 위치 확인 필요
            barsEl.textContent+=' · ⚠️ 편곡 변경 감지(저장 당시 '+sec.storedBars+'마디 → 지금 '+sec.totalBars+'마디) — 전환 위치 확인';
            barsEl.style.color='#e05c00';
          }

          const linkSel=document.createElement('select');
          linkSel.className='link-select';
          linkSel.dataset.song=song;linkSel.dataset.sec=sec.sec;linkSel.dataset.sb=sec.occIdx;
          const myBase=sec.sec.replace(/[0-9]+$/,'');
          const songSections=(DATA.find(s=>s.song===song)||{sections:[]}).sections;
          // 복사 가능한 대상: 이름이 같은 다른 등장(occIdx 무관) + 숫자 제외 이름이 같은 다른 섹션들의 모든 등장
          const copyOpts=songSections
            .filter(s=>!(s.sec===sec.sec&&s.occIdx===sec.occIdx)&&s.sec.replace(/[0-9]+$/,'')===myBase)
            .map(s=>{
              const label=(s.sec===sec.sec?'':s.sec+' ')+(s.occIdx+1)+'번째';
              return '<option value="'+s.sec+'@@'+s.occIdx+'">'+label+' 복사</option>';
            }).join('');
          linkSel.innerHTML='<option value="independent">독립적으로 편집</option>'+copyOpts;
          linkSel.value='independent';  // 드롭다운은 상태가 아니라 "복사" 액션 트리거 — 항상 대기 상태로 표시
          linkSel.disabled=!copyOpts;
          linkSel.addEventListener('click',e=>e.stopPropagation());
          linkSel.addEventListener('change',()=>{
            const val=linkSel.value;
            linkSel.value='independent';
            if(val==='independent')return;
            const ii=val.lastIndexOf('@@');
            copyFromSection(song,sec.sec,sec.occIdx,val.slice(0,ii),parseInt(val.slice(ii+2)));
            refreshBlock(block,song,sec,gidx);
            showMsg('복사했어요 (전환 타이밍 포함). 다시 선택하면 최신 내용으로 다시 복사돼요.');
          });

          hdr.appendChild(arrow);hdr.appendChild(nameEl);hdr.appendChild(barsEl);hdr.appendChild(linkSel);
          block.appendChild(hdr);

          if(ui.open){
            const cards=document.createElement('div');cards.className='cards-col';
            renderCards(cards,song,sec,gidx);
            block.appendChild(cards);
          }
          return block;
        }

        function refreshBlock(block,song,sec,gidx){block.replaceWith(createSecBlock(song,sec,gidx));renderSongTimeline(song);}
        function getBlock(ukey){return document.querySelector('.sec-block[data-ukey="'+ukey+'"]');}

        function firstLineOf(tokens){
          let s='';
          for(const t of(tokens||[])){if(t.type==='br')break;if(t.type==='char')s+=t.char||'';}
          return s||'(빈 슬라이드)';
        }

        // ── 곡 전체 슬라이드 목록 (곡 내 절대 위치로 펼침) ──
        // 각 항목: {secIdx, sec(섹션 데이터), si(섹션 내 슬라이드 인덱스), abs(곡 내 초), guess, sd}
        function songSlideList(song){
          const songData=DATA.find(s=>s.song===song);
          if(!songData)return[];
          const list=[];
          songData.sections.forEach((sec,secIdx)=>{
            const st=loadState(song,sec.sec,sec.occIdx);
            const pos=resolvePositions(st.segData,sec.durationSec||0);
            st.segData.forEach((sd,si)=>{
              list.push({secIdx,sec,si,abs:(sec.startInSong||0)+pos[si].sec,guess:pos[si].guess,sd});
            });
          });
          list.sort((a,b)=>a.abs-b.abs||a.secIdx-b.secIdx||a.si-b.si);
          return list;
        }
        function songDuration(song){
          const s=DATA.find(d=>d.song===song);
          if(!s||!s.sections.length)return 0;
          const last=s.sections[s.sections.length-1];
          return(last.startInSong||0)+(last.durationSec||0);
        }
        function tlHeight(dur){return Math.max(240,Math.round(dur*7));}  // 초당 픽셀 확대(4→7, 약 1.75배) — 슬라이드 블록이 더 크게 보이도록

        function fmtOffset(o){
          const r=Math.round(o*10)/10;
          if(Math.abs(r)<0.05)return'마커와 동시';
          return(r>0?'+':'−')+Math.abs(r).toFixed(1)+'초';
        }

        // 곡 단위 연속 타임라인: 마커 트랙(눈금·움직일 수 없음)과 슬라이드 트랙(색 블록)을
        // 같은 시간축 위에 분리 표시. 모든 경계(섹션 첫 슬라이드 포함)가 드래그·찍기 대상.
        function renderSongTimeline(song){
          const container=$('song-tl');
          if(!container||curSong!==song)return;
          container.innerHTML='';
          const list=songSlideList(song);
          const songDur=songDuration(song);
          if(!list.length)return;
          const effDur=songDur>0?songDur:(list[list.length-1].abs+8);
          const H=tlHeight(effDur);
          const rail=document.createElement('div');rail.className='tl-rail';rail.style.height=H+'px';
          const yOf=s=>Math.max(0,Math.min(H,s/effDur*H));
          // 마커 트랙 (Logic 마커 = 섹션 경계 눈금)
          const songData=DATA.find(s=>s.song===song);
          songData.sections.forEach(sec=>{
            const y=yOf(sec.startInSong||0);
            const mk=document.createElement('div');mk.className='tl-marker';mk.style.top=y+'px';rail.appendChild(mk);
            const lbl=document.createElement('div');lbl.className='tl-marker-lbl';lbl.style.top=y+'px';
            lbl.textContent=sec.sec;lbl.title=sec.sec+' 마커 · '+fmtSec(sec.startInSong||0);
            rail.appendChild(lbl);
            const tm=document.createElement('div');tm.className='tl-marker-time';tm.style.top=y+'px';
            tm.textContent=fmtSec(sec.startInSong||0);rail.appendChild(tm);
          });
          // 슬라이드 트랙
          for(let g=0;g<list.length;g++){
            const it=list[g];
            const top=yOf(it.abs);
            const bottom=g+1<list.length?yOf(list[g+1].abs):H;
            const el=document.createElement('div');el.className='tl-slide';el.dataset.g=String(g);
            el.dataset.secIdx=String(it.secIdx);el.dataset.si=String(it.si);
            el.style.top=top+'px';el.style.height=Math.max(14,bottom-top)+'px';
            el.style.background=COLORS[it.si%COLORS.length];
            el.textContent=(it.si+1)+'. '+(it.sd.isInstrumental?'코드만':firstLineOf(it.sd.tokens));
            el.title=it.sec.sec+' · 슬라이드 '+(it.si+1)+' — 클릭하면 오른쪽 카드로 이동';
            el.addEventListener('click',()=>{
              const card=getBlock(ukOf(song,it.sec.sec,it.secIdx))?.querySelector('.seg-card[data-si="'+it.si+'"]');
              if(card)card.scrollIntoView({behavior:'smooth',block:'center'});
            });
            rail.appendChild(el);
          }
          // 경계 핸들 (곡의 맨 첫 슬라이드 제외 전부 — 섹션 첫 슬라이드도 마커 대비 ± 조절 가능)
          for(let g=1;g<list.length;g++){
            const it=list[g];
            const h=document.createElement('div');
            h.className='tl-handle'+(it.guess?' guess':'');
            h.style.top=yOf(it.abs)+'px';
            h.title=(it.si===0?it.sec.sec+' 첫 슬라이드 (마커 대비 '+fmtOffset(it.abs-(it.sec.startInSong||0))+') — ':'')+(it.guess?'임시 위치 — 드래그하거나 재생 중 찍어서 확정':'드래그로 전환 시점 조절 (위=일찍, 아래=늦게)');
            const grip=document.createElement('span');grip.className='grip';
            grip.textContent=(it.guess?'~':'')+fmtSec(it.abs);
            h.appendChild(grip);
            attachHandleDrag(h,rail,song,g,effDur,H);
            rail.appendChild(h);
          }
          const ph=document.createElement('div');ph.className='tl-playhead';rail.appendChild(ph);
          container.appendChild(rail);
        }

        // 전환 아이콘 드래그: 위=일찍, 아래=늦게. 이웃 경계를 넘지 못함 (슬라이드 순서 고정).
        // 섹션 첫 슬라이드 핸들은 마커를 넘어 이전 섹션 구간까지 끌 수 있음 (음수 오프셋).
        // 드래그 중엔 스타일만 직접 갱신(재렌더 시 포인터 캡처가 끊기므로), 놓을 때 상태 확정.
        function attachHandleDrag(h,rail,song,g,effDur,H){
          h.addEventListener('pointerdown',e=>{
            e.preventDefault();e.stopPropagation();
            h.setPointerCapture(e.pointerId);
            const railTop=rail.getBoundingClientRect().top;
            const list0=songSlideList(song);
            const it=list0[g];
            const lo=list0[g-1].abs+0.15;
            const hi=(g+1<list0.length?list0[g+1].abs:effDur)-0.15;
            const blocks=rail.querySelectorAll('.tl-slide');
            const grip=h.querySelector('.grip');
            let cur=it.abs;
            const apply=t=>{
              cur=t;
              const y=t/effDur*H;
              h.style.top=y+'px';
              h.classList.remove('guess');
              if(grip)grip.textContent=fmtSec(t);
              const prev=blocks[g-1],me=blocks[g];
              if(prev)prev.style.height=Math.max(14,y-parseFloat(prev.style.top))+'px';
              if(me){const meBottom=parseFloat(me.style.top)+parseFloat(me.style.height);me.style.top=y+'px';me.style.height=Math.max(14,meBottom-y)+'px';}
            };
            const move=ev=>{
              let t=(ev.clientY-railTop)/H*effDur;
              t=Math.max(lo,Math.min(Math.max(lo,hi),t));
              apply(Math.round(t*100)/100);
            };
            const up=()=>{
              h.removeEventListener('pointermove',move);
              h.removeEventListener('pointerup',up);
              const st=loadState(song,it.sec.sec,it.sec.occIdx);
              const segData=st.segData.map(s=>({...s}));
              segData[it.si].startSec=Math.round((cur-(it.sec.startInSong||0))*100)/100;
              setState(song,it.sec.sec,it.sec.occIdx,{segData});
              const bl=getBlock(ukOf(song,it.sec.sec,it.secIdx));
              if(bl)refreshBlock(bl,song,it.sec,it.secIdx);
              else renderSongTimeline(song);
            };
            h.addEventListener('pointermove',move);
            h.addEventListener('pointerup',up);
          });
        }

        const chordEditState={};

        function renderCards(container,song,sec,gidx){
          container.innerHTML='';
          const st=loadState(song,sec.sec,sec.occIdx);
          st.segData.forEach((sd,i)=>container.appendChild(createSegCard(song,sec,gidx,i)));
          const addBtn=document.createElement('button');addBtn.className='add-slide-btn';addBtn.textContent='＋ 슬라이드 추가';
          addBtn.addEventListener('click',()=>{
            const cur=loadState(song,sec.sec,sec.occIdx);
            setState(song,sec.sec,sec.occIdx,{segData:[...cur.segData.map(s=>({...s})),emptySlide()]});
            const bl=getBlock(ukOf(song,sec.sec,gidx));if(bl)refreshBlock(bl,song,sec,gidx);
          });
          container.appendChild(addBtn);
        }

        function createSegCard(song,sec,gidx,segIdx){
          const ukey=ukOf(song,sec.sec,gidx);
          const ceKey=ukey+'|||'+segIdx;
          if(!chordEditState[ceKey])chordEditState[ceKey]={chordMode:false,editIdx:null};
          const ces=chordEditState[ceKey];
          const st=loadState(song,sec.sec,sec.occIdx);
          const sd=st.segData[segIdx];
          const pos=resolvePositions(st.segData,sec.durationSec||0);
          const card=document.createElement('div');card.className='seg-card';card.dataset.si=String(segIdx);

          const hd=document.createElement('div');hd.className='seg-hdr';
          const dot=document.createElement('div');dot.className='seg-dot';dot.style.background=COLORS[segIdx%COLORS.length];
          const info=document.createElement('div');info.className='seg-info';info.textContent='슬라이드 '+(segIdx+1);
          info.style.flex='0 0 auto';
          const time=document.createElement('span');
          const isGuess=pos[segIdx]&&pos[segIdx].guess;
          time.className='seg-time'+(isGuess?' guess':'');
          // 첫 슬라이드도 마커 대비 오프셋을 가질 수 있음(타임라인에서 조절) — 0이면 "섹션 시작",
          // 아니면 실제 오프셋을 표시해 타임라인 핸들과 카드 라벨이 항상 일치하게 함
          if(segIdx===0){
            const off=pos[0]?pos[0].sec:0;
            time.textContent=Math.abs(off)<0.05?'섹션 시작':'섹션 시작 ('+fmtOffset(off)+')';
          }else{
            time.textContent=isGuess?'~'+fmtSec(pos[segIdx].sec)+' (임시)':'전환 '+fmtSec(pos[segIdx].sec);
          }
          const typeBtn=document.createElement('button');typeBtn.className='btn btn-sm btn-ghost';
          typeBtn.textContent=sd.isInstrumental?'코드만':'가사';
          typeBtn.addEventListener('click',()=>{
            setSlideField(song,sec.sec,sec.occIdx,segIdx,'isInstrumental',!sd.isInstrumental);
            const bl=getBlock(ukey);if(bl)refreshBlock(bl,song,sec,gidx);
          });
          hd.appendChild(dot);hd.appendChild(info);hd.appendChild(time);hd.appendChild(typeBtn);

          // 노트 — 슬라이드 귀속 (뷰어에서 이 슬라이드가 떠 있는 동안 표시)
          const noteP=document.createElement('div');noteP.className='note-pair';noteP.style.marginLeft='auto';
          const snInp=Object.assign(document.createElement('input'),{className:'note-inp-sm',type:'text',placeholder:'세션 노트',value:sd.sessionNote||''});
          const gnInp=Object.assign(document.createElement('input'),{className:'note-inp-sm',type:'text',placeholder:'싱어 노트',value:sd.singerNote||''});
          snInp.addEventListener('input',()=>setSlideField(song,sec.sec,sec.occIdx,segIdx,'sessionNote',snInp.value));
          gnInp.addEventListener('input',()=>setSlideField(song,sec.sec,sec.occIdx,segIdx,'singerNote',gnInp.value));
          noteP.appendChild(snInp);noteP.appendChild(gnInp);
          hd.appendChild(noteP);

          if(st.segData.length>1){
            const delBtn=document.createElement('button');delBtn.className='btn btn-sm btn-red';delBtn.textContent='삭제';
            delBtn.addEventListener('click',()=>{
              const cur=loadState(song,sec.sec,sec.occIdx);
              const segData=cur.segData.map(s=>({...s}));
              segData.splice(segIdx,1);
              setState(song,sec.sec,sec.occIdx,{segData});
              const bl=getBlock(ukey);if(bl)refreshBlock(bl,song,sec,gidx);
            });
            hd.appendChild(delBtn);
          }
          card.appendChild(hd);

          const edArea=document.createElement('div');edArea.className='seg-ed';
          if(sd.isInstrumental){
            renderInstEditor(edArea,song,sec,gidx,segIdx);
          }else{
            const modeRow=document.createElement('div');modeRow.className='mode-row';
            const lyricBtn=document.createElement('button');lyricBtn.className='btn btn-sm'+(ces.chordMode?' btn-ghost':'');lyricBtn.textContent='가사';
            lyricBtn.addEventListener('click',()=>{if(ces.chordMode){ces.chordMode=false;ces.editIdx=null;refreshSegCard(card,song,sec,gidx,segIdx);}});
            const chordBtn=document.createElement('button');chordBtn.className='btn btn-sm'+(ces.chordMode?'':' btn-ghost');chordBtn.textContent='코드 편집';
            chordBtn.addEventListener('click',()=>{
              if(!ces.chordMode){
                const ta=card.querySelector('.lyric-ta');
                if(ta){const cur=loadState(song,sec.sec,sec.occIdx);
                  if(tokensToPlain(cur.segData[segIdx].tokens||[])!==ta.value){setSlideField(song,sec.sec,sec.occIdx,segIdx,'tokens',textToTokens(ta.value));}
                }
                ces.chordMode=true;ces.editIdx=null;refreshSegCard(card,song,sec,gidx,segIdx);
              }
            });
            modeRow.appendChild(lyricBtn);modeRow.appendChild(chordBtn);edArea.appendChild(modeRow);
            if(!ces.chordMode){
              const ta=document.createElement('textarea');ta.className='lyric-ta';
              ta.placeholder='가사를 입력하세요\\nEnter = 줄바꿈';
              ta.value=tokensToPlain(sd.tokens||[]);
              ta.addEventListener('input',()=>{
                setSlideField(song,sec.sec,sec.occIdx,segIdx,'tokens',textToTokens(ta.value));
              });
              edArea.appendChild(ta);
            }else{
              const grid=document.createElement('div');grid.className='chord-grid';
              renderChordGrid(grid,song,sec,gidx,segIdx,ceKey);edArea.appendChild(grid);
            }
          }
          card.appendChild(edArea);
          return card;
        }

        function refreshSegCard(card,song,sec,gidx,segIdx){
          card.replaceWith(createSegCard(song,sec,gidx,segIdx));
        }

        function renderChordGrid(grid,song,sec,gidx,segIdx,ceKey){
          const ces=chordEditState[ceKey];
          const st=loadState(song,sec.sec,sec.occIdx);
          const tokens=st.segData[segIdx]?.tokens||[];
          grid.innerHTML='';
          let line=newTokLine();let lineLastIdx=-1;
          const finishLine=brIdx=>{
            line.appendChild(makeAddGhostBtn(song,sec,gidx,segIdx,ceKey,lineLastIdx>=0?lineLastIdx+1:brIdx));
            grid.appendChild(line);line=newTokLine();lineLastIdx=-1;
          };
          tokens.forEach((t,ti)=>{
            if(t.type==='br'){finishLine(ti+1);}
            else{line.appendChild(makeTokEl(t,ti,song,sec,gidx,segIdx,ceKey));lineLastIdx=ti;}
          });
          finishLine(tokens.length);
        }

        function newTokLine(){const el=document.createElement('div');el.className='tok-line';return el;}

        function makeAddGhostBtn(song,sec,gidx,segIdx,ceKey,at){
          const btn=document.createElement('span');btn.className='add-ghost-btn';btn.textContent='+';
          btn.addEventListener('click',()=>{
            commitChordEdit(song,sec,gidx,segIdx,ceKey);
            const st=loadState(song,sec.sec,sec.occIdx);const segData=[...st.segData];
            const toks=[...(segData[segIdx].tokens||[])];toks.splice(at,0,{type:'ghost'});
            segData[segIdx]={...segData[segIdx],tokens:toks};setState(song,sec.sec,sec.occIdx,{...st,segData});
            const grid=getBlock(ukOf(song,sec.sec,gidx))?.querySelector('.seg-card[data-si="'+segIdx+'"] .chord-grid');
            if(grid)renderChordGrid(grid,song,sec,gidx,segIdx,ceKey);
            setTimeout(()=>openChordInput(song,sec,gidx,segIdx,ceKey,at),0);
          });
          return btn;
        }

        function makeTokEl(t,ti,song,sec,gidx,segIdx,ceKey){
          const ces=chordEditState[ceKey];
          const el=document.createElement('span');el.className='tok tok-'+t.type;
          if(ti===ces.editIdx)el.classList.add('editing');
          if(ti===ces.editIdx){
            const inp=document.createElement('input');inp.className='chord-inp-pop';
            inp.value=t.chord||'';inp.placeholder='코드';
            inp.addEventListener('keydown',e=>handleChordKey(e,ti,inp,song,sec,gidx,segIdx,ceKey));
            inp.addEventListener('compositionend',e=>{
              // 한글 IME 입력 완료 시 → 영문 변환 시도 (한→영 키 매핑)
              const map={'ㅁ':'a','ㄴ':'b','ㅇ':'c','ㄹ':'d','ㅎ':'e','ㅛ':'f','ㅣ':'g','ㅏ':'h','ㅗ':'i','ㅓ':'j','ㅏ':'k','ㅣ':'l','ㅡ':'m','ㄴ':'n','ㅛ':'o','ㅖ':'p','ㅂ':'q','ㄱ':'r','ㄴ':'s','ㅅ':'t','ㅕ':'u','ㅍ':'v','ㅈ':'w','ㅌ':'x','ㅛ':'y','ㅈ':'z'};
              const raw=e.data||'';const mapped=raw.split('').map(c=>map[c]||c).join('');
              const cur=inp.value;const replaced=cur.slice(0,cur.length-raw.length)+mapped;
              inp.value=replaced;inp.dispatchEvent(new Event('input'));
            });
            inp.addEventListener('input',()=>{
              const pos=inp.selectionStart;
              inp.value=inp.value.replace(/[^A-Za-z0-9#♭/]/g,'');
              // 첫 글자 + / 뒤 첫 글자 대문자
              inp.value=inp.value.replace(/^([a-z])/,(m,c)=>c.toUpperCase()).replace(/\\/([a-z])/,(m,c)=>'\\/'+c.toUpperCase());
            });
            inp.addEventListener('blur',()=>{if(ces.editIdx===ti){ces.editIdx=null;confirmChord(song,sec,gidx,segIdx,ceKey,ti,inp.value);}});
            el.appendChild(inp);setTimeout(()=>{inp.focus();inp.select();},0);
          }else if(t.chord){
            const ca=document.createElement('span');ca.className='tok-ca';ca.textContent=t.chord;el.appendChild(ca);
          }
          const ch=document.createElement('span');ch.className='tok-ch';
          ch.textContent=t.type==='ghost'?'·':(t.char===' '?' ':(t.char||''));
          el.appendChild(ch);
          if(t.type==='ghost'){
            const del=document.createElement('span');del.className='tok-del';del.textContent='×';
            del.addEventListener('click',e=>{
              e.stopPropagation();commitChordEdit(song,sec,gidx,segIdx,ceKey);
              const st=loadState(song,sec.sec,sec.occIdx);const segData=[...st.segData];
              const toks=[...(segData[segIdx].tokens||[])];toks.splice(ti,1);
              segData[segIdx]={...segData[segIdx],tokens:toks};setState(song,sec.sec,sec.occIdx,{...st,segData});
              const grid=getBlock(ukOf(song,sec.sec,gidx))?.querySelector('.seg-card[data-si="'+segIdx+'"] .chord-grid');
              if(grid)renderChordGrid(grid,song,sec,gidx,segIdx,ceKey);
            });
            el.appendChild(del);
          }
          el.addEventListener('mousedown',e=>{if(ti!==ces.editIdx){e.preventDefault();openChordInput(song,sec,gidx,segIdx,ceKey,ti);}});
          return el;
        }

        function openChordInput(song,sec,gidx,segIdx,ceKey,ti){
          const ces=chordEditState[ceKey];
          if(ces.editIdx===ti)return;
          if(ces.editIdx!==null){
            const inp=getBlock(ukOf(song,sec.sec,gidx))?.querySelector('.seg-card[data-si="'+segIdx+'"] .chord-inp-pop');
            const v=inp?inp.value:null;const old=ces.editIdx;ces.editIdx=null;
            if(v!==null)confirmChord(song,sec,gidx,segIdx,ceKey,old,v);
          }
          ces.editIdx=ti;
          const grid=getBlock(ukOf(song,sec.sec,gidx))?.querySelector('.seg-card[data-si="'+segIdx+'"] .chord-grid');
          if(grid)renderChordGrid(grid,song,sec,gidx,segIdx,ceKey);
        }

        function commitChordEdit(song,sec,gidx,segIdx,ceKey){
          const ces=chordEditState[ceKey];if(ces.editIdx===null)return;
          const inp=getBlock(ukOf(song,sec.sec,gidx))?.querySelector('.seg-card[data-si="'+segIdx+'"] .chord-inp-pop');
          const v=inp?inp.value:null;const idx=ces.editIdx;ces.editIdx=null;
          if(v!==null)confirmChord(song,sec,gidx,segIdx,ceKey,idx,v);
        }

        function confirmChord(song,sec,gidx,segIdx,ceKey,ti,val){
          const chord=normChord(val);
          const st=loadState(song,sec.sec,sec.occIdx);const segData=[...st.segData];
          const toks=[...(segData[segIdx].tokens||[])];
          if(toks[ti]){toks[ti]={...toks[ti]};if(chord)toks[ti].chord=chord;else delete toks[ti].chord;}
          segData[segIdx]={...segData[segIdx],tokens:toks};setState(song,sec.sec,sec.occIdx,{...st,segData});
          const grid=getBlock(ukOf(song,sec.sec,gidx))?.querySelector('.seg-card[data-si="'+segIdx+'"] .chord-grid');
          if(grid)renderChordGrid(grid,song,sec,gidx,segIdx,ceKey);
        }

        function handleChordKey(e,ti,inp,song,sec,gidx,segIdx,ceKey){
          const ces=chordEditState[ceKey];
          if(e.key==='Enter'||e.key===' '){
            e.preventDefault();ces.editIdx=null;confirmChord(song,sec,gidx,segIdx,ceKey,ti,inp.value);
            const st=loadState(song,sec.sec,sec.occIdx);
            const toks=st.segData[segIdx]?.tokens||[];
            for(let j=ti+1;j<toks.length;j++){if(toks[j].type!=='br'){setTimeout(()=>openChordInput(song,sec,gidx,segIdx,ceKey,j),0);break;}}
          }else if(e.key==='Escape'){
            ces.editIdx=null;
            const grid=getBlock(ukOf(song,sec.sec,gidx))?.querySelector('.seg-card[data-si="'+segIdx+'"] .chord-grid');
            if(grid)renderChordGrid(grid,song,sec,gidx,segIdx,ceKey);
          }else if(e.key==='Tab'){
            e.preventDefault();ces.editIdx=null;confirmChord(song,sec,gidx,segIdx,ceKey,ti,inp.value);
            const st=loadState(song,sec.sec,sec.occIdx);const segData=[...st.segData];
            const toks=[...(segData[segIdx].tokens||[])];toks.splice(ti+1,0,{type:'ghost'});
            segData[segIdx]={...segData[segIdx],tokens:toks};setState(song,sec.sec,sec.occIdx,{...st,segData});
            const grid=getBlock(ukOf(song,sec.sec,gidx))?.querySelector('.seg-card[data-si="'+segIdx+'"] .chord-grid');
            if(grid)renderChordGrid(grid,song,sec,gidx,segIdx,ceKey);
            setTimeout(()=>openChordInput(song,sec,gidx,segIdx,ceKey,ti+1),0);
          }
        }

        function renderInstEditor(ed,song,sec,gidx,segIdx){
          const st=loadState(song,sec.sec,sec.occIdx);
          const existingIC=st.segData[segIdx]?.instChords||[];
          const barCount=Math.max(existingIC.length,4);
          // 항상 "8분음표 해상도"로 통일: 분모가 4(4/4,3/4 등)면 박마다 정박+엇박 2칸,
          // 분모가 8(6/8,9/8,12/8 등)이면 각 박 자체가 이미 8분음표라 1칸씩 — 그래서
          // 마디당 실제 칸 수 = 분자 × (8÷분모). 예전엔 무조건 8칸(4/4 전용)이었음.
          const bpb=sec.beatsPerBar||4, bUnit=sec.beatUnit||4;
          const slotsPerBar=Math.max(1,Math.round(bpb*8/bUnit));
          const subdivided=(bUnit===4);  // 분모 4 계열만 박 안에 정박/엇박 구분이 있음
          const hintRow=document.createElement('div');hintRow.style.cssText='display:flex;align-items:center;gap:10px;margin-bottom:10px';
          const hint=document.createElement('div');hint.style.cssText='font-size:12px;color:var(--sub)';
          hint.textContent='8분음표 그리드 (s=♯, b=♭) · '+barCount+'마디 · '+bpb+'/'+bUnit;
          const setBars=n=>{
            const cur=loadState(song,sec.sec,sec.occIdx);
            const curIC=cur.segData[segIdx]?.instChords||[];
            const newIC=Array(Math.max(1,n)).fill(null).map((_,bi)=>curIC[bi]||[]);
            setSlideField(song,sec.sec,sec.occIdx,segIdx,'instChords',newIC);
            const card=getBlock(ukOf(song,sec.sec,gidx))?.querySelector('.seg-card[data-si="'+segIdx+'"]');
            if(card)refreshSegCard(card,song,sec,gidx,segIdx);
          };
          const minus=document.createElement('button');minus.className='btn btn-sm btn-ghost';minus.textContent='－마디';
          minus.addEventListener('click',()=>setBars(barCount-1));
          const plus=document.createElement('button');plus.className='btn btn-sm btn-ghost';plus.textContent='＋마디';
          plus.addEventListener('click',()=>setBars(barCount+1));
          hintRow.appendChild(hint);hintRow.appendChild(minus);hintRow.appendChild(plus);
          ed.appendChild(hintRow);
          const table=document.createElement('div');table.className='inst-table';
          const hdr=document.createElement('div');hdr.className='inst-row';
          const hl=document.createElement('div');hl.className='inst-bar-lbl';hdr.appendChild(hl);
          const hdrLabels=[];
          for(let i=1;i<=bpb;i++){hdrLabels.push(String(i));if(subdivided)hdrLabels.push('+');}
          hdrLabels.forEach(lbl=>{const l=document.createElement('div');l.className='inst-beat-hdr';l.textContent=lbl;hdr.appendChild(l);});
          table.appendChild(hdr);
          for(let b=0;b<barCount;b++){
            const barSlots=existingIC[b]||[];
            const row=document.createElement('div');row.className='inst-row';
            const lbl=document.createElement('div');lbl.className='inst-bar-lbl';lbl.textContent='마디 '+(b+1);row.appendChild(lbl);
            for(let beat=0;beat<slotsPerBar;beat++){
              const slot=barSlots.find(s=>s.pos===beat);
              const cell=document.createElement('div');cell.className='inst-beat-'+(!subdivided||beat%2===0?'on':'off');
              const inp=document.createElement('input');inp.className='inst-beat-inp';inp.type='text';
              inp.value=slot?slot.name:'';inp.placeholder='';
              inp.addEventListener('focus',()=>inp.select());
              // change(blur 시점)에만 의존하면 일부 브라우저/모바일 환경에서 커밋이 안 되는
              // 경우가 있어(코드만 슬라이드가 저장 안 되던 버그의 원인) input마다 바로 상태에 반영
              const commitInstChord=()=>{
                inp.value=inp.value.replace(/[^A-Za-z0-9#♭/]/g,'');
                inp.value=normChord(inp.value);
                const cur=loadState(song,sec.sec,sec.occIdx);
                const curIC=cur.segData[segIdx]?.instChords||[];
                const newIC=Array(barCount).fill(null).map((_,bi)=>{
                  const arr=[...(curIC[bi]||[])];
                  if(bi===b){const f=arr.filter(s=>s.pos!==beat);const v=inp.value;if(v)f.push({pos:beat,name:v});return f.sort((a,c)=>a.pos-c.pos);}
                  return arr;
                });
                setSlideField(song,sec.sec,sec.occIdx,segIdx,'instChords',newIC);
              };
              inp.addEventListener('input',commitInstChord);
              inp.addEventListener('blur',commitInstChord);
              cell.appendChild(inp);row.appendChild(cell);
            }
            table.appendChild(row);
          }
          ed.appendChild(table);
        }

        // dirty 키("song|||sec@@occIdx") 파싱
        function parseDk(k){
          const sep=k.indexOf('|||');
          const song=k.slice(0,sep);
          const rest=k.slice(sep+3);
          const at=rest.lastIndexOf('@@');
          return{song,sec:rest.slice(0,at),occIdx:parseInt(rest.slice(at+2))};
        }

        // 상태 → 저장용 슬라이드 배열 (startSec 포함, startBar는 순서 보존용 레거시 값)
        function slidesOf(st){
          return st.segData.map((sd,i)=>({
            startSec:sd.startSec==null?null:sd.startSec,
            startBar:i,
            barCount:sd.isInstrumental?(sd.instChords||[]).length:0,
            isInstrumental:!!sd.isInstrumental,
            tokens:sd.isInstrumental?[]:(sd.tokens||[]),
            instChords:sd.isInstrumental?(sd.instChords||[]):[],
            singerNote:sd.singerNote||'',
            sessionNote:sd.sessionNote||''
          }));
        }

        function sectionPayload(song,sec){
          const st=loadState(song,sec.sec,sec.occIdx);
          const slides=slidesOf(st);
          const plain=tokensToPlain(st.segData[0]?.tokens||[]);
          // 섹션 레벨 노트는 첫 슬라이드 노트를 미러링 (구버전 뷰어/데이터 호환용)
          return{lyricCue:plain.split('\\n')[0]||'',
                 sessionNote:st.segData[0]?.sessionNote||'',
                 singerNote:st.segData[0]?.singerNote||'',
                 slides,linked:false,totalBars:Math.max(sec.totalBars||0,0)};
        }

        function saveAll(){
          const payload={};
          // 모든 섹션을 현재 편집 상태(loadState: dirty 우선, 아니면 원본)로 전송
          DATA.forEach(songData=>{
            payload[songData.song]={};
            (songData.sections||[]).forEach(sec=>{
              payload[songData.song][sec.sec+'@@'+sec.occIdx]=sectionPayload(songData.song,sec);
            });
          });
          fetch('/save',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)})
            .then(r=>r.json())
            .then(()=>{
              // 저장 성공: 서버에 반영된 내용을 로컬 DATA에도 병합
              for(const[song,secs]of Object.entries(payload)){
                const d=DATA.find(s=>s.song===song);if(!d)continue;
                for(const[occKey,val]of Object.entries(secs)){
                  const ii=occKey.lastIndexOf('@@');if(ii<0)continue;
                  const sec=occKey.slice(0,ii);const occIdx=parseInt(occKey.slice(ii+2))||0;
                  const ds=d.sections.find(s=>s.sec===sec&&(s.occIdx??0)===occIdx);if(!ds)continue;
                  ds.slides=val.slides||[];
                  ds.sessionNote=val.sessionNote||'';
                  ds.singerNote=val.singerNote||'';
                  ds.linked=false;
                }
              }
              for(const k in dirty)delete dirty[k];
              renderSidebar();showMsg('뷰어에 적용됐어요!');
            }).catch(()=>showMsg('적용 실패'));
        }

        function showMsg(m){const el=$('save-msg');el.textContent=m;el.style.opacity='1';setTimeout(()=>el.style.opacity='0',2200);}

        // ── HTML 내보내기/가져오기 ──
        function buildExportData(song){
          const s=DATA.find(d=>d.song===song);
          if(!s)return null;
          const sections=s.sections.map(sec=>{
            const st=loadState(song,sec.sec,sec.occIdx);
            return{sec:sec.sec,occIdx:sec.occIdx,totalBars:sec.totalBars,durationSec:sec.durationSec||0,slides:slidesOf(st)};
          });
          return[{song,countdownBars:s.countdownBars??1,sections}];
        }

        async function buildStandaloneHtml(exportData,filename){
          const dataJson=JSON.stringify(exportData);
          let html;
          if(STANDALONE){
            html=document.documentElement.outerHTML;
            if(!html.startsWith('<!DOCTYPE'))html='<!DOCTYPE html>'+html;
          } else {
            const resp=await fetch('/edit');
            html=await resp.text();
          }
          html=html.replace(/const DATA=[^;]*;\\/\\/EXPORT_DATA_LINE/,()=>'const DATA='+dataJson+';//EXPORT_DATA_LINE');
          html=html.replace('const STANDALONE=false;//EXPORT_STANDALONE_LINE','const STANDALONE=true;//EXPORT_STANDALONE_LINE');
          html=html.replace(/const EXPORT_FILENAME='[^']*';\\/\\/EXPORT_FILENAME_LINE/,()=>"const EXPORT_FILENAME='"+(filename||'')+"';//EXPORT_FILENAME_LINE");
          return html;
        }

        async function exportSongAsHtml(song){
          const exportData=buildExportData(song);
          if(!exportData)return;
          const html=await buildStandaloneHtml(exportData,song);
          const blob=new Blob([html],{type:'text/html;charset=utf-8'});
          const a=document.createElement('a');
          a.href=URL.createObjectURL(blob);
          a.download=song.replace(/[\\s/]/g,'_')+'.html';
          a.click();
          showMsg(song+' 내보내기 완료!');
        }

        async function exportForTeam(){
          const date=prompt('예배 날짜를 입력하세요 (예: 20260628)','');
          if(date===null)return;
          const allSongs=[...new Set(DATA.map(s=>s.song))];
          const exportData=allSongs.flatMap(song=>buildExportData(song)||[]);
          if(!exportData.length){showMsg('곡 데이터 없음');return;}
          const fname=(date?date+'_':'')+'가사편집';
          const html=await buildStandaloneHtml(exportData,fname);
          const blob=new Blob([html],{type:'text/html;charset=utf-8'});
          const a=document.createElement('a');
          a.href=URL.createObjectURL(blob);
          a.download=fname+'.html';
          a.click();
          showMsg('내보내기 완료!');
        }

        async function standaloneDownload(){
          const allSongs=[...new Set(DATA.map(s=>s.song))];
          const exportData=allSongs.flatMap(song=>buildExportData(song)||[]);
          if(!exportData.length)return;
          const html=await buildStandaloneHtml(exportData);
          const blob=new Blob([html],{type:'text/html;charset=utf-8'});
          const a=document.createElement('a');
          a.href=URL.createObjectURL(blob);
          a.download=(EXPORT_FILENAME||'가사편집')+'_편집완료.html';
          a.click();
          showMsg('저장됐어요!');
        }

        // 구버전 파일 호환: 필드 누락 시 기본값으로 채움 (마디 기반 구버전은 startSec null → 임시 위치로 표시)
        function fixSlides(slides){return(slides||[]).map(sl=>({startBar:sl.startBar||0,barCount:sl.barCount||0,startSec:(sl.startSec===undefined?null:sl.startSec),isInstrumental:sl.isInstrumental||false,tokens:(sl.tokens||[]).map(t=>({type:t.type||'char',char:t.char??null,chord:t.chord??null})),instChords:sl.instChords||[],singerNote:sl.singerNote||'',sessionNote:sl.sessionNote||''}));}

        function handleImportFile(file,targetSongName){
          if(!file)return;
          const reader=new FileReader();
          reader.onload=e=>{
            const html=e.target.result;
            const startMark='const DATA=';const endMark=';//EXPORT_DATA_LINE';
            const si=html.indexOf(startMark);const ei=html.indexOf(endMark);
            if(si<0||ei<0){showMsg('파일 형식 오류');return;}
            let importedData;
            try{importedData=JSON.parse(html.slice(si+startMark.length,ei));}catch{showMsg('파싱 오류');return;}
            // /save 호출 없이 로컬 DATA만 업데이트 — 뷰어 적용 버튼으로만 서버에 반영
            // 노트(세션/싱어)는 덮어쓰지 않고 병합: 파일에 값이 있으면 채우고, 없으면 기존 값 유지
            const importedSongs=new Set();
            const mergeSec=(destSec,srcSec)=>{
              destSec.slides=fixSlides(srcSec.slides);
              destSec.sessionNote=srcSec.sessionNote||destSec.sessionNote||'';
              destSec.singerNote=srcSec.singerNote||destSec.singerNote||'';
              destSec.linked=false;
            };
            // 카운트다운 설정은 즉시 저장 필드라 가져오기에서도 바로 서버에 반영
            const mergeCountdown=(dest,srcSong)=>{
              if(srcSong.countdownBars==null)return;
              dest.countdownBars=srcSong.countdownBars;
              fetch('/save-song-meta',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({song:dest.song,countdownBars:srcSong.countdownBars})});
            };
            if(targetSongName){
              const srcSong=importedData.find(s=>s.song===targetSongName)||importedData[0];
              if(!srcSong){showMsg('데이터 없음');return;}
              const dest=DATA.find(s=>s.song===targetSongName);
              if(!dest){showMsg('현재 세트리스트에 없는 곡');return;}
              srcSong.sections.forEach(srcSec=>{
                const destSec=dest.sections.find(s=>s.sec===srcSec.sec&&(s.occIdx??0)===(srcSec.occIdx??0));
                if(destSec)mergeSec(destSec,srcSec);
              });
              mergeCountdown(dest,srcSong);
              importedSongs.add(targetSongName);
            } else {
              importedData.forEach(importSong=>{
                const dest=DATA.find(s=>s.song===importSong.song);
                if(!dest)return;
                importSong.sections.forEach(srcSec=>{
                  const destSec=dest.sections.find(s=>s.sec===srcSec.sec&&(s.occIdx??0)===(srcSec.occIdx??0));
                  if(destSec)mergeSec(destSec,srcSec);
                });
                mergeCountdown(dest,importSong);
                importedSongs.add(importSong.song);
              });
            }
            // 노트 입력창 캐시(secUI)가 옛 값으로 남아있으면 화면이 안 갱신되니 비워서
            // 다음 렌더에서 병합된 최신 값(DATA)을 다시 읽어오게 함
            Object.keys(secUI).forEach(ukey=>{
              if(importedSongs.has(ukey.split('|||')[0])){
                delete secUI[ukey].sessionNote;
                delete secUI[ukey].singerNote;
              }
            });
            if(importedSongs.has(curSong))renderSections(curSong);
            renderSidebar();
            showMsg('가져왔어요! 뷰어 적용을 눌러주세요.');
          };
          reader.readAsText(file);
        }

        // ── 드래그앤드롭 ──
        let pendingImportSong=null;
        const mainEl=$('main');
        mainEl.addEventListener('dragover',e=>{e.preventDefault();e.stopPropagation();mainEl.classList.add('drop-hover');});
        mainEl.addEventListener('dragleave',e=>{if(!mainEl.contains(e.relatedTarget))mainEl.classList.remove('drop-hover');});
        mainEl.addEventListener('drop',e=>{
          e.preventDefault();e.stopPropagation();mainEl.classList.remove('drop-hover');
          const file=[...e.dataTransfer.files].find(f=>f.name.endsWith('.html'));
          if(!file){showMsg('.html 파일만 가져올 수 있어요');return;}
          handleImportFile(file,curSong||null);
        });
        document.addEventListener('dragover',e=>{e.preventDefault();});
        document.addEventListener('drop',e=>{e.preventDefault();});

        // ── 실시간 연동: 재생 위치 표시 / 재생 따라가기 / 넘김 지점 기록 ──
        // 곡 내 절대 위치(초) 기준으로 통일 — 섹션 경계(마커)와 무관하게 연속 진행
        let lastState=null,lastStateAt=0;
        let tapCtx={song:null,cursor:1,prevAbs:0};

        // SSE 상태 + 수신 후 경과 시간으로 현재 재생 위치를 보간, 곡 내 절대 초로 환산
        function liveAbsSec(info){
          if(!lastState||!info)return null;
          const e=lastState.sectionElapsedSec??0;
          const elapsed=lastState.isPlaying?e+(Date.now()-lastStateAt)/1000:e;
          return(info.sec.startInSong||0)+elapsed;
        }
        function playingSecInfo(){
          if(!lastState)return null;
          const song=(lastState.songs||[])[lastState.currentSongIndex];
          const secIdx=lastState.currentSectionIndexInSong??-1;
          if(!song||secIdx<0)return null;
          const songData=DATA.find(s=>s.song===song);
          const sec=songData?songData.sections[secIdx]:null;
          if(!sec)return null;
          return{song,secIdx,sec};
        }
        // 다음에 찍을 경계(곡 전체 슬라이드 목록 인덱스 g) = 이미 확정된 경계 중 현재 위치보다
        // 앞에 있는 것들 다음. 곡 전환·뒤로 점프 때마다 재계산 → 처음부터 다시 들으면 1번부터 재기록.
        function computeTapCursor(song,absSec){
          const list=songSlideList(song);
          let cnt=0;
          for(let g=1;g<list.length;g++){
            const it=list[g];
            const st=loadState(song,it.sec.sec,it.sec.occIdx);
            if(st.segData[it.si].startSec!=null&&it.abs<=absSec)cnt=g;
          }
          return cnt+1;
        }
        function onStateMsg(s){
          lastState=s;lastStateAt=Date.now();
          const info=playingSecInfo();
          const absSec=info?liveAbsSec(info):null;
          if(info){
            if(info.song!==tapCtx.song||absSec<tapCtx.prevAbs-1.5){
              tapCtx={song:info.song,cursor:computeTapCursor(info.song,absSec),prevAbs:absSec};
            }else tapCtx.prevAbs=absSec;
          }
          $('now-playing').textContent=info?('▶ '+info.song+' · '+info.sec.sec+(s.isPlaying?'':' (정지)')):'';
          // 따라가기: 다른 곡 재생 시 자동 곡 전환
          if(info&&$('follow-chk').checked&&curSong!==info.song)selectSong(info.song);
          // 연주 중 섹션 블록 하이라이트 (+따라가기 시 스크롤)
          document.querySelectorAll('.sec-block.playing').forEach(el=>el.classList.remove('playing'));
          if(info&&curSong===info.song){
            const bl=getBlock(ukOf(info.song,info.sec.sec,info.secIdx));
            if(bl){
              bl.classList.add('playing');
              if($('follow-chk').checked&&s.isPlaying&&!bl._scrolled){bl._scrolled=true;bl.scrollIntoView({behavior:'smooth',block:'nearest'});}
            }
          }
        }
        // 재생헤드 라인 + 현재 표시 중 슬라이드 하이라이트 (매 프레임 보간, 곡 타임라인 기준)
        function tickPlayhead(){
          requestAnimationFrame(tickPlayhead);
          const info=playingSecInfo();
          const rail=document.querySelector('#song-tl .tl-rail');
          const ph=rail?rail.querySelector('.tl-playhead'):null;
          document.querySelectorAll('.tl-slide.playing-slide,.seg-card.playing-slide').forEach(el=>el.classList.remove('playing-slide'));
          if(ph)ph.style.display='none';
          if(!info||curSong!==info.song||!rail)return;
          const list=songSlideList(info.song);
          if(!list.length)return;
          const songDur=songDuration(info.song);
          const effDur=songDur>0?songDur:(list[list.length-1].abs+8);
          const t=Math.min(liveAbsSec(info)??0,effDur);
          ph.style.display='block';
          ph.style.top=(t/effDur*rail.clientHeight)+'px';
          // 따라가기 켜짐 + 재생 중: 타임라인 자체 스크롤을 재생헤드가 항상 보이게 유지
          // (카드 쪽 자동 스크롤과 별개 — 타임라인은 sticky라 카드를 내려도 화면에 남아있음)
          if($('follow-chk').checked&&lastState.isPlaying){
            const container=$('song-tl');
            container.scrollTop=Math.max(0,ph.offsetTop-container.clientHeight/2);
          }
          let gi=0;for(let g=0;g<list.length;g++){if(list[g].abs<=t)gi=g;}
          const it=list[gi];
          const tlBlock=rail.querySelector('.tl-slide[data-g="'+gi+'"]');
          if(tlBlock)tlBlock.classList.add('playing-slide');
          const cardEl=getBlock(ukOf(info.song,it.sec.sec,it.secIdx))?.querySelector('.seg-card[data-si="'+it.si+'"]');
          if(cardEl)cardEl.classList.add('playing-slide');
        }
        // 넘김 지점 기록: 버튼/Enter를 누른 "지금 이 순간"이 다음 슬라이드로 넘어가는 시점이 됨.
        // 섹션 첫 슬라이드 경계도 포함 — 마커를 막 지났을 때 누르면 그 섹션 첫 슬라이드가 정확히 지금 뜨도록 기록됨.
        function tap(){
          const info=playingSecInfo();
          if(!info||!lastState.isPlaying){showMsg('재생 중이 아니에요');return;}
          const list=songSlideList(info.song);
          const g=tapCtx.cursor;
          if(g>=list.length){showMsg('곡의 마지막 슬라이드예요');return;}
          const it=list[g];
          const songDur=songDuration(info.song);
          let t=liveAbsSec(info)??0;
          // 이웃의 이미 확정된 위치를 넘지 않게 보정
          let prevStamped=list[0].abs;
          for(let k=g-1;k>=1;k--){const kk=list[k];const st=loadState(info.song,kk.sec.sec,kk.sec.occIdx);if(st.segData[kk.si].startSec!=null){prevStamped=kk.abs;break;}}
          t=Math.max(prevStamped+0.1,t);
          for(let k=g+1;k<list.length;k++){const kk=list[k];const st=loadState(info.song,kk.sec.sec,kk.sec.occIdx);if(st.segData[kk.si].startSec!=null){t=Math.min(t,kk.abs-0.1);break;}}
          if(songDur>0)t=Math.min(t,songDur-0.05);
          const st=loadState(info.song,it.sec.sec,it.sec.occIdx);
          const segData=st.segData.map(s=>({...s}));
          segData[it.si].startSec=Math.round((t-(it.sec.startInSong||0))*100)/100;
          setState(info.song,it.sec.sec,it.sec.occIdx,{segData});
          tapCtx.cursor=g+1;
          const btn=$('tap-btn');btn.classList.remove('flash');void btn.offsetWidth;btn.classList.add('flash');
          showMsg('슬라이드 '+(g)+'→'+(g+1)+' 넘김 '+fmtSec(t)+' 기록');
          if(curSong===info.song){
            const bl=getBlock(ukOf(info.song,it.sec.sec,it.secIdx));
            if(bl)refreshBlock(bl,info.song,it.sec,it.secIdx);
            else renderSongTimeline(info.song);
          }
        }

        if(!STANDALONE){
          $('tap-btn').addEventListener('click',tap);
          document.addEventListener('keydown',e=>{
            if(e.key!=='Enter')return;
            const tag=(document.activeElement?.tagName||'').toLowerCase();
            if(tag==='input'||tag==='textarea'||document.activeElement?.isContentEditable)return;
            e.preventDefault();tap();
          });
          const esLive=new EventSource('/events');
          esLive.onmessage=e=>{try{onStateMsg(JSON.parse(e.data));}catch{}};
          tickPlayhead();
        }else{
          $('tap-btn').style.display='none';
          $('follow-wrap').style.display='none';
          $('now-playing').style.display='none';
        }

        if(STANDALONE){
          const bi=$('btn-import');if(bi)bi.style.display='none';
          const be=$('btn-export');if(be)be.style.display='none';
          // 안내 배너
          const banner=document.createElement('div');
          banner.style.cssText='background:#fff8e1;border-bottom:1px solid #ffe082;padding:10px 20px;font-size:13px;color:#7a5c00;flex-shrink:0;display:flex;align-items:center;gap:8px';
          banner.innerHTML='<span>✏️</span><span>가사를 편집하고 <b>저장</b> 버튼을 누르면 편집 완료 파일이 다운로드됩니다. 그 파일을 리더에게 보내주세요.</span>';
          document.body.insertBefore(banner,document.getElementById('layout'));
        }

        renderSidebar();
        </script>
        </body>
        </html>
        """
    }

    // MARK: - /save  (POST JSON)

    private func handleSave(_ conn: NWConnection, body: Data) {
        // 임시 진단 로그: 간주 코드가 저장 안 되는 문제 추적용 (원인 확인 후 제거 예정)
        if let raw = String(data: body, encoding: .utf8), raw.contains("instChords") {
            debugLog("[SaveDebug] body=\(raw)")
        }
        if let decoded = try? JSONDecoder().decode([String: [String: SectionData]].self, from: body) {
            saveLyrics?(decoded)
            onLyricsSaved?()
            broadcaster.send("event: lyrics-updated\ndata: {}\n\n")
        } else {
            debugLog("[SaveDebug] JSON 디코드 실패")
        }
        send(conn, body: Data("{\"ok\":true}".utf8), contentType: "application/json")
    }

    // MARK: - /save-song-meta  (곡별 카운트다운 표시 시작 등, 즉시 저장)

    private struct SongMetaPayload: Decodable { let song: String; let countdownBars: Int }

    private func handleSaveSongMeta(_ conn: NWConnection, body: Data) {
        if let decoded = try? JSONDecoder().decode(SongMetaPayload.self, from: body) {
            saveSongCountdownBars?(decoded.song, decoded.countdownBars)
        }
        send(conn, body: Data("{\"ok\":true}".utf8), contentType: "application/json")
    }

    // MARK: - /export/setlist

    private func handleExportSetlist(_ conn: NWConnection) {
        let markers = getMarkers?() ?? []
        let data = (exportSetlist?(markers) ?? Data())
        sendDownload(conn, data: data, filename: "setlist.json")
    }

    // MARK: - /export/song/{name}

    private func handleExportSong(_ conn: NWConnection, path: String) {
        let encoded = String(path.dropFirst("/export/song/".count))
        let name = encoded.removingPercentEncoding ?? encoded
        let data = (exportSong?(name) ?? Data())
        let safe = name.replacingOccurrences(of: "/", with: "_")
        sendDownload(conn, data: data, filename: "\(safe).json")
    }

    // MARK: - /export.csv

    private func handleExportCSV(_ conn: NWConnection) {
        let markers = getMarkers?() ?? []
        var csv = "Song,Section,LyricCue,Note\n"
        var currentSong = ""
        for m in markers {
            if m.isSong { currentSong = m.displayName }
            else {
                let d = getLyric?(currentSong, m.displayName)
                let lc = csvEsc(d?.lyricCue ?? "")
                let nt = csvEsc(d?.sessionNote ?? "")
                csv += "\(csvEsc(currentSong)),\(csvEsc(m.displayName)),\(lc),\(nt)\n"
            }
        }
        let data = csv.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/csv; charset=utf-8\r\nContent-Disposition: attachment; filename=\"lyrics.csv\"\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var response = header.data(using: .utf8)!
        response.append(data)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - /import.csv

    private func handleImportCSV(_ conn: NWConnection, body: Data) {
        let csv = String(data: body, encoding: .utf8) ?? ""
        let rows = csv.components(separatedBy: "\n").dropFirst() // skip header
        for row in rows {
            let cols = parseCSVRow(row)
            guard cols.count >= 4 else { continue }
            let (song, sec, lc, nt) = (cols[0], cols[1], cols[2], cols[3])
            guard !song.isEmpty, !sec.isEmpty else { continue }
            saveLyrics?([song: [sec: SectionData(lyricCue: lc, sessionNote: nt)]])
        }
        onLyricsSaved?()
        send(conn, body: Data("{\"ok\":true}".utf8), contentType: "application/json")
    }

    // MARK: - Helpers

    private func sendDownload(_ conn: NWConnection, data: Data, filename: String) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Disposition: attachment; filename=\"\(filename)\"\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var response = header.data(using: .utf8)!
        response.append(data)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func send(_ conn: NWConnection, body: Data, contentType: String) {
        // no-store: 앱 업데이트 후 브라우저가 옛 HTML/JS를 캐시로 보여주는 문제 방지
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = header.data(using: .utf8)!
        response.append(body)
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func csvEsc(_ s: String) -> String {
        let needs = s.contains(",") || s.contains("\"") || s.contains("\n")
        if needs { return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return s
    }

    private func parseCSVRow(_ row: String) -> [String] {
        var cols: [String] = []
        var cur = ""
        var inQuotes = false
        var i = row.startIndex
        while i < row.endIndex {
            let c = row[i]
            if c == "\"" {
                let next = row.index(after: i)
                if inQuotes && next < row.endIndex && row[next] == "\"" {
                    cur.append("\""); i = row.index(after: next); continue
                }
                inQuotes.toggle()
            } else if c == "," && !inQuotes {
                cols.append(cur); cur = ""
            } else {
                cur.append(c)
            }
            i = row.index(after: i)
        }
        cols.append(cur)
        return cols
    }

    // MARK: - HTML loading

    private func loadHTML() {
        if let url = Bundle.main.url(forResource: "index", withExtension: "html"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            bandContent = content
        } else {
            bandContent = "<html><body><h1>index.html not found</h1></body></html>"
        }
        if let url = Bundle.main.url(forResource: "singer", withExtension: "html"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            singerContent = content
        } else {
            singerContent = "<html><body><h1>singer.html not found</h1></body></html>"
        }
    }
}
