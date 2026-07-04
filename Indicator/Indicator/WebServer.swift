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
    // occurrence 기반 조회: (song, section, occIdx) -> (resolved data, linked 여부)
    var getLyricOcc: ((_ song: String, _ section: String, _ occIdx: Int) -> (SectionData, Bool))? = nil
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

        // 간주 슬라이드의 instChords를 targetTotalBars에 맞춰 앞마디부터 채우고 남으면 버림/모자라면 빈 마디로 패딩
        func adaptSlides(_ slides: [LyricSlide], targetTotalBars: Int) -> [LyricSlide] {
            slides.map { slide in
                guard slide.isInstrumental else { return slide }
                var s = slide
                let n = s.instChords.count
                if targetTotalBars <= n {
                    s.instChords = Array(s.instChords.prefix(targetTotalBars))
                } else {
                    s.instChords += Array(repeating: [], count: targetTotalBars - n)
                }
                s.barCount = targetTotalBars
                return s
            }
        }

        // Build songs data (with slides + totalBars)
        struct SecInfo {
            var sec: String; var occIdx: Int; var totalBars: Int
            var slidesJson: String; var sessionNote: String; var singerNote: String; var linked: Bool
        }
        var songs: [(name: String, sections: [SecInfo])] = []
        var curSong = ""
        var occCount: [String: Int] = [:]  // "song|||sec" -> 다음 occurrence 인덱스
        for (i, m) in markers.enumerated() {
            if m.isSong {
                curSong = m.displayName
                songs.append((name: curSong, sections: []))
                occCount = [:]
            } else if !curSong.isEmpty {
                let occKey = "\(curSong)|||\(m.displayName)"
                let occIdx = occCount[occKey] ?? 0
                occCount[occKey] = occIdx + 1
                let nextMTC = (i + 1 < markers.count) ? markers[i + 1].mtcSeconds : m.mtcSeconds
                let totalBars = max(0, Int((nextMTC - m.mtcSeconds) / (60.0 / max(1, 120.0)) / 4))
                let (d, linked) = getLyricOcc?(curSong, m.displayName, occIdx) ?? (SectionData(), false)
                let adapted = adaptSlides(d.slides, targetTotalBars: totalBars)
                let slidesJson = encodeJSON(adapted)
                songs[songs.count - 1].sections.append(
                    SecInfo(sec: m.displayName, occIdx: occIdx, totalBars: totalBars,
                            slidesJson: slidesJson, sessionNote: d.sessionNote, singerNote: d.singerNote, linked: linked)
                )
            }
        }

        // Embed as JSON
        let songsJson = "[" + songs.map { song in
            let secs = "[" + song.sections.map { sec in
                "{\"sec\":\"\(j(sec.sec))\",\"occIdx\":\(sec.occIdx),\"totalBars\":\(sec.totalBars),\"slides\":\(sec.slidesJson),\"sessionNote\":\"\(j(sec.sessionNote))\",\"singerNote\":\"\(j(sec.singerNote))\",\"linked\":\(sec.linked)}"
            }.joined(separator: ",") + "]"
            return "{\"song\":\"\(j(song.name))\",\"sections\":\(secs)}"
        }.joined(separator: ",") + "]"

        let exportBtns = buildSongExportButtons(songs: songs.map { ($0.name, $0.sections.map { $0.sec }) })

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
        #song-title{font-size:22px;font-weight:700;color:var(--text)}
        #export-box{border-top:1px solid var(--border);padding:16px 24px;flex-shrink:0;background:var(--card)}
        #export-box h2{font-size:11px;font-weight:700;color:var(--sub);margin-bottom:8px;text-transform:uppercase;letter-spacing:.5px}
        .btn-row{display:flex;gap:8px;flex-wrap:wrap}
        .btn-sec{background:var(--purple)}
        .sec-block{background:var(--card);border-radius:14px;overflow:hidden;border:1px solid var(--border)}
        .sec-hdr{display:flex;align-items:center;gap:8px;padding:12px 18px;flex-wrap:wrap}
        .sec-arrow{font-size:11px;color:var(--sub);flex-shrink:0;width:14px}
        .sec-name{font-size:16px;font-weight:700;color:var(--text)}
        .sec-bars-info{font-size:12px;color:var(--sub)}
        .capo-wrap{display:flex;align-items:center;gap:4px;font-size:12px;color:var(--sub);margin-left:auto}
        .capo-inp{width:36px;border:1px solid var(--border);border-radius:5px;padding:3px 4px;font-size:12px;text-align:center;outline:none}
        .capo-inp:focus{border-color:var(--accent)}
        .note-pair{display:flex;gap:6px}
        .note-inp-sm{border:1px solid var(--border);border-radius:7px;padding:5px 9px;font-size:12px;outline:none;width:130px}
        .note-inp-sm:focus{border-color:var(--accent)}
        .bar-tl-area{padding:10px 18px 8px;background:#f8f8fc;border-bottom:1px solid var(--border)}
        .bar-tl{display:flex;align-items:center;overflow-x:auto;padding-bottom:4px;user-select:none}
        .bar-box{width:34px;height:42px;border-radius:6px;display:flex;flex-direction:column;align-items:center;justify-content:center;font-size:11px;font-weight:700;flex-shrink:0;position:relative}
        .bar-box .bn{font-size:9px;color:rgba(0,0,0,.3);position:absolute;bottom:2px}
        .bar-box.free{background:#e4e4ee;color:#aaa}
        .bar-box.seg-owned{color:#fff}
        .div-gap{width:10px;height:42px;display:flex;align-items:center;justify-content:center;cursor:col-resize;flex-shrink:0;position:relative}
        .div-gap::after{content:'';width:2px;height:65%;background:transparent;border-radius:1px;transition:background .1s}
        .div-gap:hover::after{background:rgba(0,122,255,.5)}
        .div-gap.active::after{background:var(--orange);width:3px;height:85%}
        .segs-area{padding:10px 18px 14px;display:flex;flex-direction:column;gap:10px}
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
        </style>
        </head>
        <body>
        <div id="hdr">
          <h1>가사 편집</h1>
          <span id="save-msg"></span>
          <button class="btn" onclick="saveAll()">저장</button>
        </div>
        <div id="layout">
          <div id="sidebar"><div class="sb-hd">곡 목록</div></div>
          <div id="main">
            <div id="empty">← 곡을 선택하세요</div>
            <div id="song-view">
              <div id="song-title"></div>
              <div id="sections-list"></div>
            </div>
          </div>
        </div>
        <div id="export-box">
          <h2>내보내기</h2>
          <div class="btn-row">
            <a href="/export/setlist" class="btn btn-sm btn-sec" style="text-decoration:none">이번 세트리스트</a>
            \(exportBtns)
          </div>
          <h2 style="margin-top:12px">가져오기</h2>
          <div class="btn-row" style="align-items:center;gap:8px">
            <label class="btn btn-sm btn-sec" style="cursor:pointer">
              파일 선택
              <input type="file" accept=".json,.csv" style="display:none" onchange="handleImportFile(this)">
            </label>
            <span id="import-status" style="font-size:11px;color:var(--sub)"></span>
          </div>
        </div>
        <script>
        const DATA=\(songsJson);
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

        // occurrence(occIdx) 기반 키 — 같은 이름 섹션이 여러 번 등장해도 독립적으로 식별됨
        function dkOf(song,sec,occIdx){return song+'|||'+sec+'@@'+occIdx;}
        function ukOf(song,sec,idx){return song+'|||'+sec+'|||'+idx;}
        function origSecOf(song,sec,occIdx){
          const secs=DATA.find(s=>s.song===song)?.sections||[];
          if(occIdx!==undefined){const exact=secs.find(s=>s.sec===sec&&s.occIdx===occIdx);if(exact)return exact;}
          return secs.find(s=>s.sec===sec)||{};
        }

        function getSegs(st,total){
          const sp=[...st.splits].sort((a,b)=>a-b);
          const starts=[0,...sp.map(p=>p+1)];
          const ends=[...sp,total-1];
          return starts.map((start,i)=>({barStart:start,barEnd:ends[i],barCount:ends[i]-start+1,segData:st.segData[i]||{isInstrumental:false,tokens:[],instChords:[]}}));
        }

        // 간주 슬라이드를 targetTotal 마디에 맞춰 앞마디부터 채우고 남으면 버림/모자라면 빈 마디로 패딩 (서버 adaptSlides와 동일 규칙)
        function adaptRawSlides(rawSlides,targetTotal){
          return(rawSlides||[]).map(sl=>{
            if(!sl.isInstrumental)return sl;
            const n=(sl.instChords||[]).length;
            const ic=targetTotal<=n?sl.instChords.slice(0,targetTotal):[...sl.instChords,...Array(targetTotal-n).fill([])];
            return{...sl,instChords:ic,barCount:targetTotal};
          });
        }
        // raw slides 배열 -> {splits,segData} (loadState와 동일 변환 로직)
        function slidesFromRaw(rawSlides,secStart){
          const slides=(rawSlides||[]).filter(sl=>(sl.tokens&&sl.tokens.length>0)||sl.isInstrumental);
          if(slides.length===0)return{splits:[],segData:[{isInstrumental:false,tokens:[],instChords:[]}]};
          const sorted=[...slides].sort((a,b)=>a.startBar-b.startBar);
          const splits=sorted.slice(0,-1).map(sl=>{const r=sl.startBar>=secStart&&secStart>0?sl.startBar-secStart:sl.startBar;return r+sl.barCount-1;});
          const segData=sorted.map(sl=>({isInstrumental:sl.isInstrumental||false,tokens:sl.tokens||[],instChords:sl.instChords||[]}));
          return{splits,segData};
        }
        // {splits,segData} 상태 -> raw slide 배열 (저장/캐노니컬 전파용, saveAll과 동일 변환)
        function rawSlidesFromState(st,total){
          return getSegs(st,total).map(sg=>({
            startBar:sg.barStart,barCount:sg.barCount,isInstrumental:!!sg.segData.isInstrumental,
            tokens:sg.segData.isInstrumental?[]:(sg.segData.tokens||[]),
            instChords:sg.segData.isInstrumental?(sg.segData.instChords||[]):[]
          }));
        }

        // 캐노니컬(같은 이름 가장 이른 occurrence)의 최신 데이터를 내 마디 수에 맞춰 즉시 계산 (세션 중 캐노니컬 수정도 반영)
        // 노트는 연결 여부와 무관하게 항상 자기 occurrence 것을 쓴다 (가사/코드만 캐노니컬을 따라감)
        function buildLinkedPreview(song,sec,occIdx){
          const canon=origSecOf(song,sec); // occIdx 생략 -> 이름으로 첫 occurrence(캐노니컬) 탐색
          const canonDirty=dirty[dkOf(song,sec,0)];
          let rawSlides;
          if(canonDirty&&!canonDirty.linked){
            rawSlides=rawSlidesFromState(canonDirty,canon.totalBars||0);
          } else {
            rawSlides=canon.slides;
          }
          const target=origSecOf(song,sec,occIdx).totalBars||0;
          const adapted=adaptRawSlides(rawSlides,target);
          const{splits,segData}=slidesFromRaw(adapted,0);
          const own=origSecOf(song,sec,occIdx);
          return{splits,segData,sessionNote:own.sessionNote||'',singerNote:own.singerNote||'',capo:0,linked:true};
        }

        function loadState(song,sec,occIdx){
          const k=dkOf(song,sec,occIdx);
          if(dirty[k])return dirty[k];
          const o=origSecOf(song,sec,occIdx);
          if(!!o.linked)return buildLinkedPreview(song,sec,occIdx);
          const slides=(o.slides||[]).filter(sl=>(sl.tokens&&sl.tokens.length>0)||sl.isInstrumental);
          if(slides.length===0){
            return{splits:[],segData:[{isInstrumental:false,tokens:[],instChords:[]}],sessionNote:o.sessionNote||'',singerNote:o.singerNote||'',capo:0,linked:false};
          }
          const sorted=[...slides].sort((a,b)=>a.startBar-b.startBar);
          const splits=sorted.slice(0,-1).map(sl=>sl.startBar+sl.barCount-1);
          const segData=sorted.map(sl=>({isInstrumental:sl.isInstrumental||false,tokens:sl.tokens||[],instChords:sl.instChords||[]}));
          return{splits,segData,sessionNote:o.sessionNote||'',singerNote:o.singerNote||'',capo:0,linked:false};
        }

        function setState(song,sec,occIdx,st){
          dirty[dkOf(song,sec,occIdx)]={...st,linked:false};
          document.querySelectorAll('.sb-song').forEach(el=>{if(el.dataset.song===song)el.classList.add('dirty');});
          updateLinkUI(song,sec,occIdx,false);
        }

        function setNote(song,sec,occIdx,field,value){
          const cur=loadState(song,sec,occIdx);
          dirty[dkOf(song,sec,occIdx)]={...cur,[field]:value};
          document.querySelectorAll('.sb-song').forEach(el=>{if(el.dataset.song===song)el.classList.add('dirty');});
        }

        function setLinked(song,sec,occIdx,linked){
          if(linked){
            dirty[dkOf(song,sec,occIdx)]={...buildLinkedPreview(song,sec,occIdx)};
          } else {
            const cur=loadState(song,sec,occIdx);
            dirty[dkOf(song,sec,occIdx)]={...cur,linked:false};
          }
          document.querySelectorAll('.sb-song').forEach(el=>{if(el.dataset.song===song)el.classList.add('dirty');});
        }

        function updateLinkUI(song,sec,occIdx,linked){
          const sel=document.querySelector('select.link-select[data-song="'+song+'"][data-sec="'+sec+'"][data-sb="'+occIdx+'"]');
          if(sel)sel.value=linked?'linked':'independent';
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
          $('song-title').textContent=song;
          renderSections(song);
        }

        function renderSections(song){
          const list=$('sections-list');list.innerHTML='';
          const songData=DATA.find(s=>s.song===song);
          if(!songData)return;
          songData.sections.forEach((sec,secIdx)=>{
            const ukey=ukOf(song,sec.sec,secIdx);
            if(!secUI[ukey])secUI[ukey]={open:false};
            list.appendChild(createSecBlock(song,sec,secIdx));
          });
        }

        function createSecBlock(song,sec,gidx){
          const ukey=ukOf(song,sec.sec,gidx);
          const ui=secUI[ukey];
          const st=loadState(song,sec.sec,sec.occIdx);
          const total=sec.totalBars||0;
          const block=document.createElement('div');
          block.className='sec-block';block.dataset.ukey=ukey;

          const hdr=document.createElement('div');hdr.className='sec-hdr';hdr.style.cursor='pointer';
          hdr.addEventListener('click',()=>{ui.open=!ui.open;refreshBlock(block,song,sec,gidx);});

          const arrow=document.createElement('span');arrow.className='sec-arrow';arrow.textContent=ui.open?'▾':'▸';
          const nameEl=document.createElement('span');nameEl.className='sec-name';nameEl.textContent=sec.sec;
          const barsEl=document.createElement('span');barsEl.className='sec-bars-info';barsEl.textContent=total+'마디';

          const linkSel=document.createElement('select');
          linkSel.className='link-select';
          linkSel.dataset.song=song;linkSel.dataset.sec=sec.sec;linkSel.dataset.sb=sec.occIdx;
          const isCanonical=(sec.occIdx===0);
          linkSel.innerHTML='<option value="independent">독립적으로 편집</option>'+(isCanonical?'':'<option value="linked">'+sec.sec+' 자동 연결</option>');
          linkSel.value=st.linked?'linked':'independent';
          if(isCanonical)linkSel.disabled=true;
          linkSel.addEventListener('click',e=>e.stopPropagation());
          linkSel.addEventListener('change',()=>{
            setLinked(song,sec.sec,sec.occIdx,linkSel.value==='linked');
            refreshBlock(block,song,sec,gidx);
          });

          const capoW=document.createElement('div');capoW.className='capo-wrap';
          capoW.innerHTML='카포 <input class="capo-inp" type="number" min="0" max="11" value="'+(st.capo||0)+'">';
          const capoInp=capoW.querySelector('.capo-inp');
          capoInp.addEventListener('click',e=>e.stopPropagation());
          capoInp.addEventListener('change',e=>{e.stopPropagation();setState(song,sec.sec,sec.occIdx,{...loadState(song,sec.sec,sec.occIdx),capo:parseInt(capoInp.value)||0});});

          if(secUI[ukey].sessionNote===undefined)secUI[ukey].sessionNote=st.sessionNote||'';
          if(secUI[ukey].singerNote===undefined)secUI[ukey].singerNote=st.singerNote||'';
          const noteP=document.createElement('div');noteP.className='note-pair';
          const snInp=Object.assign(document.createElement('input'),{className:'note-inp-sm',type:'text',placeholder:'세션 노트',value:secUI[ukey].sessionNote});
          const gnInp=Object.assign(document.createElement('input'),{className:'note-inp-sm',type:'text',placeholder:'싱어 노트',value:secUI[ukey].singerNote});
          [snInp,gnInp].forEach(inp=>inp.addEventListener('click',e=>e.stopPropagation()));
          snInp.addEventListener('input',()=>{secUI[ukey].sessionNote=snInp.value;setNote(song,sec.sec,sec.occIdx,'sessionNote',snInp.value);});
          gnInp.addEventListener('input',()=>{secUI[ukey].singerNote=gnInp.value;setNote(song,sec.sec,sec.occIdx,'singerNote',gnInp.value);});
          noteP.appendChild(snInp);noteP.appendChild(gnInp);

          hdr.appendChild(arrow);hdr.appendChild(nameEl);hdr.appendChild(barsEl);hdr.appendChild(linkSel);hdr.appendChild(capoW);hdr.appendChild(noteP);
          block.appendChild(hdr);

          if(ui.open){
            const tlArea=document.createElement('div');tlArea.className='bar-tl-area';
            renderBarTl(tlArea,song,sec,gidx);block.appendChild(tlArea);
            const sa=document.createElement('div');sa.className='segs-area';
            renderSegsArea(sa,song,sec,gidx);block.appendChild(sa);
          }
          return block;
        }

        function refreshBlock(block,song,sec,gidx){block.replaceWith(createSecBlock(song,sec,gidx));}
        function getBlock(ukey){return document.querySelector('.sec-block[data-ukey="'+ukey+'"]');}

        function renderBarTl(container,song,sec,gidx){
          container.innerHTML='';
          const ukey=ukOf(song,sec.sec,gidx);
          const st=loadState(song,sec.sec,sec.occIdx);
          const total=sec.totalBars||0;
          const segs=getSegs(st,total);
          const tl=document.createElement('div');tl.className='bar-tl';
          for(let i=0;i<total;i++){
            const segIdx=segs.findIndex(sg=>i>=sg.barStart&&i<=sg.barEnd);
            const box=document.createElement('div');box.className='bar-box';
            if(segIdx>=0){box.classList.add('seg-owned');box.style.background=COLORS[segIdx%COLORS.length];}
            else box.classList.add('free');
            const bn=document.createElement('span');bn.className='bn';bn.textContent=String(i+1);box.appendChild(bn);
            tl.appendChild(box);
            if(i<total-1){
              const gap=document.createElement('div');
              const isActive=st.splits.includes(i);
              gap.className='div-gap'+(isActive?' active':'');
              gap.title=isActive?'구분 제거':'여기서 나누기';
              gap.addEventListener('click',()=>{
                const cur=loadState(song,sec.sec,sec.occIdx);
                let splits=[...cur.splits];let segData=[...cur.segData];
                const segs2=getSegs(cur,total);
                if(splits.includes(i)){
                  const idx=splits.indexOf(i);splits.splice(idx,1);
                  const merged={isInstrumental:segData[idx].isInstrumental,tokens:[...(segData[idx].tokens||[]),...(segData[idx+1]?.tokens||[])]};
                  segData.splice(idx,2,merged);
                }else{
                  const idx=segs2.findIndex(sg=>i>=sg.barStart&&i<=sg.barEnd);
                  splits.push(i);splits.sort((a,b)=>a-b);
                  const orig=segData[idx]||{isInstrumental:false,tokens:[]};
                  segData.splice(idx,1,{isInstrumental:orig.isInstrumental,tokens:orig.tokens},{isInstrumental:orig.isInstrumental,tokens:[]});
                }
                setState(song,sec.sec,sec.occIdx,{...cur,splits,segData});
                const bl=getBlock(ukey);if(bl)refreshBlock(bl,song,sec,gidx);
              });
              tl.appendChild(gap);
            }
          }
          container.appendChild(tl);
        }

        const chordEditState={};

        function renderSegsArea(container,song,sec,gidx){
          container.innerHTML='';
          const st=loadState(song,sec.sec,sec.occIdx);
          const total=sec.totalBars||0;
          const segs=getSegs(st,total);
          const secStart=0;
          segs.forEach((sg,i)=>container.appendChild(createSegCard(song,sec,gidx,i,sg,segs.length,secStart,total)));
        }

        function createSegCard(song,sec,gidx,segIdx,sg,totalSegs,secStart,total){
          const ukey=ukOf(song,sec.sec,gidx);
          const ceKey=ukey+'|||'+segIdx;
          if(!chordEditState[ceKey])chordEditState[ceKey]={chordMode:false,editIdx:null};
          const ces=chordEditState[ceKey];
          const card=document.createElement('div');card.className='seg-card';card.dataset.si=String(segIdx);

          const hd=document.createElement('div');hd.className='seg-hdr';
          const dot=document.createElement('div');dot.className='seg-dot';dot.style.background=COLORS[segIdx%COLORS.length];
          const info=document.createElement('div');info.className='seg-info';
          info.textContent='마디 '+(sg.barStart+1)+(sg.barCount>1?'~'+(sg.barEnd+1):'');
          const typeBtn=document.createElement('button');typeBtn.className='btn btn-sm btn-ghost';
          typeBtn.textContent=sg.segData.isInstrumental?'🎵 간주':'🎤 가사';
          typeBtn.addEventListener('click',()=>{
            const st=loadState(song,sec.sec,sec.occIdx);const segData=[...st.segData];
            segData[segIdx]={...segData[segIdx],isInstrumental:!segData[segIdx].isInstrumental};
            setState(song,sec.sec,sec.occIdx,{...st,segData});
            const bl=getBlock(ukey);if(bl)refreshBlock(bl,song,sec,gidx);
          });
          if(totalSegs>1){
            const delBtn=document.createElement('button');delBtn.className='btn btn-sm btn-red';delBtn.textContent='삭제';
            delBtn.addEventListener('click',()=>{
              const cur=loadState(song,sec.sec,sec.occIdx);let splits=[...cur.splits];let segData=[...cur.segData];
              const splitIdx=segIdx>0?segIdx-1:0;
              splits.splice(splitIdx,1);
              if(segIdx>0){
                const merged={isInstrumental:segData[segIdx-1].isInstrumental,tokens:[...(segData[segIdx-1].tokens||[]),...(segData[segIdx].tokens||[])]};
                segData.splice(segIdx-1,2,merged);
              }else{
                const merged={isInstrumental:segData[1].isInstrumental,tokens:[...(segData[0].tokens||[]),...(segData[1].tokens||[])]};
                segData.splice(0,2,merged);
              }
              setState(song,sec.sec,sec.occIdx,{...cur,splits,segData});
              const bl=getBlock(ukey);if(bl)refreshBlock(bl,song,sec,gidx);
            });
            hd.appendChild(dot);hd.appendChild(info);hd.appendChild(typeBtn);hd.appendChild(delBtn);
          }else{
            hd.appendChild(dot);hd.appendChild(info);hd.appendChild(typeBtn);
          }
          card.appendChild(hd);

          const edArea=document.createElement('div');edArea.className='seg-ed';
          if(sg.segData.isInstrumental){
            renderInstEditor(edArea,song,sec,gidx,segIdx,sg,secStart,total);
          }else{
            const modeRow=document.createElement('div');modeRow.className='mode-row';
            const lyricBtn=document.createElement('button');lyricBtn.className='btn btn-sm'+(ces.chordMode?' btn-ghost':'');lyricBtn.textContent='가사';
            lyricBtn.addEventListener('click',()=>{if(ces.chordMode){ces.chordMode=false;ces.editIdx=null;refreshSegCard(card,song,sec,gidx,segIdx,total);}});
            const chordBtn=document.createElement('button');chordBtn.className='btn btn-sm'+(ces.chordMode?'':' btn-ghost');chordBtn.textContent='코드 편집';
            chordBtn.addEventListener('click',()=>{
              if(!ces.chordMode){
                const ta=card.querySelector('.lyric-ta');
                if(ta){const st=loadState(song,sec.sec,sec.occIdx);const segData=[...st.segData];
                  if(tokensToPlain(segData[segIdx].tokens||[])!==ta.value){segData[segIdx]={...segData[segIdx],tokens:textToTokens(ta.value)};setState(song,sec.sec,sec.occIdx,{...st,segData});}
                }
                ces.chordMode=true;ces.editIdx=null;refreshSegCard(card,song,sec,gidx,segIdx,total);
              }
            });
            modeRow.appendChild(lyricBtn);modeRow.appendChild(chordBtn);edArea.appendChild(modeRow);
            if(!ces.chordMode){
              const ta=document.createElement('textarea');ta.className='lyric-ta';
              ta.placeholder='가사를 입력하세요\\nEnter = 줄바꿈';
              ta.value=tokensToPlain(sg.segData.tokens||[]);
              ta.addEventListener('input',()=>{
                const st=loadState(song,sec.sec,sec.occIdx);const segData=[...st.segData];
                segData[segIdx]={...segData[segIdx],tokens:textToTokens(ta.value)};
                setState(song,sec.sec,sec.occIdx,{...st,segData});
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

        function refreshSegCard(card,song,sec,gidx,segIdx,total){
          const st=loadState(song,sec.sec,sec.occIdx);const segs=getSegs(st,total);
          const secStart=0;
          card.replaceWith(createSegCard(song,sec,gidx,segIdx,segs[segIdx],segs.length,secStart,total));
        }

        function renderChordGrid(grid,song,sec,gidx,segIdx,ceKey){
          const ces=chordEditState[ceKey];
          const st=loadState(song,sec.sec,sec.occIdx);
          const total=origSecOf(song,sec.sec,sec.occIdx).totalBars||0;
          const tokens=getSegs(st,total)[segIdx]?.segData.tokens||[];
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
            inp.addEventListener('input',()=>{
              inp.value=inp.value.replace(/[^A-Za-z0-9#♭/]/g,'');
              inp.value=inp.value.slice(0,1).toUpperCase()+inp.value.slice(1);
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
          el.addEventListener('click',()=>{if(ti!==ces.editIdx)openChordInput(song,sec,gidx,segIdx,ceKey,ti);});
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
            const st=loadState(song,sec.sec,sec.occIdx);const total=origSecOf(song,sec.sec,sec.occIdx).totalBars||0;
            const toks=getSegs(st,total)[segIdx]?.segData.tokens||[];
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

        function renderInstEditor(ed,song,sec,gidx,segIdx,sg,secStart,total){
          const st=loadState(song,sec.sec,sec.occIdx);const segs=getSegs(st,total);
          const existingIC=segs[segIdx]?.segData.instChords||[];
          const hint=document.createElement('div');hint.style.cssText='font-size:12px;color:var(--sub);margin-bottom:10px';
          hint.textContent='8비트 그리드 코드 입력 (s=♯, b=♭)';ed.appendChild(hint);
          const table=document.createElement('div');table.className='inst-table';
          const hdr=document.createElement('div');hdr.className='inst-row';
          const hl=document.createElement('div');hl.className='inst-bar-lbl';hdr.appendChild(hl);
          ['1','+','2','+','3','+','4','+'].forEach(lbl=>{const l=document.createElement('div');l.className='inst-beat-hdr';l.textContent=lbl;hdr.appendChild(l);});
          table.appendChild(hdr);
          for(let b=0;b<sg.barCount;b++){
            const barSlots=existingIC[b]||[];
            const row=document.createElement('div');row.className='inst-row';
            const lbl=document.createElement('div');lbl.className='inst-bar-lbl';lbl.textContent='마디 '+(sg.barStart+b+1);row.appendChild(lbl);
            for(let beat=0;beat<8;beat++){
              const slot=barSlots.find(s=>s.pos===beat);
              const cell=document.createElement('div');cell.className='inst-beat-'+(beat%2===0?'on':'off');
              const inp=document.createElement('input');inp.className='inst-beat-inp';inp.type='text';
              inp.value=slot?slot.name:'';inp.placeholder='';
              inp.addEventListener('focus',()=>inp.select());
              inp.addEventListener('input',()=>{inp.value=inp.value.replace(/[^A-Za-z0-9#♭/]/g,'');inp.value=normChord(inp.value);});
              inp.addEventListener('change',()=>{
                const cur=loadState(song,sec.sec,sec.occIdx);const segData=[...cur.segData];
                const curIC=getSegs(cur,total)[segIdx]?.segData.instChords||[];
                const newIC=Array(sg.barCount).fill(null).map((_,bi)=>{
                  const arr=[...(curIC[bi]||[])];
                  if(bi===b){const f=arr.filter(s=>s.pos!==beat);const v=normChord(inp.value);if(v)f.push({pos:beat,name:v});return f.sort((a,c)=>a.pos-c.pos);}
                  return arr;
                });
                segData[segIdx]={...segData[segIdx],instChords:newIC};setState(song,sec.sec,sec.occIdx,{...cur,segData});
              });
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

        function saveAll(){
          if(Object.keys(dirty).length===0){showMsg('변경사항 없음');return;}
          const payload={};
          for(const[k,st]of Object.entries(dirty)){
            const{song,sec,occIdx}=parseDk(k);
            if(!payload[song])payload[song]={};
            const occKey=sec+'@@'+occIdx;
            if(st.linked){
              payload[song][occKey]={lyricCue:'',sessionNote:st.sessionNote||'',singerNote:st.singerNote||'',slides:[],linked:true};
              continue;
            }
            const o=origSecOf(song,sec,occIdx);
            const total=o.totalBars||0;
            const segs=getSegs(st,total);
            const slides=segs.map(sg=>({startBar:sg.barStart,barCount:sg.barCount,isInstrumental:!!sg.segData.isInstrumental,tokens:sg.segData.isInstrumental?[]:(sg.segData.tokens||[]),instChords:sg.segData.isInstrumental?(sg.segData.instChords||[]):[],singerNote:''}));
            const plain=tokensToPlain(segs[0]?.segData.tokens||[]);
            payload[song][occKey]={lyricCue:plain.split('\\n')[0]||'',sessionNote:st.sessionNote||'',singerNote:st.singerNote||'',slides,linked:false};
          }
          fetch('/save',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)})
            .then(r=>r.json())
            .then(()=>{
              for(const[k,st]of Object.entries(dirty)){
                const{song,sec,occIdx}=parseDk(k);
                const sd=DATA.find(x=>x.song===song)?.sections.find(x=>x.sec===sec&&x.occIdx===occIdx);
                if(sd){
                  sd.linked=!!st.linked;
                  sd.sessionNote=st.sessionNote||'';sd.singerNote=st.singerNote||'';
                  if(!st.linked){
                    const segs=getSegs(st,sd.totalBars||0);
                    sd.slides=segs.map(sg=>({startBar:sg.barStart,barCount:sg.barCount,isInstrumental:!!sg.segData.isInstrumental,tokens:sg.segData.isInstrumental?[]:(sg.segData.tokens||[]),instChords:sg.segData.isInstrumental?(sg.segData.instChords||[]):[],singerNote:''}));
                  }
                }
              }
              for(const k in dirty)delete dirty[k];
              renderSidebar();showMsg('저장됐어요!');
            }).catch(()=>showMsg('저장 실패'));
        }

        function showMsg(m){const el=$('save-msg');el.textContent=m;el.style.opacity='1';setTimeout(()=>el.style.opacity='0',2200);}

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
            broadcaster.send("event: lyrics-updated\ndata: {}\n\n")
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
