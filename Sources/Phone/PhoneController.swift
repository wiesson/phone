import AppKit
import Combine
import Darwin
import Foundation
import UserNotifications

@MainActor
final class PhoneController: NSObject, ObservableObject, @preconcurrency UNUserNotificationCenterDelegate {
    let menuBar = MenuBarModel()

    @Published private(set) var state: CallState = .stopped {
        didSet { if menuBar.state != state { menuBar.state = state } }
    }
    @Published var number = ""
    @Published private(set) var transcript: [TranscriptEntry] = []
    @Published private(set) var summary: CallSummary?
    @Published private(set) var intelligenceStatus = "Local transcription ready"
    @Published private(set) var callStartedAt: Date? {
        didSet { if menuBar.callStartedAt != callStartedAt { menuBar.callStartedAt = callStartedAt } }
    }
    @Published private(set) var history: [CallRecord] = []
    @Published private(set) var isMuted = false

    private var process: Process?
    private var input: Pipe?
    private var lineBuffer = ""
    private let audioTap = AudioTapServer()
    private let intelligence = LocalIntelligence()
    private var draftIDs: [Speaker: UUID] = [:]
    private var intelligenceRunning = false
    private var currentDirection: CallDirection?
    private var contacts: [String: String] = [:]
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
        if let data = UserDefaults.standard.data(forKey: "callHistory"),
           let stored = try? JSONDecoder().decode([CallRecord].self, from: data) {
            history = stored
        }
        let intelligence = self.intelligence
        audioTap.onFrame = { frame in
            Task { await intelligence.append(frame) }
        }
    }

    func start() {
        loadContacts()
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
        currentDirection = .outgoing
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
        recordCall(missed: false)
        send("b")
        state = .ready
    }

    func hangup() {
        guard state.isInCall else { return }
        send("b")
        recordCall(missed: false)
        finishCall()
        state = .ready
    }

    /// Toggles the microphone for the active call (baresip single-key command).
    func toggleMute() {
        guard state.isConnected else { return }
        send("m")
        isMuted.toggle()
    }

    /// Sends a DTMF digit during an active call. baresip relays bare digit
    /// keys as DTMF while a call is established.
    func sendDTMF(_ digit: Character) {
        guard state.isConnected, "0123456789*#".contains(digit) else { return }
        send(String(digit))
    }

    /// Handles tel:, callto:, and sip: URLs from other applications.
    func handleDialURL(_ url: URL) {
        var target = url.absoluteString
        for scheme in ["tel:", "callto:", "sip:"] where target.lowercased().hasPrefix(scheme) {
            target.removeFirst(scheme.count)
        }
        target = target.removingPercentEncoding ?? target
        target = target.replacingOccurrences(of: "//", with: "")
        target.removeAll { $0.isWhitespace || $0 == "(" || $0 == ")" || $0 == "-" }
        guard !target.isEmpty else { return }
        number = target
        if state.isReady { dial() }
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
            currentDirection = .incoming
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
            recordCall(missed: false)
            finishCall()
            state = .error("The call could not be established")
        } else if lower.contains("call closed") || lower.contains("session closed") || lower.contains("disconnected") {
            let missed = state.isRinging
            let caller = state.peer
            recordCall(missed: missed)
            finishCall()
            state = hasRegisteredAccount ? .ready : .starting
            clearIncomingCallNotification()
            if missed { showMissedCallNotification(caller: caller) }
        } else if lower.contains("no accounts") {
            state = .error("No SIP account configured")
        }
    }

    /// Parses `runtime/baresip/contacts` lines of the form `"Name" <sip:user@domain>`
    /// into a user-part → display-name map.
    private func loadContacts() {
        contacts = [:]
        let url = projectRoot.appendingPathComponent("runtime/baresip/contacts")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"),
                  let nameStart = trimmed.firstIndex(of: "\""),
                  let nameEnd = trimmed[trimmed.index(after: nameStart)...].firstIndex(of: "\""),
                  let uriStart = trimmed.range(of: "<sip:"),
                  let uriEnd = trimmed[uriStart.upperBound...].firstIndex(of: ">") else { continue }
            let name = String(trimmed[trimmed.index(after: nameStart)..<nameEnd])
            let uri = trimmed[uriStart.upperBound..<uriEnd]
            guard let user = uri.split(separator: "@").first, !user.contains("*"), !name.isEmpty else { continue }
            contacts[String(user)] = name
        }
    }

    /// Returns a display name for a dial target or caller id, if known.
    func displayName(for peer: String?) -> String? {
        guard let peer else { return nil }
        var value = peer
        if value.lowercased().hasPrefix("sip:") { value.removeFirst(4) }
        let user = value.split(separator: "@").first.map(String.init) ?? value
        return contacts[user]
    }

    private func callerName(from line: String) -> String? {
        guard let marker = line.range(of: "incoming call from:", options: .caseInsensitive) else { return nil }
        var value = line[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("sip:") { value.removeFirst(4) }
        guard let caller = value.split(separator: "@").first, !caller.isEmpty else { return nil }
        let id = String(caller).removingPercentEncoding ?? String(caller)
        return contacts[id] ?? id
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: "callHistory")
    }

    private func recordCall(missed: Bool) {
        guard let direction = currentDirection else { return }
        currentDirection = nil
        let duration = callStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let record = CallRecord(
            direction: direction,
            peer: state.peer,
            date: Date(),
            duration: duration,
            missed: missed
        )
        history.insert(record, at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "callHistory")
        }
    }

    private var transcriptionEnabled: Bool {
        UserDefaults.standard.object(forKey: "transcriptionEnabled") as? Bool ?? true
    }

    private var retainTranscript: Bool {
        UserDefaults.standard.object(forKey: "retainTranscript") as? Bool ?? true
    }

    private func beginCallIntelligence() {
        guard !intelligenceRunning, callStartedAt == nil else { return }
        clearConversation()
        callStartedAt = Date()
        guard transcriptionEnabled else {
            intelligenceStatus = "Transcription is off"
            return
        }
        intelligenceRunning = true
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
            guard transcript[index].text != cleaned || transcript[index].isFinal != isFinal else { return }
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
        isMuted = false
        let counts = audioTap.drainFrameCounts()
        appendDiagnostic("phone-app: audio frames this call — me: \(counts[.me] ?? 0), caller: \(counts[.caller] ?? 0)\n")
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
                    if !self.retainTranscript { self.clearConversation() }
                }
            } catch {
                await MainActor.run {
                    self.intelligenceStatus = "Summary unavailable"
                    if !self.retainTranscript { self.clearConversation() }
                }
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
