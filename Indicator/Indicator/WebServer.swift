import Foundation
import Network

class WebServer {

    private var listener: NWListener?
    private let broadcaster = SSEBroadcaster()
    private var htmlContent: String = ""

    // Wired up by AppDelegate after init
    var getMarkers: (() -> [Marker])? = nil
    var getLyric: ((_ song: String, _ section: String) -> SectionData?)? = nil
    var saveLyrics: ((_ dict: [String: [String: SectionData]]) -> Void)? = nil
    var exportSetlist: ((_ markers: [Marker]) -> Data?)? = nil
    var exportSong: ((_ name: String) -> Data?)? = nil
    var getSongNames: (() -> [String])? = nil
    var onLyricsSaved: (() -> Void)? = nil

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
        case ("GET", "/edit"):                        handleEdit(conn)
        case ("POST", "/save"):                       handleSave(conn, body: body)
        case ("GET", "/export/setlist"):              handleExportSetlist(conn)
        case _ where path.hasPrefix("/export/song/"): handleExportSong(conn, path: path)
        case ("GET", "/export.csv"):                  handleExportCSV(conn)
        case ("POST", "/import.csv"):                 handleImportCSV(conn, body: body)
        default:                                      handleHTML(conn)
        }
    }

    // MARK: - Main page

    private func handleHTML(_ conn: NWConnection) {
        send(conn, body: htmlContent.data(using: .utf8) ?? Data(), contentType: "text/html; charset=utf-8")
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
        // Build song→sections structure
        var songs: [(name: String, sections: [String])] = []
        var currentSong: String? = nil
        for m in markers {
            if m.isSong {
                currentSong = m.displayName
                songs.append((name: m.displayName, sections: []))
            } else if currentSong != nil {
                songs[songs.count - 1].sections.append(m.displayName)
            }
        }

        var rows = ""
        for song in songs {
            rows += "<tr><td colspan='4' class='song-header'>\(esc(song.name))</td></tr>\n"
            for sec in song.sections {
                let d  = getLyric?(song.name, sec)
                let lc = esc(d?.lyricCue ?? "")
                let nt = esc(d?.note ?? "")
                rows += """
                <tr>
                  <td class='sec'>\(esc(sec))</td>
                  <td><input name='lc' data-song='\(esc(song.name))' data-sec='\(esc(sec))' value='\(lc)' placeholder='가사 첫 줄'></td>
                  <td><input name='nt' data-song='\(esc(song.name))' data-sec='\(esc(sec))' value='\(nt)' placeholder='연주 노트'></td>
                </tr>\n
                """
            }
        }

        return """
        <!DOCTYPE html>
        <html lang='ko'>
        <head>
        <meta charset='UTF-8'>
        <meta name='viewport' content='width=device-width, initial-scale=1'>
        <title>Indicator 편집</title>
        <style>
          * { box-sizing: border-box; margin: 0; padding: 0; }
          body { font-family: -apple-system, sans-serif; background: #f5f5f7; padding: 20px; }
          h1 { font-size: 20px; margin-bottom: 16px; color: #1d1d1f; }
          table { width: 100%; border-collapse: collapse; background: #fff; border-radius: 12px; overflow: hidden; box-shadow: 0 1px 4px rgba(0,0,0,.1); }
          th { background: #1d1d1f; color: #fff; padding: 10px 12px; text-align: left; font-size: 13px; }
          td { padding: 8px 12px; border-bottom: 1px solid #e5e5ea; font-size: 14px; }
          .song-header { background: #e5e5ea; font-weight: 700; font-size: 15px; color: #1d1d1f; }
          .sec { color: #555; min-width: 80px; }
          input { width: 100%; border: 1px solid #d1d1d6; border-radius: 6px; padding: 6px 10px; font-size: 14px; outline: none; }
          input:focus { border-color: #007aff; }

          .btn { display: inline-block; margin-top: 16px; padding: 10px 28px; background: #007aff; color: #fff; border: none; border-radius: 10px; font-size: 16px; font-weight: 600; cursor: pointer; }
          .btn:active { background: #0062cc; }
          #msg { margin-top: 12px; color: #34c759; font-weight: 600; font-size: 14px; display: none; }
          .csv-section { margin-top: 24px; background: #fff; border-radius: 12px; padding: 16px; box-shadow: 0 1px 4px rgba(0,0,0,.1); }
          .csv-section h2 { font-size: 15px; margin-bottom: 12px; color: #1d1d1f; }
          .csv-row { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
          .btn-sm { padding: 8px 18px; font-size: 14px; background: #5856d6; }
          .btn-sm.green { background: #34c759; }
        </style>
        </head>
        <body>
        <h1>가사 · 연주 노트 편집</h1>
        <table>
          <thead><tr><th>섹션</th><th>가사 (첫 줄)</th><th>연주 노트</th></tr></thead>
          <tbody>\(rows)</tbody>
        </table>
        <button class='btn' onclick='save()'>저장</button>
        <div id='msg'>✓ 저장됐어요!</div>

        <div class='csv-section'>
          <h2>내보내기</h2>
          <div class='csv-row'>
            <a href='/export/setlist' class='btn btn-sm'>이번 세트리스트</a>
            \(buildSongExportButtons(songs: songs))
          </div>
        </div>

        <div class='csv-section'>
          <h2>Google Sheets 연동</h2>
          <div class='csv-row'>
            <a href='/export.csv' class='btn btn-sm'>CSV 내보내기 (Sheets용)</a>
            <span style='color:#888;font-size:13px'>→ Google Sheets에서 편집 후 CSV로 다운로드 →</span>
            <label class='btn btn-sm green' style='cursor:pointer'>
              CSV 가져오기
              <input type='file' accept='.csv' style='display:none' onchange='importCSV(this)'>
            </label>
          </div>
        </div>

        <script>
        function save() {
          const payload = {};
          document.querySelectorAll('input[name=lc]').forEach(el => {
            const song = el.dataset.song, sec = el.dataset.sec;
            if (!payload[song]) payload[song] = {};
            if (!payload[song][sec]) payload[song][sec] = { lyricCue: '', note: '' };
            // 중복 섹션명이 있을 때 빈 값이 기존 값을 덮어쓰지 않도록
            if (el.value || !payload[song][sec].lyricCue) payload[song][sec].lyricCue = el.value;
          });
          document.querySelectorAll('input[name=nt]').forEach(el => {
            const song = el.dataset.song, sec = el.dataset.sec;
            if (!payload[song]) payload[song] = {};
            if (!payload[song][sec]) payload[song][sec] = { lyricCue: '', note: '' };
            if (el.value || !payload[song][sec].note) payload[song][sec].note = el.value;
          });
          fetch('/save', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(payload) })
            .then(() => { const m = document.getElementById('msg'); m.style.display='block'; setTimeout(()=>m.style.display='none', 2000); });
        }

        function importCSV(input) {
          const file = input.files[0]; if (!file) return;
          const reader = new FileReader();
          reader.onload = e => {
            fetch('/import.csv', { method:'POST', headers:{'Content-Type':'text/plain'}, body: e.target.result })
              .then(() => location.reload());
          };
          reader.readAsText(file);
        }
        </script>
        </body></html>
        """
    }

    // MARK: - /save  (POST JSON)

    private func handleSave(_ conn: NWConnection, body: Data) {
        print("[Save] body bytes: \(body.count)")
        print("[Save] body: \(String(data: body, encoding: .utf8) ?? "<invalid utf8>")")
        if let decoded = try? JSONDecoder().decode([String: [String: SectionData]].self, from: body) {
            print("[Save] decoded OK: \(decoded)")
            saveLyrics?(decoded)
            onLyricsSaved?()
        } else {
            print("[Save] decode FAILED")
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
                let nt = csvEsc(d?.note ?? "")
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
            saveLyrics?([song: [sec: SectionData(lyricCue: lc, note: nt)]])
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
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
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
            htmlContent = content
        } else {
            htmlContent = "<html><body><h1>index.html not found</h1></body></html>"
        }
    }
}
