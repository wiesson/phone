import AppKit
import Combine
import Darwin
import Foundation
import UserNotifications

@MainActor
final class PhoneController: NSObject, ObservableObject, @preconcurrency UNUserNotificationCenterDelegate {
    @Published private(set) var state: CallState = .stopped
    @Published var number = ""
    @Published private(set) var transcript: [TranscriptEntry] = []
    @Published private(set) var summary: CallSummary?
    @Published private(set) var intelligenceStatus = "Local transcription ready"
    @Published private(set) var callStartedAt: Date?

    private var process: Process?
    private var input: Pipe?
    private var lineBuffer = ""
    private let audioTap = AudioTapServer()
    private let intelligence = LocalIntelligence()
    private var draftIDs: [Speaker: UUID] = [:]
    private var intelligenceRunning = false
    private var audioFrameCounts: [Speaker: Int] = [:]
    private var hasRegisteredAccount = false
    private var isShuttingDown = false

    private var diagnosticLogURL: URL {
        projectRoot.appendingPathComponent("runtime/phone.log")
    }

    private var pidFileURL: URL {
        projectRoot.appendingPathComponent("runtime/baresip.pid")
    }

    override init() {
        super.init()
        number = UserDefaults.standard.string(forKey: "lastDialedNumber") ?? ""
        audioTap.onFrame = { [weak self] frame in
            guard let self else { return }
            Task { @MainActor in
                self.countAudioFrame(frame)
                await self.intelligence.append(frame)
            }
        }
    }

    func start() {
        installNotifications()
        do {
            try audioTap.start()
        } catch {
            intelligenceStatus = "Audio bridge unavailable"
        }
        startBaresip()
        intelligenceStatus = "Preparing local models …"
        Task {
            do {
                try await intelligence.prepare()
                await MainActor.run { self.intelligenceStatus = "Local transcription ready" }
            } catch {
                await MainActor.run { self.intelligenceStatus = error.localizedDescription }
            }
        }
    }

    func toggleBaresip() {
        process == nil ? startBaresip() : stopBaresip()
    }

    func recoverFromError() {
        state = process == nil ? .stopped : (hasRegisteredAccount ? .ready : .starting)
        if process == nil { startBaresip() }
    }

    func dial() {
        guard state.isReady else { return }
        let value = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else {
            state = .error("Please enter a valid number")
            return
        }
        number = value
        UserDefaults.standard.set(value, forKey: "lastDialedNumber")
        state = .dialing(value)
        send("/dial \(value)")
    }

    func answer() {
        guard case .ringing(let caller) = state else { return }
        state = .answering(caller)
        clearIncomingCallNotification()
        send("a")
    }

    func reject() {
        guard state.isRinging else { return }
        clearIncomingCallNotification()
        send("b")
        state = .ready
    }

    func hangup() {
        guard state.isInCall else { return }
        send("b")
        finishCall()
        state = .ready
    }

    func clearConversation() {
        transcript = []
        summary = nil
        draftIDs = [:]
    }

    func copyConversation() {
        let body = transcript.map { "\($0.speaker.title): \($0.text)" }.joined(separator: "\n")
        let result = [summary?.text, body].compactMap { $0 }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
    }

    func openRuntimeConfig() {
        NSWorkspace.shared.open(projectRoot.appendingPathComponent("runtime/baresip", isDirectory: true))
    }

    func quit() {
        shutdown()
        NSApp.terminate(nil)
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        clearIncomingCallNotification()
        audioTap.stop()
        stopBaresipAndWait()
    }

