import Darwin
import Foundation

struct BaresipSocketPaths: Equatable, Sendable {
    let tap: String
    let injection: String

    init(identifier: String, uid: uid_t = getuid()) {
        tap = "/tmp/phone-audio-\(uid)-\(identifier).sock"
        injection = "/tmp/phone-audio-inject-\(uid)-\(identifier).sock"
    }
}

func sanitizedBaresipInstanceAOR(_ aor: String) -> String {
    let bytes = aor.lowercased().utf8
    var result = ""
    for byte in bytes {
        switch byte {
        case 48...57, 97...122, 45, 46:
            result.append(Character(UnicodeScalar(byte)))
        default:
            result += String(format: "_%02x", byte)
        }
    }
    guard result.utf8.count > 44 else { return result.isEmpty ? "account" : result }
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in bytes {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return "\(String(result.prefix(31)))-\(String(format: "%012llx", hash & 0xffffffffffff))"
}

func baresipRTPPortRange(instanceIndex: Int) -> String {
    let first = 40_000 + instanceIndex * 100
    return "\(first)-\(first + 99)"
}

func perInstanceBaresipConfig(sharedConfig: String, instanceIndex: Int) -> String {
    let portLine = "rtp_ports\t\t\(baresipRTPPortRange(instanceIndex: instanceIndex))"
    var lines = sharedConfig.components(separatedBy: "\n")
    var replaced = false
    for index in lines.indices {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("rtp_ports") || trimmed.hasPrefix("#rtp_ports") {
            guard !replaced else {
                lines[index] = ""
                continue
            }
            lines[index] = portLine
            replaced = true
        }
    }
    if !replaced { lines.append(portLine) }
    return lines.joined(separator: "\n")
}

func managedInstanceAccountLine(account: ManagedSIPAccount, password: String) throws -> String {
    let line = try account.accountLine(password: password)
        .trimmingCharacters(in: .newlines)
    return "\(line);answermode=manual\n"
}

func resolvedCallAccountAOR(instanceAOR: String?, parsedCalledAOR: String?) -> String? {
    instanceAOR ?? parsedCalledAOR
}

enum IncomingCallDisposition: Equatable {
    case present
    case deferWhileBusy
}

func incomingCallDisposition(currentInstanceID: String?, incomingInstanceID: String) -> IncomingCallDisposition {
    currentInstanceID == nil ? .present : .deferWhileBusy
}

func canArmAutoAnswer(currentInstanceID: String?, armedInstanceID: String) -> Bool {
    currentInstanceID == armedInstanceID
}

struct RegistrationAggregate: Equatable {
    let status: RegistrationStatus
    let registered: Int
    let total: Int

    var summary: String { "\(registered) of \(total) registered" }
}

func baresipInstanceEnvironment(
    base: [String: String],
    socketPaths: BaresipSocketPaths
) -> [String: String] {
    var environment = base
    environment["PHONE_TAP_SOCKET"] = socketPaths.tap
    environment["PHONE_INJECT_SOCKET"] = socketPaths.injection
    return environment
}

func aggregateRegistrationState(_ statuses: [RegistrationStatus], total: Int) -> RegistrationAggregate {
    guard total > 0 else { return RegistrationAggregate(status: .idle, registered: 0, total: 0) }
    let registered = statuses.count { $0 == .registered }
    if registered == total {
        return RegistrationAggregate(status: .registered, registered: registered, total: total)
    }
    if statuses.count == total, statuses.allSatisfy({ $0 == .idle }) {
        return RegistrationAggregate(status: .idle, registered: registered, total: total)
    }
    if statuses.contains(where: {
        if case .registering = $0 { return true }
        if case .idle = $0 { return true }
        return false
    }) || statuses.count < total {
        return RegistrationAggregate(status: .registering, registered: registered, total: total)
    }
    let failure = statuses.compactMap { status -> String? in
        if case .failed(let message) = status { return message }
        return nil
    }.first ?? "Registration failed"
    return RegistrationAggregate(status: .failed(failure), registered: registered, total: total)
}

/// Waits for one line to reach a state it will not leave on its own. `nil` means
/// the deadline passed without baresip answering either way: the caller has to
/// record that as a failure rather than only report it, because the line
/// otherwise keeps the `registering` entry it was polled on for as long as the
/// app runs.
@MainActor
func registrationStatusOnceSettled(
    timeout: Duration,
    now: () -> ContinuousClock.Instant,
    status: () -> RegistrationStatus,
    sleep: () async -> Void
) async -> RegistrationStatus? {
    let deadline = now().advanced(by: timeout)
    while now() < deadline {
        let current = status()
        switch current {
        case .registered, .failed: return current
        case .idle, .registering: await sleep()
        }
    }
    // The deadline can pass during the last wait, after the answer arrived. One
    // more look before giving up keeps a registration that did complete from
    // being reported — and written back — as a timeout.
    let last = status()
    switch last {
    case .registered, .failed: return last
    case .idle, .registering: return nil
    }
}

/// Names the duration that was actually waited: the timeout is a parameter, and
/// a hard-coded number turns into a lie the moment a caller passes another one.
func registrationTimeoutMessage(_ timeout: Duration) -> String {
    let seconds = Double(timeout.components.seconds)
        + Double(timeout.components.attoseconds) / 1e18
    let value = seconds == seconds.rounded() ? "\(Int(seconds))" : String(format: "%.1f", seconds)
    return "Registration did not complete within \(value) seconds."
}

/// The per-line entries for a failure that happened before any baresip process
/// existed. The interface reads the entry per line, not the aggregate, so a
/// startup failure recorded only in the aggregate leaves every line reading
/// `idle` — no registration attempted, nothing wrong.
func failedRegistrationStatuses(
    for accounts: [ManagedSIPAccount],
    message: String
) -> [String: RegistrationStatus] {
    Dictionary(
        accounts.map { (sanitizedBaresipInstanceAOR($0.sipAddress), RegistrationStatus.failed(message)) },
        uniquingKeysWith: { first, _ in first }
    )
}

/// Whether the pid file still belongs to this process, rather than to a
/// successor that reused the same path.
func pidFileNamesProcess(pid: Int32, at url: URL) -> Bool {
    guard let value = try? String(contentsOf: url, encoding: .utf8) else { return false }
    return Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) == pid
}

