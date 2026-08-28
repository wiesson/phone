import AVFoundation
import Foundation
import Testing
@testable import Phone

private struct AudioFormatCase: Sendable {
    let wireValue: UInt8
    let expected: AVAudioCommonFormat
}

private let audioFormats = [
    AudioFormatCase(wireValue: 1, expected: .pcmFormatInt16),
    AudioFormatCase(wireValue: 2, expected: .pcmFormatInt32),
    AudioFormatCase(wireValue: 3, expected: .pcmFormatFloat32),
    AudioFormatCase(wireValue: 4, expected: .pcmFormatFloat64)
]

@Test(arguments: audioFormats)
private func parsesValidPTAPFormats(formatCase: AudioFormatCase) throws {
    let payload: [UInt8] = [0x10, 0x20, 0x30, 0x40]
    let frame = try #require(AudioFrameParser.parse(packet(format: formatCase.wireValue, payload: payload)[...]))

    #expect(frame.speaker == .caller)
    #expect(frame.sampleRate == 48_000)
    #expect(frame.channels == 2)
    #expect(frame.format == formatCase.expected)
    #expect(frame.samples == Data(payload))
    #expect(AudioFrameParser.commonFormat(formatCase.wireValue) == formatCase.expected)
}

@Test func rejectsWrongPTAPMagic() {
    var bytes = packet(format: 1)
    bytes[0] = 0
    #expect(AudioFrameParser.parse(bytes[...]) == nil)
}

@Test func rejectsWrongPTAPVersion() {
    var bytes = packet(format: 1)
    bytes[4] = 2
    #expect(AudioFrameParser.parse(bytes[...]) == nil)
}

@Test func rejectsTruncatedPTAPPayload() {
    var bytes = packet(format: 1, payload: [1, 2, 3, 4])
    bytes.removeLast()
    #expect(AudioFrameParser.parse(bytes[...]) == nil)
}

@Test func rejectsPTAPPayloadSizeMismatch() {
    var bytes = packet(format: 1, payload: [1, 2, 3, 4])
    bytes[12] = 3
    #expect(AudioFrameParser.parse(bytes[...]) == nil)
}

private func packet(format: UInt8, payload: [UInt8] = [1, 2, 3, 4]) -> [UInt8] {
    let sampleRate: UInt32 = 48_000
    let payloadCount = UInt32(payload.count)
    return [
        0x50, 0x54, 0x41, 0x50,
        1, Speaker.caller.rawValue, format, 2,
        UInt8(sampleRate & 0xff),
        UInt8((sampleRate >> 8) & 0xff),
        UInt8((sampleRate >> 16) & 0xff),
        UInt8((sampleRate >> 24) & 0xff),
        UInt8(payloadCount & 0xff),
        UInt8((payloadCount >> 8) & 0xff),
        UInt8((payloadCount >> 16) & 0xff),
        UInt8((payloadCount >> 24) & 0xff)
    ] + payload
}