    private var projectRoot: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    private var baresipExecutable: String? {
        let candidates = [
            ProcessInfo.processInfo.environment["BARESIP_EXECUTABLE"],
            "/opt/homebrew/bin/baresip",
            "/usr/local/bin/baresip"
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func startBaresip() {
        guard process == nil else { return }
        isShuttingDown = false
        cleanupOrphanedBaresip()
        guard let executable = baresipExecutable else {
            state = .error("baresip was not found")
            return
        }
        let configDirectory = projectRoot.appendingPathComponent("runtime/baresip", isDirectory: true)
        guard FileManager.default.fileExists(atPath: configDirectory.appendingPathComponent("config").path) else {
            state = .error("baresip configuration is missing")
            return
        }

        let task = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.currentDirectoryURL = projectRoot
        task.arguments = ["-f", configDirectory.path, "-c"]
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.consume(text) }
        }
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.didStop() }
        }

        do {
            try task.run()
            process = task
            input = stdin
            try? String(task.processIdentifier).write(to: pidFileURL, atomically: true, encoding: .utf8)
            hasRegisteredAccount = false
            state = .starting
        } catch {
            state = .error("baresip could not be started")
        }
    }

    private func stopBaresip() {
        guard let childProcess = process else { return }
        clearIncomingCallNotification()
        send("/quit")
        try? input?.fileHandleForWriting.close()

        Task { @MainActor [weak self, weak childProcess] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, let childProcess, childProcess.isRunning, self.process === childProcess else { return }
            childProcess.terminate()
        }
    }

    private func stopBaresipAndWait() {
        guard let task = process else {
            try? FileManager.default.removeItem(at: pidFileURL)
            return
        }

        send("/quit")
        try? input?.fileHandleForWriting.close()
        let gracefulDeadline = Date().addingTimeInterval(1.5)
        while task.isRunning, Date() < gracefulDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        if task.isRunning {
            task.terminate()
            let forcedDeadline = Date().addingTimeInterval(0.75)
            while task.isRunning, Date() < forcedDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }

        if task.isRunning {
            kill(task.processIdentifier, SIGKILL)
        }
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    private func cleanupOrphanedBaresip() {
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
        let expectedConfig = projectRoot.appendingPathComponent("runtime/baresip").path
        guard command.contains("/opt/homebrew/bin/baresip"), command.contains(expectedConfig) else {
            try? FileManager.default.removeItem(at: pidFileURL)
            return
        }

        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(0.75)
        while kill(pid, 0) == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    private func didStop() {
        process = nil
        input = nil
        try? FileManager.default.removeItem(at: pidFileURL)
        if intelligenceRunning { finishCall() }
        state = .stopped
    }

    private func send(_ command: String) {
        appendDiagnostic("> \(command)\n")
        guard let data = "\(command)\n".data(using: .utf8), let input else { return }
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    private func appendDiagnostic(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: diagnosticLogURL.path) {
            fileManager.createFile(atPath: diagnosticLogURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: diagnosticLogURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch { }
    }

    private func consume(_ text: String) {
        appendDiagnostic(text)
        lineBuffer += text.replacingOccurrences(of: "\r", with: "\n")
        while let newline = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<newline])
            lineBuffer.removeSubrange(...newline)
            consumeLine(line)
        }
        if lineBuffer.count > 16_000 { lineBuffer.removeFirst(lineBuffer.count - 16_000) }
    }

    private func consumeLine(_ line: String) {
        let lower = line.lowercased()
        if lower.contains("useragent registered successfully") || lower.contains("useragents registered successfully") {
            hasRegisteredAccount = true
            if case .starting = state { state = .ready }
        } else if lower.contains("registration failed") || lower.contains("register failed") {
            state = .error("SIP registration failed")
        } else if lower.contains("incoming call") || lower.contains("call incoming") {
            let caller = callerName(from: line)
            state = .ringing(caller)
            showIncomingCallNotification(caller: caller)
        } else if lower.contains("call established") || lower.contains("answered") {
            state = .connected(state.peer)
            clearIncomingCallNotification()
            beginCallIntelligence()
        } else if lower.contains("call uri:") || lower.contains("connecting to") {
            state = .dialing(number)
            clearIncomingCallNotification()
        } else if lower.contains("security violation") {
            finishCall()
            state = .error("The provider rejected the audio encryption")
        } else if lower.contains("ua_connect failed") || lower.contains("call failed") {
            finishCall()
            state = .error("The call could not be established")
        } else if lower.contains("call closed") || lower.contains("session closed") || lower.contains("disconnected") {
            let missed = state.isRinging
            let caller = state.peer
            finishCall()
            state = hasRegisteredAccount ? .ready : .starting
            clearIncomingCallNotification()
            if missed { showMissedCallNotification(caller: caller) }
        } else if lower.contains("no accounts") {
            state = .error("No SIP account configured")
        }
    }

    private func callerName(from line: String) -> String? {
        guard let marker = line.range(of: "incoming call from:", options: .caseInsensitive) else { return nil }
        var value = line[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("sip:") { value.removeFirst(4) }
        guard let caller = value.split(separator: "@").first, !caller.isEmpty else { return nil }
        return String(caller).removingPercentEncoding ?? String(caller)
    }

    private func countAudioFrame(_ frame: AudioFrame) {
        guard intelligenceRunning else { return }
        audioFrameCounts[frame.speaker, default: 0] += 1
        let count = audioFrameCounts[frame.speaker] ?? 0
        if count == 1 || count % 1_000 == 0 {
            appendDiagnostic("phone-app: \(count) \(frame.speaker.title) audio frames received (\(Int(frame.sampleRate)) Hz)\n")
        }
    }

    private func beginCallIntelligence() {
        guard !intelligenceRunning else { return }
        clearConversation()
        intelligenceRunning = true
        callStartedAt = Date()
        audioFrameCounts = [:]
        intelligenceStatus = "Preparing local models …"
        Task {
            do {
                try await intelligence.start { [weak self] speaker, text, isFinal in
                    Task { @MainActor in self?.receiveTranscript(speaker: speaker, text: text, isFinal: isFinal) }
                } onError: { [weak self] speaker, message in
                    Task { @MainActor in
                        self?.appendDiagnostic("phone-app: \(speaker.title) lane error: \(message)\n")
                        self?.intelligenceStatus = message
                    }
                }
                await MainActor.run { self.intelligenceStatus = "Live · on this Mac only" }
            } catch {
                await MainActor.run {
                    self.intelligenceRunning = false
                    self.intelligenceStatus = error.localizedDescription
                }
            }
        }
    }

    private func receiveTranscript(speaker: Speaker, text: String, isFinal: Bool) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if let draftID = draftIDs[speaker], let index = transcript.firstIndex(where: { $0.id == draftID }) {
            transcript[index].text = cleaned
            transcript[index].isFinal = isFinal
            if isFinal { draftIDs[speaker] = nil }
        } else {
            let entry = TranscriptEntry(speaker: speaker, text: cleaned, isFinal: isFinal, createdAt: Date())
            transcript.append(entry)
            if !isFinal { draftIDs[speaker] = entry.id }
        }
    }

    private func finishCall() {
        guard intelligenceRunning else {
            callStartedAt = nil
            return
        }
        intelligenceRunning = false
        callStartedAt = nil
        intelligenceStatus = "Summarizing the call …"
        let entries = transcript
        Task {
            await intelligence.stop()
            do {
                let text = try await intelligence.summarize(entries: entries)
                await MainActor.run {
                    self.summary = CallSummary(text: text, createdAt: Date())
                    self.intelligenceStatus = "Processed locally"
                }
            } catch {
                await MainActor.run { self.intelligenceStatus = "Summary unavailable" }
            }
        }
    }

    private func installNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let answer = UNNotificationAction(identifier: "answer-call", title: "Answer", options: [.foreground])
        let reject = UNNotificationAction(identifier: "reject-call", title: "Decline", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "incoming-call", actions: [answer, reject], intentIdentifiers: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        completionHandler()
        Task { @MainActor in
            if actionIdentifier == "answer-call" { self.answer() }
            if actionIdentifier == "reject-call" { self.reject() }
        }
    }

    private func showIncomingCallNotification(caller: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Incoming call"
        content.body = caller.map { "Call from \($0)" } ?? "The phone is ringing."
        content.sound = .default
        content.categoryIdentifier = "incoming-call"
        clearIncomingCallNotification()
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "incoming-call", content: content, trigger: nil))
    }

    private func showMissedCallNotification(caller: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Missed call"
        content.body = caller.map { "Call from \($0)" } ?? "A call was not answered."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "missed-\(UUID())", content: content, trigger: nil))
    }

    private func clearIncomingCallNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["incoming-call"])
        center.removeDeliveredNotifications(withIdentifiers: ["incoming-call"])
    }
}