@MainActor
final class BaresipInstance {
    let id: String
    let accountAOR: String?
    let configDirectory: URL
    let pidFileURL: URL
    let socketPaths: BaresipSocketPaths
    private(set) var registrationStatus: RegistrationStatus = .idle

    var onOutput: ((BaresipInstance, String) -> Void)?
    var onTermination: ((BaresipInstance) -> Void)?
    var onAudioFrame: (@Sendable (String, AudioFrame) -> Void)?

    private var process: Process?
    private var input: Pipe?
    private let audioTap: AudioTapServer

    init(id: String, accountAOR: String?, configDirectory: URL, pidFileURL: URL) {
        self.id = id
        self.accountAOR = accountAOR
        self.configDirectory = configDirectory
        self.pidFileURL = pidFileURL
        socketPaths = BaresipSocketPaths(identifier: id)
        audioTap = AudioTapServer(socketPath: socketPaths.tap)
        audioTap.onFrame = { [id] frame in
            Task { @MainActor [weak self] in self?.onAudioFrame?(id, frame) }
        }
    }

    var isRunning: Bool { process?.isRunning == true }

    func setRegistrationStatus(_ status: RegistrationStatus) {
        registrationStatus = status
    }

    func start(executable: String, currentDirectory: URL) throws {
        guard process == nil else { return }
        try audioTap.start()

        let task = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.currentDirectoryURL = currentDirectory
        task.arguments = ["-f", configDirectory.path, "-c"]
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stdout
        task.environment = baresipInstanceEnvironment(
            base: ProcessInfo.processInfo.environment,
            socketPaths: socketPaths
        )
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.consume(text) }
        }
        task.terminationHandler = { [weak self, weak task] _ in
            guard let task else { return }
            Task { @MainActor [weak self] in self?.didStop(task) }
        }

        process = task
        input = stdin
        do {
            try task.run()
            try String(task.processIdentifier).write(to: pidFileURL, atomically: true, encoding: .utf8)
            registrationStatus = .registering
        } catch {
            process = nil
            input = nil
            audioTap.stop()
            throw error
        }
    }

    func send(_ command: String) {
        guard let data = "\(command)\n".data(using: .utf8), let input else { return }
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    func stop() {
        guard let task = process else {
            audioTap.stop()
            try? FileManager.default.removeItem(at: pidFileURL)
            return
        }
        send("/quit")
        try? input?.fileHandleForWriting.close()
        Task { @MainActor [weak self, weak task] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, let task, task.isRunning, self.process === task else { return }
            task.terminate()
        }
    }

    func stopAndWait() {
        guard let task = process else {
            audioTap.stop()
            try? FileManager.default.removeItem(at: pidFileURL)
            return
        }
        send("/quit")
        try? input?.fileHandleForWriting.close()
        wait(for: task, until: Date().addingTimeInterval(1.5))
        if task.isRunning {
            task.terminate()
            wait(for: task, until: Date().addingTimeInterval(0.75))
        }
        if task.isRunning {
            kill(task.processIdentifier, SIGKILL)
            wait(for: task, until: Date().addingTimeInterval(0.75))
        }
        if !task.isRunning { didStop(task) }
    }

    func cleanupOrphanedProcess() {
        guard let value = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1,
              kill(pid, 0) == 0 else {
            try? FileManager.default.removeItem(at: pidFileURL)
            return
        }

        let probe = Process()
        let output = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/bin/ps")
        probe.arguments = ["-p", String(pid), "-o", "command="]
        probe.standardOutput = output
        try? probe.run()
        probe.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let command = String(data: data, encoding: .utf8) ?? ""
        guard command.contains("baresip"), command.contains(configDirectory.path) else {
            try? FileManager.default.removeItem(at: pidFileURL)
            return
        }

        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(0.75)
        while kill(pid, 0) == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    func drainAudioFrameCounts() -> [Speaker: Int] {
        audioTap.drainFrameCounts()
    }

    private func wait(for task: Process, until deadline: Date) {
        while task.isRunning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func consume(_ text: String) {
        onOutput?(self, text)
    }

    private func didStop(_ stoppedProcess: Process) {
        guard process === stoppedProcess else { return }
        process = nil
        input = nil
        audioTap.stop()
        // Successive instances for one line share this path. stopAndWait() gives
        // up after its deadlines, so a process can die late — after a
        // replacement already wrote its own pid — and must not delete that.
        if pidFileNamesProcess(pid: stoppedProcess.processIdentifier, at: pidFileURL) {
            try? FileManager.default.removeItem(at: pidFileURL)
        }
        onTermination?(self)
    }
}
