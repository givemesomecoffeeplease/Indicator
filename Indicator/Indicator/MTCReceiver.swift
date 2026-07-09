import CoreMIDI
import Foundation

class MTCReceiver {

    var onTimeUpdate: ((TimeInterval) -> Void)?
    var onStop: (() -> Void)?
    var onBeat: (() -> Void)?   // MIDI Clock 24펄스마다 호출 (= 1박자)
    var onFPSChange: ((Double) -> Void)?   // 프로젝트 SMPTE 프레임레이트 변경 감지

    // rateCode 디코딩 → 공유 fps 갱신, 변경 시 콜백 (스캔 데이터와 불일치 경고용)
    private func updateFPS(_ newFPS: Double) {
        fps = newFPS
        if SMPTEConfig.fps != newFPS {
            SMPTEConfig.fps = newFPS
            DispatchQueue.main.async { self.onFPSChange?(newFPS) }
        }
    }

    private(set) var currentTime: TimeInterval = 0

    private var client = MIDIClientRef()
    private var port   = MIDIPortRef()

    // MTC
    private var qfBits: [UInt8] = Array(repeating: 0, count: 8)
    private var qfCount = 0
    private var synced  = false
    private var fps: Double = 25.0
    private var qfIndex = 0
    private var silenceTimer: DispatchWorkItem?

    // MIDI Clock
    private var clockPulses = 0   // 0..<24, 24펄스 = 1박자
    private(set) var iacConnected = false
    private(set) var clockReceived = false
    private(set) var mtcReceived = false
    private var mtcTimeoutTimer:   DispatchWorkItem?
    private var clockTimeoutTimer: DispatchWorkItem?

