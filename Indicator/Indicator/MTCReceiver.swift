import CoreMIDI
import Foundation

class MTCReceiver {

    var onTimeUpdate: ((TimeInterval) -> Void)?
    var onStop: (() -> Void)?
    var onBeat: (() -> Void)?   // MIDI Clock 24펄스마다 호출 (= 1박자)

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
            if srcName.lowercased().contains("iac") {
                MIDIPortConnectSource(port, src, nil)
                connectedAny = true
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

    private func resetSilenceTimer() {
        silenceTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.synced = false
            DispatchQueue.main.async { self?.onStop?() }
        }
        silenceTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func process(_ pkt: MIDIPacket) {
        withUnsafeBytes(of: pkt.data) { raw in
            var idx = 0
            let count = Int(pkt.length)
            while idx < count {
                let byte = raw[idx]

                switch byte {
                case 0xF8:
                    // MIDI Timing Clock — 24펄스/박자
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

                case 0xF1 where idx + 1 < count:
                    // MTC Quarter Frame
                    idx += 1
                    let data       = raw[idx]
                    let nibbleType = Int((data >> 4) & 0x07)
                    qfBits[nibbleType] = data & 0x0F
                    qfCount += 1

                    if qfCount >= 8 {
                        let frames   = Int(qfBits[0]) | (Int(qfBits[1]) << 4)
                        let secs     = Int(qfBits[2]) | (Int(qfBits[3]) << 4)
                        let mins     = Int(qfBits[4]) | (Int(qfBits[5]) << 4)
                        let hours    = Int(qfBits[6]) | (Int(qfBits[7] & 0x01) << 4)
                        let rateCode = Int((qfBits[7] >> 1) & 0x03)
                        fps          = [24.0, 25.0, 29.97, 30.0][rateCode]
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
