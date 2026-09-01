import Foundation
import PhoneAutomation
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
    #expect(first.tap != second.tap)
    #expect(first.injection != second.injection)
    #expect(!first.tap.hasPrefix("/tmp/"))
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

@Test @MainActor func waitingForARegistrationReportsATimeoutInsteadOfAStatus() async {
    let clock = ContinuousClock()
    var elapsed = Duration.zero
    var polls = 0
    // A line baresip never answers for: the wait has to end with `nil` so the
    // caller records the timeout, instead of handing back the `registering` it
    // last saw as if that were an answer.
    let timedOut = await registrationStatusOnceSettled(
        timeout: .seconds(20),
        now: { clock.now.advanced(by: elapsed) },
        status: {
            polls += 1
            return .registering
        },
        sleep: { elapsed += .seconds(1) }
    )

    #expect(timedOut == nil)
    // Twenty polls inside the window, and one more once it has passed.
    #expect(polls == 21)

    // A registration that lands during the last wait is not a timeout: the look
    // after the deadline still reports it, so it is not written back as failed.
    var lateCalls = 0
    let late = await registrationStatusOnceSettled(
        timeout: .seconds(2),
        now: { clock.now.advanced(by: elapsed) },
        status: {
            lateCalls += 1
            return lateCalls > 2 ? .registered : .registering
        },
        sleep: { elapsed += .seconds(1) }
    )

    #expect(late == .registered)

    elapsed = .zero
    var settledAfter = 0
    let settled = await registrationStatusOnceSettled(
        timeout: .seconds(20),
        now: { clock.now.advanced(by: elapsed) },
        status: {
            settledAfter += 1
            return settledAfter < 3 ? .registering : .failed("401 Unauthorized")
        },
        sleep: { elapsed += .seconds(1) }
    )

    #expect(settled == .failed("401 Unauthorized"))
    #expect(settledAfter == 3)
}

@Test func aRegistrationTimeoutNamesTheDurationItActuallyWaited() {
    #expect(registrationTimeoutMessage(.seconds(20)) == "Registration did not complete within 20 seconds.")
    #expect(registrationTimeoutMessage(.milliseconds(1500)) == "Registration did not complete within 1.5 seconds.")
}

@Test func aStartupFailureIsRecordedForEveryEnabledLine() {
    let first = ManagedSIPAccount(
        provider: .custom,
        username: "First",
        domain: "Example.com",
        outboundProxy: "",
        stunServer: "",
        mediaEncryption: ""
    )
    let second = ManagedSIPAccount(
        provider: .custom,
        username: "second",
        domain: "example.net",
        outboundProxy: "",
        stunServer: "",
        mediaEncryption: ""
    )
    let statuses = failedRegistrationStatuses(for: [first, second], message: "baresip was not found")

    // The keys are the instance ids the interface looks a line up by, so the
    // failure reaches the line and not only the aggregate.
    #expect(statuses[sanitizedBaresipInstanceAOR(first.sipAddress)] == .failed("baresip was not found"))
    #expect(statuses[sanitizedBaresipInstanceAOR(second.sipAddress)] == .failed("baresip was not found"))
    #expect(aggregateRegistrationState(Array(statuses.values), total: 2).status == .failed("baresip was not found"))
}


/// The sandbox container's temporary directory is long; a Unix socket path
/// is not allowed to be. The longest line identifier there is has to fit.
@Test func socketPathsFitASandboxContainerForTheLongestLineIdentifier() {
    let container = "/Users/someoneswithalongname/Library/Containers/com.nordwerk.phone/Data/tmp"
    let longest = sanitizedBaresipInstanceAOR(String(repeating: "x", count: 200) + "@" + String(repeating: "y", count: 200))
    let paths = BaresipSocketPaths(identifier: longest, uid: 501, directory: container)
    let limit = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
    #expect(paths.tap.utf8.count <= limit)
    #expect(paths.injection.utf8.count <= limit)
    #expect(paths.tap.hasPrefix(container + "/"))
    #expect(shortSocketDigest("a@b") != shortSocketDigest("a@c"))
    #expect(shortSocketDigest("a@b") == shortSocketDigest("a@b"))
}

/// Without an app group the control socket stays where the README says it
/// is, so a development build and its helper keep finding each other.
@Test func controlSocketFallsBackToApplicationSupportWithoutAnAppGroup() {
    let url = PhoneControlSocket.url()
    #expect(url.lastPathComponent == "control.sock")
    #expect(url.path.contains("Application Support/Phone") || url.path.contains("Group Containers"))
}
