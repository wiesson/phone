import Foundation
import Testing
@testable import Phone

struct CallEventParsingTests {
    @Test func helpMenuOutputIsNotACallEvent() {
        let helpLines = [
            "  /acceptdir ..                  Accept incoming call with audio and videodirection.",
            "  /accept               a        Accept incoming call",
            "  /hangup             b        Hangup call",
            "  /hangupall ..                Hangup all calls with direction",
            "  /listcalls          l        List active calls",
            "  /sndcode ..                    Send Code"
        ]
        for line in helpLines {
            #expect(PhoneController.parseCallEvent(line) == nil, "misclassified: \(line)")
        }
    }

    @Test func classifiesRealCallEvents() {
        #expect(PhoneController.parseCallEvent("menu: sip:+491234@tel.t-online.de: Incoming call from:  sip:+441164649449@versatel.de;user=phone - (press 'a' to accept)") == .incoming("+491234@tel.t-online.de"))
        #expect(PhoneController.parseCallEvent("+491234@tel.t-online.de: Call established: sip:+441164649449@versatel.de;user=phone") == .established)
        #expect(PhoneController.parseCallEvent("All 1 useragent registered successfully! (309 ms)") == .registered)
        #expect(PhoneController.parseCallEvent("session closed: Connection reset by peer") == .closed(nil))
        #expect(PhoneController.parseCallEvent("sip:+491234@tel.t-online.de: session closed: 403 Forbidden") == .closed("403 Forbidden"))
        #expect(PhoneController.parseCallEvent("[0:00:07] audio=63978/62699 (bit/s)") == nil)
    }

    @Test func parsesCalledAORFromRealIncomingLines() {
        let line = "menu: sip:+491234@tel.t-online.de: Incoming call from:  sip:+441164649449@versatel.de;user=phone - (press 'a' to accept)"
        #expect(parseIncomingCalledAOR(from: line) == "+491234@tel.t-online.de")
        #expect(PhoneController.parseCallEvent(line) == .incoming("+491234@tel.t-online.de"))
        #expect(parseIncomingCalledAOR(from: "incoming call from: sip:caller@example.com") == nil)
    }

    @Test func classifiesLoopbackTranscript() throws {
        let fixtureURL = try #require(Bundle.module.url(forResource: "loopback-transcript", withExtension: "txt"))
        let fixture = try String(contentsOf: fixtureURL, encoding: .utf8)
        let events = fixture.split(separator: "\n").compactMap { PhoneController.parseCallEvent(String($0)) }

        #expect(events == [.dialing, .dialing, .established, .closed(nil)])
        #expect(events.filter { $0 == .registered }.isEmpty)
        #expect(events.filter { $0 == .established }.count == 1)
        #expect(events.filter { if case .closed = $0 { true } else { false } }.count == 1)
        #expect(events.filter { if case .incoming = $0 { true } else { false } }.isEmpty)
    }

    @Test func filtersOnlyAudioStatisticsFromDiagnostics() {
        let input = "kept before\n[0:00:07] audio=63978/62699 (bit/s)\rkept after\n"
        #expect(filteringAudioStatistics(from: input) == "kept before\nkept after\n")
        #expect(filteringAudioStatistics(from: "audio=63978/62699 (bit/s)\n") == "audio=63978/62699 (bit/s)\n")
    }
}