    func start() {
        MIDIClientCreate("IndicatorMTC" as CFString, nil, nil, &client)
        MIDIInputPortCreateWithBlock(client, "MTCIn" as CFString, &port) { [weak self] pktList, _ in
            self?.receive(pktList)
        }
        // IAC Driver 소스만 연결 (다른 앱이 MIDI Clock을 반사하면 2중 수신으로 오작동)
        var connectedAny = false
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            var name: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(src, kMIDIPropertyName, &name)
            let srcName = (name?.takeRetainedValue() as String?) ?? ""
            if srcName.lowercased().contains("iac") || srcName.contains("버스") {
                MIDIPortConnectSource(port, src, nil)
                connectedAny = true
                iacConnected = true
            }
        }
        // IAC 소스가 없으면 전체 연결 (fallback)
        if !connectedAny {
            for i in 0..<MIDIGetNumberOfSources() {
                MIDIPortConnectSource(port, MIDIGetSource(i), nil)
            }
        }
    }

    func stop() {
        silenceTimer?.cancel()
        MIDIPortDispose(port)
        MIDIClientDispose(client)
    }

    func receive(_ pktList: UnsafePointer<MIDIPacketList>) {
        var pkt = pktList.pointee.packet
        for _ in 0..<pktList.pointee.numPackets {
            process(pkt)
            pkt = MIDIPacketNext(&pkt).pointee
        }
    }

    private func resetMTCTimeout() {
        mtcTimeoutTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.mtcReceived = false }
        mtcTimeoutTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 60.0, execute: item)
    }

    private func resetClockTimeout() {
        clockTimeoutTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.clockReceived = false }
        clockTimeoutTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 60.0, execute: item)
    }

    private func resetSilenceTimer() {
        silenceTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.synced = false
            DispatchQueue.main.async { self?.onStop?() }
        }
        silenceTimer = item
        // 실제 정지는 0xFC(MIDI Stop)가 즉시 처리하므로 이 타이머는 0xFC 유실 시의
        // 비상 안전망일 뿐. 짧으면(0.15s) 시스템 부하로 MIDI가 잠깐 밀릴 때
        // 재생 중인데 정지로 오판 → 섹션/카운트 리셋 요동이 발생했음.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    private func process(_ pkt: MIDIPacket) {
        withUnsafeBytes(of: pkt.data) { raw in
            var idx = 0
            // pkt.length는 실제 메시지 길이지만 버퍼(raw)는 최대 256바이트
            // SysEx 등 긴 메시지가 오면 length > 256이 되어 크래시 → 버퍼 크기로 제한
            let count = min(Int(pkt.length), raw.count)
            while idx < count {
                let byte = raw[idx]

                switch byte {
                case 0xF8:
                    // MIDI Timing Clock — 24펄스/박자
                    clockReceived = true
                    resetClockTimeout()
                    clockPulses += 1
                    if clockPulses >= 24 {
                        clockPulses = 0
                        DispatchQueue.main.async { self.onBeat?() }
                    }
                    resetSilenceTimer()

                case 0xFA, 0xFB:
                    // MIDI Start / Continue — 펄스 카운터 리셋
                    clockPulses = 0

                case 0xFC:
                    // MIDI Stop
                    clockPulses = 0
                    synced = false
                    silenceTimer?.cancel()
                    DispatchQueue.main.async { self.onStop?() }

                case 0xF0:
                    // MTC Full Frame SysEx: F0 7F 7F 01 01 HH MM SS FF F7 (10 bytes)
                    // 점프(seek) 시 Logic이 전송 — 새 위치를 즉시 반영
                    if idx + 9 < count,
                       raw[idx+1] == 0x7F, raw[idx+2] == 0x7F,
                       raw[idx+3] == 0x01, raw[idx+4] == 0x01 {
                        let hh       = raw[idx+5]
                        let mm       = raw[idx+6]
                        let ss       = raw[idx+7]
                        let ff       = raw[idx+8]
                        let rateCode = Int((hh >> 5) & 0x03)
                        updateFPS([24.0, 25.0, 29.97, 30.0][rateCode])
                        let hours    = Int(hh & 0x1F)
                        let total    = Double(hours)*3600 + Double(mm)*60 + Double(ss) + Double(ff)/fps
                        currentTime  = total
                        synced       = true
                        qfCount      = 0
                        qfIndex      = 0
                        idx += 9  // F7까지 소비 (루프 끝 idx+=1 포함 시 10바이트 전진)
                        // onTimeUpdate 호출하지 않음: 정지 상태에서 재생헤드만 점프해도
                        // Logic이 Full Frame을 보내는데, 이때 재생 중으로 오판하면 안 됨.
                        // 위치만 기억해두면 재생 시작 시 Quarter Frame이 즉시(10ms) 이어받음.
                    }

                case 0xF1 where idx + 1 < count:
                    // MTC Quarter Frame
                    idx += 1
                    let data       = raw[idx]
                    let nibbleType = Int((data >> 4) & 0x07)
                    qfBits[nibbleType] = data & 0x0F
                    qfCount += 1

                    mtcReceived = true
                    resetMTCTimeout()
                    if qfCount >= 8 {
                        let frames   = Int(qfBits[0]) | (Int(qfBits[1]) << 4)
                        let secs     = Int(qfBits[2]) | (Int(qfBits[3]) << 4)
                        let mins     = Int(qfBits[4]) | (Int(qfBits[5]) << 4)
                        let hours    = Int(qfBits[6]) | (Int(qfBits[7] & 0x01) << 4)
                        let rateCode = Int((qfBits[7] >> 1) & 0x03)
                        updateFPS([24.0, 25.0, 29.97, 30.0][rateCode])
                        let total    = Double(hours)*3600 + Double(mins)*60 + Double(secs) + Double(frames)/fps
                        currentTime  = total
                        synced       = true
                        qfCount      = 0
                        qfIndex      = 0
                        let t = total
                        DispatchQueue.main.async { self.onTimeUpdate?(t) }
                    } else if synced {
                        qfIndex = (qfIndex + 1) % 8
                        currentTime += 1.0 / (4.0 * fps)
                        let t = currentTime
                        DispatchQueue.main.async { self.onTimeUpdate?(t) }
                    }
                    resetSilenceTimer()

                default:
                    break
                }
                idx += 1
            }
        }
    }
}
