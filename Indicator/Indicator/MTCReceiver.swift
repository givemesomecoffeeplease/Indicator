import CoreMIDI
import Foundation

class MTCReceiver {

    var onTimeUpdate: ((TimeInterval) -> Void)?
    private(set) var currentTime: TimeInterval = 0

    private var client = MIDIClientRef()
    private var port   = MIDIPortRef()

    private var qfBits: [UInt8] = Array(repeating: 0, count: 8)
    private var qfCount = 0

    // After initial sync, we know fps and can advance by 1 QF per message
    private var synced = false
    private var fps: Double = 25.0
    private var qfIndex = 0  // 0–7, cycles per full frame

    func start() {
        MIDIClientCreate("IndicatorMTC" as CFString, nil, nil, &client)
        MIDIInputPortCreateWithBlock(client, "MTCIn" as CFString, &port) { [weak self] pktList, _ in
            self?.receive(pktList)
        }
        for i in 0..<MIDIGetNumberOfSources() {
            MIDIPortConnectSource(port, MIDIGetSource(i), nil)
        }
    }

    func stop() {
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

    private func process(_ pkt: MIDIPacket) {
        withUnsafeBytes(of: pkt.data) { raw in
            var idx = 0
            let count = Int(pkt.length)
            while idx < count {
                let byte = raw[idx]
                if byte == 0xF1, idx + 1 < count {
                    idx += 1
                    let data        = raw[idx]
                    let nibbleType  = Int((data >> 4) & 0x07)
                    qfBits[nibbleType] = data & 0x0F
                    qfCount += 1

                    if qfCount >= 8 {
                        // Full frame decoded — establish sync anchor
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
                        // Each quarter-frame advances time by 1/(4*fps) seconds
                        qfIndex = (qfIndex + 1) % 8
                        currentTime += 1.0 / (4.0 * fps)
                        let t = currentTime
                        DispatchQueue.main.async { self.onTimeUpdate?(t) }
                    }
                }
                idx += 1
            }
        }
    }
}
