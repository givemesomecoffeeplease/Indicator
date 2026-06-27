import Foundation
import Network

class WebServer {

    private var listener: NWListener?
    private let broadcaster = SSEBroadcaster()
    private var bandContent: String = ""
    private var singerContent: String = ""

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
        case ("GET", "/band"):                        handleBand(conn)
        case ("GET", "/singer"):                      handleSinger(conn)
        case ("GET", "/api/sections"):                handleSections(conn)
        case ("GET", "/edit"):                        handleEdit(conn)
        case ("POST", "/save"):                       handleSave(conn, body: body)
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
            else { result.append(["song": currentSong, "section": m.displayName, "bar": m.bar]) }
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
        // Helper: LyricToken array → editable [chord]text string
        func tokenText(_ tokens: [LyricToken]) -> String {
            tokens.map { t in
                switch t.type {
                case .br:    return "\n"
                case .ghost: return t.chord.map { "[\($0)]" } ?? ""
                case .char:
                    let pfx = t.chord.map { "[\($0)]" } ?? ""
                    return pfx + (t.char ?? "")
                }
            }.joined()
        }

        // JSON string escape
        func j(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
             .replacingOccurrences(of: "\n", with: "\\n")
             .replacingOccurrences(of: "\r", with: "")
             .replacingOccurrences(of: "\t", with: "\\t")
        }

        // Build songs data with existing lyrics
        var songs: [(name: String, sections: [(sec: String, text: String, note: String)])] = []
        var curSong = ""
        for m in markers {
            if m.isSong {
                curSong = m.displayName
                songs.append((name: curSong, sections: []))
            } else if !curSong.isEmpty {
                let d = getLyric?(curSong, m.displayName)
                var text = ""
                if let tokens = d?.slides.first?.tokens, !tokens.isEmpty {
                    text = tokenText(tokens)
                } else {
                    text = d?.lyricCue ?? ""
                }
                songs[songs.count - 1].sections.append((m.displayName, text, d?.note ?? ""))
            }
        }

        // Embed as JSON
        let songsJson = "[" + songs.map { song in
            let secs = "[" + song.sections.map { sec in
                "{\"sec\":\"\(j(sec.sec))\",\"text\":\"\(j(sec.text))\",\"note\":\"\(j(sec.note))\"}"
            }.joined(separator: ",") + "]"
            return "{\"song\":\"\(j(song.name))\",\"sections\":\(secs)}"
        }.joined(separator: ",") + "]"

        let exportBtns = buildSongExportButtons(songs: songs.map { ($0.name, $0.sections.map { $0.sec }) })

