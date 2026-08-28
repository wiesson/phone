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
        try? FileManager.default.removeItem(at: pidFileURL)
        onTermination?(self)
    }
}
