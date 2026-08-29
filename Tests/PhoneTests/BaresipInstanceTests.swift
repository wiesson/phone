import Foundation
import Testing
@testable import Phone

@Test func generatesIsolatedManagedInstanceConfiguration() throws {
    let template = """
    module_path\t\t/bundled/modules
    #rtp_ports\t\t10000-20000
    module\t\t\tphone_tap.so
    module\t\t\tuuid.so
    """
    let first = perInstanceBaresipConfig(sharedConfig: template, instanceIndex: 0)
    let second = perInstanceBaresipConfig(sharedConfig: template, instanceIndex: 1)

    #expect(first.contains("module_path\t\t/bundled/modules"))
    #expect(second.contains("module_path\t\t/bundled/modules"))
    #expect(first.contains("rtp_ports\t\t40000-40099"))
    #expect(second.contains("rtp_ports\t\t40100-40199"))
    #expect(first.components(separatedBy: "rtp_ports").count == 2)
    #expect(second.components(separatedBy: "rtp_ports").count == 2)
    #expect(first.contains("module\t\t\tuuid.so"))
    #expect(!first.components(separatedBy: "\n").contains { $0.hasPrefix("uuid\t") })
}

@Test func generatesExactlyOneManualAccountLinePerInstance() throws {
    let account = ManagedSIPAccount(
        provider: .custom,
        username: "line-a",
        domain: "example.test",
        outboundProxy: "",
        stunServer: "",
        mediaEncryption: ""
    )
    let content = try managedInstanceAccountLine(account: account, password: "test-password")

    #expect(content.split(separator: "\n").count == 1)
    #expect(content.hasPrefix("<sip:line-a@example.test>"))
    #expect(content.contains(";answermode=manual"))
}

@Test func injectsUniqueAudioSocketPathsIntoEachChildEnvironment() {
    let first = BaresipSocketPaths(identifier: sanitizedBaresipInstanceAOR("line-a@example.test"), uid: 501)
    let second = BaresipSocketPaths(identifier: sanitizedBaresipInstanceAOR("line-b@example.test"), uid: 501)
    let firstEnvironment = baresipInstanceEnvironment(base: ["BASE": "value"], socketPaths: first)
    let secondEnvironment = baresipInstanceEnvironment(base: [:], socketPaths: second)

    #expect(first.tap != second.tap)
    #expect(first.injection != second.injection)
    #expect(firstEnvironment["BASE"] == "value")
    #expect(firstEnvironment["PHONE_TAP_SOCKET"] == first.tap)
    #expect(firstEnvironment["PHONE_INJECT_SOCKET"] == first.injection)
    #expect(secondEnvironment["PHONE_TAP_SOCKET"] == second.tap)
    #expect(secondEnvironment["PHONE_INJECT_SOCKET"] == second.injection)
}

@Test func routesIncomingEventToOwningInstanceAccount() {
    #expect(
        resolvedCallAccountAOR(
            instanceAOR: "owned@example.test",
            parsedCalledAOR: "ambiguous@example.invalid"
        ) == "owned@example.test"
    )
    #expect(
        resolvedCallAccountAOR(instanceAOR: nil, parsedCalledAOR: "manual@example.test") ==
        "manual@example.test"
    )
}

@Test func suppressesSecondIncomingCallWhileAnotherInstanceOwnsTheUI() {
    #expect(
        incomingCallDisposition(currentInstanceID: nil, incomingInstanceID: "first") == .present
    )
    #expect(
        incomingCallDisposition(currentInstanceID: "first", incomingInstanceID: "second") == .deferWhileBusy
    )
    #expect(!canArmAutoAnswer(currentInstanceID: "first", armedInstanceID: "second"))
    #expect(canArmAutoAnswer(currentInstanceID: "first", armedInstanceID: "first"))
}

@Test func aggregatesPerInstanceRegistrationState() {
    let partial = aggregateRegistrationState(
        [.registered, .registering, .registered],
        total: 3
    )
    let complete = aggregateRegistrationState(
        [.registered, .registered, .registered],
        total: 3
    )

    #expect(partial.status == .registering)
    #expect(partial.summary == "2 of 3 registered")
    #expect(complete.status == .registered)
    #expect(complete.summary == "3 of 3 registered")
    #expect(aggregateRegistrationState([.idle, .idle], total: 2).status == .idle)
}

@Test func aPIDFileIsOnlyClaimedByTheProcessThatWroteIt() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("phone-pid-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }

    try "4711\n".write(to: url, atomically: true, encoding: .utf8)
    #expect(pidFileNamesProcess(pid: 4711, at: url))
    // A late-dying predecessor must not delete its successor's pid file.
    #expect(!pidFileNamesProcess(pid: 4712, at: url))

    try FileManager.default.removeItem(at: url)
    #expect(!pidFileNamesProcess(pid: 4711, at: url))
}