        return """
        <!DOCTYPE html>
        <html lang="ko">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Indicator 가사 편집</title>
        <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        :root { --accent: #007aff; --bg: #f2f2f7; --card: #fff; --border: #d1d1d6; --text: #1d1d1f; --sub: #6e6e73; }
        body { font-family: -apple-system, sans-serif; background: var(--bg); height: 100vh; display: flex; flex-direction: column; overflow: hidden; }
        #hdr { display: flex; align-items: center; gap: 12px; padding: 12px 20px; background: var(--card); border-bottom: 1px solid var(--border); flex-shrink: 0; }
        #hdr h1 { font-size: 17px; font-weight: 700; flex: 1; }
        #save-msg { font-size: 13px; color: #34c759; font-weight: 600; opacity: 0; transition: opacity .3s; }
        .btn { padding: 7px 18px; background: var(--accent); color: #fff; border: none; border-radius: 8px; font-size: 14px; font-weight: 600; cursor: pointer; text-decoration: none; display: inline-block; }
        .btn:active { opacity: .8; }
        .btn-sec { background: #5856d6; }
        #layout { display: flex; flex: 1; overflow: hidden; }
        #sidebar { width: 220px; flex-shrink: 0; overflow-y: auto; background: var(--card); border-right: 1px solid var(--border); padding: 8px 0; }
        .song-hd { padding: 10px 14px 3px; font-size: 11px; font-weight: 700; color: var(--sub); letter-spacing: .5px; text-transform: uppercase; }
        .sec-row { padding: 7px 14px 7px 22px; font-size: 14px; color: var(--text); cursor: pointer; border-left: 3px solid transparent; }
        .sec-row:hover { background: #f0f0f5; }
        .sec-row.active { background: #e5eeff; color: var(--accent); border-left-color: var(--accent); font-weight: 600; }
        .sec-row.dirty::after { content: "●"; font-size: 8px; color: var(--accent); margin-left: 5px; vertical-align: middle; }
        #main { flex: 1; overflow-y: auto; display: flex; flex-direction: column; }
        #empty { flex: 1; display: flex; align-items: center; justify-content: center; color: var(--sub); font-size: 15px; }
        #panel { display: none; padding: 24px; flex-direction: column; gap: 18px; }
        #panel.show { display: flex; }
        #panel-title { font-size: 22px; font-weight: 700; }
        .lbl { font-size: 11px; font-weight: 700; color: var(--sub); letter-spacing: .5px; text-transform: uppercase; margin-bottom: 6px; }
        #ta { width: 100%; min-height: 160px; border: 1.5px solid var(--border); border-radius: 10px; padding: 12px 14px; font-size: 17px; line-height: 1.8; font-family: -apple-system, sans-serif; outline: none; resize: vertical; }
        #ta:focus { border-color: var(--accent); }
        .hint { font-size: 12px; color: var(--sub); margin-top: 5px; }
        #preview { background: #1c1c1e; border-radius: 10px; padding: 16px 18px; min-height: 56px; }
        .pv-line { display: flex; flex-wrap: wrap; align-items: flex-end; min-height: 44px; }
        .cc { display: inline-flex; flex-direction: column; align-items: center; }
        .ca { font-size: 13px; color: #5DCAA5; font-weight: 700; min-height: 16px; line-height: 1; white-space: nowrap; padding: 0 2px; }
        .ct { font-size: 22px; color: #e8e8ed; line-height: 1.3; }
        #ni { width: 100%; border: 1.5px solid var(--border); border-radius: 10px; padding: 10px 14px; font-size: 15px; font-family: -apple-system, sans-serif; outline: none; }
        #ni:focus { border-color: var(--accent); }
        #export-box { border-top: 1px solid var(--border); padding: 20px 24px; flex-shrink: 0; }
        #export-box h2 { font-size: 11px; font-weight: 700; color: var(--sub); margin-bottom: 10px; text-transform: uppercase; letter-spacing: .5px; }
        .btn-row { display: flex; gap: 8px; flex-wrap: wrap; }
        </style>
        </head>
        <body>
        <div id="hdr">
          <h1>가사 편집</h1>
          <span id="save-msg"></span>
          <button class="btn" onclick="saveAll()">저장</button>
        </div>
        <div id="layout">
          <div id="sidebar"></div>
          <div id="main">
            <div id="empty">← 섹션을 선택하세요</div>
            <div id="panel">
              <div id="panel-title"></div>
              <div>
                <div class="lbl">가사 (코드 포함)</div>
                <textarea id="ta" placeholder="[G]찬양해 [D]찬양해&#10;[Em]온 맘 다해 [C]주를"></textarea>
                <div class="hint">[코드명]글자 형식으로 코드를 삽입하세요. Enter = 줄바꿈.</div>
              </div>
              <div>
                <div class="lbl">미리보기</div>
                <div id="preview"><span style="color:#555;font-size:13px">가사를 입력하면 여기에 표시됩니다</span></div>
              </div>
              <div>
                <div class="lbl">연주 노트</div>
                <input id="ni" type="text" placeholder="예: 키 G, 템포 72">
              </div>
            </div>
            <div id="export-box">
              <h2>내보내기</h2>
              <div class="btn-row">
                <a href="/export/setlist" class="btn btn-sec" style="text-decoration:none">이번 세트리스트</a>
                \(exportBtns)
              </div>
            </div>
          </div>
        </div>
        <script>
        const DATA = \(songsJson);
        let curSong = null, curSec = null;
        const dirty = {};

        function renderSidebar() {
          const sb = document.getElementById('sidebar');
          sb.innerHTML = '';
          for (const song of DATA) {
            const hd = document.createElement('div');
            hd.className = 'song-hd';
            hd.textContent = song.song;
            sb.appendChild(hd);
            for (const sec of song.sections) {
              const key = song.song + '|||' + sec.sec;
              const row = document.createElement('div');
              row.className = 'sec-row' + (curSong === song.song && curSec === sec.sec ? ' active' : '') + (dirty[key] ? ' dirty' : '');
              row.textContent = sec.sec;
              row.addEventListener('click', () => selectSec(song.song, sec.sec));
              sb.appendChild(row);
            }
          }
        }

        function selectSec(song, sec) {
          flushCurrent();
          curSong = song; curSec = sec;
          const key = song + '|||' + sec;
          const sd = DATA.find(s => s.song === song)?.sections.find(s => s.sec === sec) || {};
          const state = dirty[key] || { text: sd.text || '', note: sd.note || '' };
          document.getElementById('panel-title').textContent = sec;
          document.getElementById('ta').value = state.text;
          document.getElementById('ni').value = state.note;
          document.getElementById('empty').style.display = 'none';
          document.getElementById('panel').classList.add('show');
          updatePreview();
          renderSidebar();
          document.getElementById('ta').focus();
        }

        function flushCurrent() {
          if (!curSong || !curSec) return;
          const key = curSong + '|||' + curSec;
          const text = document.getElementById('ta').value;
          const note = document.getElementById('ni').value;
          const sd = DATA.find(s => s.song === curSong)?.sections.find(s => s.sec === curSec) || {};
          if (text !== (sd.text || '') || note !== (sd.note || '')) {
            dirty[key] = { text, note };
          } else {
            delete dirty[key];
          }
        }

        function markDirty() {
          if (!curSong || !curSec) return;
          dirty[curSong + '|||' + curSec] = { text: document.getElementById('ta').value, note: document.getElementById('ni').value };
          document.querySelectorAll('.sec-row.active').forEach(r => r.classList.add('dirty'));
        }

        document.getElementById('ta').addEventListener('input', () => { markDirty(); updatePreview(); });
        document.getElementById('ni').addEventListener('input', markDirty);

        function parseLyric(text) {
          const tokens = [];
          const chars = [...text];
          let i = 0;
          while (i < chars.length) {
            const c = chars[i];
            if (c === '\\n') {
              tokens.push({ type: 'br' });
              i++;
            } else if (c === '[') {
              i++;
              let chord = '';
              while (i < chars.length && chars[i] !== ']' && chars[i] !== '\\n') chord += chars[i++];
              if (chars[i] === ']') i++;
              if (i < chars.length && chars[i] !== '[' && chars[i] !== '\\n') {
                const tok = { type: 'char', char: chars[i] };
                if (chord) tok.chord = chord;
                tokens.push(tok); i++;
              } else {
                const tok = { type: 'ghost' };
                if (chord) tok.chord = chord;
                tokens.push(tok);
              }
            } else {
              tokens.push({ type: 'char', char: c });
              i++;
            }
          }
          return tokens;
        }

        function updatePreview() {
          const tokens = parseLyric(document.getElementById('ta').value);
          const pv = document.getElementById('preview');
          if (!tokens.length) {
            pv.innerHTML = '<span style="color:#555;font-size:13px">가사를 입력하면 여기에 표시됩니다</span>';
            return;
          }
          const lines = [[]];
          for (const t of tokens) {
            if (t.type === 'br') lines.push([]);
            else lines[lines.length - 1].push(t);
          }
          pv.innerHTML = lines.map(line => {
            if (!line.length) return '<div class="pv-line" style="height:10px"></div>';
            return '<div class="pv-line">' + line.map(t => {
              const ca = '<span class="ca">' + (t.chord ? esc(t.chord) : '') + '</span>';
              const ch = t.char === ' ' ? '&ensp;' : esc(t.char || '');
              return '<span class="cc">' + ca + '<span class="ct">' + ch + '</span></span>';
            }).join('') + '</div>';
          }).join('');
        }

        function esc(s) { return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }

        function saveAll() {
          flushCurrent();
          if (!Object.keys(dirty).length) { showMsg('변경사항 없음'); return; }
          const payload = {};
          for (const [key, state] of Object.entries(dirty)) {
            const sep = key.indexOf('|||');
            const song = key.slice(0, sep), sec = key.slice(sep + 3);
            if (!payload[song]) payload[song] = {};
            const tokens = parseLyric(state.text);
            const plain = tokens.map(t => t.type === 'br' ? '\\n' : (t.type === 'char' ? (t.char || '') : '')).join('');
            payload[song][sec] = {
              lyricCue: plain.split('\\n')[0] || '',
              note: state.note,
              slides: [{ startBar: 0, barCount: 0, isInstrumental: false, tokens: tokens, instChords: [], singerNote: '' }]
            };
          }
          fetch('/save', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) })
            .then(r => r.json())
            .then(() => {
              for (const [key, state] of Object.entries(dirty)) {
                const sep = key.indexOf('|||'), song = key.slice(0, sep), sec = key.slice(sep + 3);
                const s = DATA.find(s => s.song === song)?.sections.find(s => s.sec === sec);
                if (s) { s.text = state.text; s.note = state.note; }
              }
              for (const k in dirty) delete dirty[k];
              renderSidebar();
              showMsg('저장됐어요!');
            }).catch(() => showMsg('저장 실패'));
        }

        function showMsg(m) {
          const el = document.getElementById('save-msg');
          el.textContent = m;
          el.style.opacity = '1';
          setTimeout(() => el.style.opacity = '0', 2200);
        }

        renderSidebar();
        </script>
        </body>
        </html>
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
