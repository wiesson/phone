import AVFoundation
import Darwin
import Foundation

struct AudioFrame: @unchecked Sendable {
    let speaker: Speaker
    let sampleRate: Double
    let channels: AVAudioChannelCount
    let format: AVAudioCommonFormat
    let samples: Data
}

final class AudioTapServer: @unchecked Sendable {
    static let socketPath = "/tmp/phone-audio-\(getuid()).sock"

    private let queue = DispatchQueue(label: "phone.audio-tap", qos: .userInitiated)
    private var descriptor: Int32 = -1
    private var running = false
    private let countLock = NSLock()
    private var frameCounts: [Speaker: Int] = [:]
    var onFrame: (@Sendable (AudioFrame) -> Void)?

    /// Returns and resets the per-speaker frame counters (for diagnostics).
    /// Uses a lock because the receive loop permanently occupies the queue.
    func drainFrameCounts() -> [Speaker: Int] {
        countLock.lock()
        defer { countLock.unlock() }
        let counts = frameCounts
        frameCounts = [:]
        return counts
    }

    func start() throws {
        guard !running else { return }
        unlink(Self.socketPath)

        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Self.socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        descriptor = fd
        running = true
        queue.async { [weak self] in self?.receiveLoop() }
    }

    func stop() {
        running = false
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        unlink(Self.socketPath)
    }

    private func receiveLoop() {
        var packet = [UInt8](repeating: 0, count: 65_536)
        while running {
            let count = recv(descriptor, &packet, packet.count, 0)
            if count <= 0 {
                if running { usleep(10_000) }
                continue
            }
            guard let frame = parse(packet[0..<count]) else { continue }
            countLock.lock()
            frameCounts[frame.speaker, default: 0] += 1
            countLock.unlock()
            onFrame?(frame)
        }
    }

    private func parse(_ bytes: ArraySlice<UInt8>) -> AudioFrame? {
        // PTAP | version | direction | format | channels | sampleRate | payloadBytes
        guard bytes.count >= 16, Array(bytes.prefix(4)) == [0x50, 0x54, 0x41, 0x50] else { return nil }
        let values = Array(bytes)
        guard values[4] == 1,
              let speaker = Speaker(rawValue: values[5]),
              let format = commonFormat(values[6]) else { return nil }
        let channels = AVAudioChannelCount(values[7])
        let sampleRate = UInt32(values[8]) | UInt32(values[9]) << 8 | UInt32(values[10]) << 16 | UInt32(values[11]) << 24
        let payloadCount = Int(UInt32(values[12]) | UInt32(values[13]) << 8 | UInt32(values[14]) << 16 | UInt32(values[15]) << 24)
        guard payloadCount > 0, values.count == 16 + payloadCount else { return nil }
        return AudioFrame(
            speaker: speaker,
            sampleRate: Double(sampleRate),
            channels: channels,
            format: format,
            samples: Data(values[16...])
        )
    }

    private func commonFormat(_ value: UInt8) -> AVAudioCommonFormat? {
        switch value {
        case 1: .pcmFormatInt16
        case 2: .pcmFormatInt32
        case 3: .pcmFormatFloat32
        case 4: .pcmFormatFloat64
        default: nil
        }
    }

    deinit { stop() }
}
