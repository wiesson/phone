import Foundation
import Testing
@testable import Phone

private struct CallerNameCase: Sendable {
    let line: String
    let expected: String?
}

private let callerNameCases = [
    CallerNameCase(line: "Incoming call from: sip:+491234@example.com", expected: "+491234"),
    CallerNameCase(line: "incoming call from: sip:%2B49%20123@example.com", expected: "+49 123"),
    CallerNameCase(line: "Incoming call from: sip:alice", expected: "alice"),
    CallerNameCase(line: "Call from: sip:alice@example.com", expected: nil)
]

private struct DialTargetCase: Sendable {
    let value: String
    let expected: String?
}

private let dialTargetCases = [
    DialTargetCase(value: "tel:+49%20123", expected: "+49123"),
    DialTargetCase(value: "callto://+49-30-123", expected: "+4930123"),
    DialTargetCase(value: "sip:user@host", expected: "user@host"),
    DialTargetCase(value: "tel:%28+49%29%20123-45", expected: "+4912345")
]

@Test(arguments: callerNameCases)
private func parsesCallerNames(testCase: CallerNameCase) throws {
    #expect(parseCallerName(from: testCase.line) == testCase.expected)
}

@Test func parsesContactsFileContent() {
    let content = """
    # Personal contacts
    "Alice" <sip:alice@example.com>
      "Bob Smith" <sip:bob@example.net>;presence=p2p
    "Catch all" <sip:*@example.com>
    "Missing URI"
    Missing quotes <sip:charlie@example.com>
    "Missing terminator" <sip:dana@example.com
    "" <sip:nobody@example.com>
    """

    #expect(parseContacts(content) == ["alice": "Alice", "bob": "Bob Smith"])
}

@Test func parsesFirstUnmanagedAccountAOR() {
    let content = """
    # Account managed by the user

    "Private" <sip:%2B49123@tel.t-online.de>;regint=300
    <sip:second@example.com>
    """

    #expect(parseAccountAOR(from: content) == "+49123@tel.t-online.de")
}

@Test(arguments: dialTargetCases)
private func normalizesDialURLs(testCase: DialTargetCase) throws {
    let url = try #require(URL(string: testCase.value))
    #expect(normalizedDialTarget(from: url) == testCase.expected)
}
