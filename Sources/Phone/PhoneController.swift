import AppKit
import Combine
import Darwin
import Foundation
import PhoneAutomation
import UserNotifications

func normalizedDialTarget(from url: URL) -> String? {
    var target = url.absoluteString
    for scheme in ["tel:", "callto:", "sip:"] where target.lowercased().hasPrefix(scheme) {
        target.removeFirst(scheme.count)
    }
    target = target.removingPercentEncoding ?? target
    target = target.replacingOccurrences(of: "//", with: "")
    target.removeAll { $0.isWhitespace || $0 == "(" || $0 == ")" || $0 == "-" }
    return target.isEmpty ? nil : target
}

let phoneDiagnosticQueue = DispatchQueue(label: "phone.diagnostic-log")

func phoneDiagnosticLog(_ text: String) {
    phoneDiagnosticQueue.async {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phone/phone.log")
        guard let data = text.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        if (try? handle.seekToEnd()) != nil {
            try? handle.write(contentsOf: data)
        }
    }
}

func redactSensitiveValues(in text: String) -> String {
    text.replacingOccurrences(
        of: #"([?&]key=)[A-Za-z0-9._-]+"#,
        with: "$1••••",
        options: .regularExpression
    ).replacingOccurrences(
        of: #"auth_pass=(?:\"(?:[^\"\\]|\\.)*\"|[^;\s]*)"#,
        with: "auth_pass=••••",
        options: .regularExpression
    )
}

func parseContacts(_ content: String) -> [String: String] {
    var contacts: [String: String] = [:]
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
    return contacts
}

func parseCallerName(from line: String) -> String? {
    guard let marker = line.range(of: "incoming call from:", options: .caseInsensitive) else { return nil }
    var value = line[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    if value.lowercased().hasPrefix("sip:") { value.removeFirst(4) }
    guard let caller = value.split(separator: "@").first, !caller.isEmpty else { return nil }
    return String(caller).removingPercentEncoding ?? String(caller)
}

func parseAccountAOR(from content: String) -> String? {
    guard let line = content.split(separator: "\n").lazy
        .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        .first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
          let marker = line.range(of: "sip:", options: .caseInsensitive) else { return nil }
    let remainder = line[marker.upperBound...]
    let end = remainder.firstIndex {
        $0 == ">" || $0 == ";" || $0 == "\"" || $0.isWhitespace
    } ?? remainder.endIndex
    let address = String(remainder[..<end])
    let parts = address.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    return address.removingPercentEncoding ?? address
}

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
    @Published private(set) var managedAccounts: [ManagedSIPAccount] = []
    @Published private(set) var activeManagedSIPAddress: String?
    @Published private(set) var unmanagedAccountAOR: String?
    @Published private(set) var registrationStatus: RegistrationStatus = .idle
    @Published private(set) var geminiLiveState: GeminiLiveState = .off
    @Published private(set) var isGeminiConfigured = false
    @Published private(set) var isAutoAnswerArmed = false
    @Published private(set) var automationStatus: String?

    private var process: Process?
    private var input: Pipe?
    private var lineBuffer = ""
    private let audioTap = AudioTapServer()
    private let intelligence = LocalIntelligence()
    private let geminiLiveBridge = GeminiLiveBridge()
    private var geminiBridgeTask: Task<Void, Never>?
    private var autoAnswerTask: Task<Void, Never>?
    private var startsAssistantWhenConnected = false
    private var draftIDs: [Speaker: UUID] = [:]
    private var intelligenceRunning = false
    private var currentDirection: CallDirection?
    private var pendingDialRetry: String?
    private var contacts: [String: String] = [:]
    private var hasRegisteredAccount = false
    private var isShuttingDown = false
    private var hasActiveEventCall = false
    private var automationStatusTask: Task<Void, Never>?
    private let eventBus = PhoneEventBus()
    private let webhookTransport = PhoneWebhookTransport()
    private let controlServer = PhoneControlServer()

    private var diagnosticLogURL: URL {
        applicationSupportDirectory.appendingPathComponent("phone.log")
    }

    private var pidFileURL: URL {
        applicationSupportDirectory.appendingPathComponent("baresip.pid")
    }

    private var controlSocketURL: URL {
        applicationSupportDirectory.appendingPathComponent("control.sock")
    }

    var activeManagedAccount: ManagedSIPAccount? {
        managedAccounts.first { $0.sipAddress == activeManagedSIPAddress }
    }

    var accountDisplay: String? {
        activeManagedAccount?.registrationDisplay ?? unmanagedAccountAOR
    }

    var isGeminiLiveActive: Bool {
        geminiLiveState == .connecting || geminiLiveState == .live
    }

    var activityStatus: String {
        if let automationStatus { return automationStatus }
        if isAutoAnswerArmed { return "Assistant will answer" }
        return switch geminiLiveState {
        case .off: intelligenceStatus
        case .connecting: "Connecting to Gemini …"
        case .live: "Gemini live"
        case .failed(let message): message
        }
    }

    override init() {
        super.init()
        eventBus.subscribe { [weak self] event in
            self?.webhookTransport.deliver(event)
        }
        webhookTransport.onFailure = { [weak self] message in
            self?.showAutomationStatus(message)
        }
        controlServer.onCommand = { [weak self] command in
            await MainActor.run {
                guard let self else {
                    return .failure(ControlError(code: "unavailable", message: "Phone control is unavailable."))
                }
                return self.handleControlCommand(command)
            }
        }
        let defaults = UserDefaults.standard
        let result = decodeManagedSIPAccounts(
            accountsData: defaults.data(forKey: "managedSIPAccounts"),
            legacyAccountData: defaults.data(forKey: "managedSIPAccount"),
            activeSIPAddress: defaults.string(forKey: "activeManagedSIPAccount")
        )
        managedAccounts = result.state.accounts
        activeManagedSIPAddress = result.state.activeSIPAddress
        try? persistManagedAccounts()
        number = defaults.string(forKey: "lastDialedNumber") ?? ""
        if let data = defaults.data(forKey: "callHistory"),
           let stored = try? JSONDecoder().decode([CallRecord].self, from: data) {
            history = stored
        }
        isGeminiConfigured = GeminiAPIKeyStore.apiKey() != nil
        let intelligence = self.intelligence
        let geminiLiveBridge = self.geminiLiveBridge
        audioTap.onFrame = { frame in
            Task { await intelligence.append(frame) }
            Task { await geminiLiveBridge.append(frame) }
        }
    }

    func start() {
        do {
            try prepareRuntime()
            try controlServer.start(at: controlSocketURL.path)
        } catch {
            state = .error("Phone data could not be prepared")
            phoneDiagnosticLog("phone-app: startup preparation failed\n")
            return
        }
        loadUnmanagedAccountAOR()
        loadContacts()
        installNotifications()
        do {
            try audioTap.start()
        } catch {
            intelligenceStatus = "Audio bridge unavailable"
        }
        if managedAccounts.isEmpty && !FileManager.default.fileExists(atPath: configDirectory.appendingPathComponent("accounts").path) {
            state = .stopped
            requestAccountSetup()
        } else {
            startBaresip()
        }
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

    func requestAccountSetup() {
        menuBar.setupRequest &+= 1
    }

    func saveManagedAccountAndTest(_ account: ManagedSIPAccount, password: String) throws {
        guard !state.isInCall else { throw SIPAccountError.activeCall }
        try account.validate(password: password)
        try SIPPasswordStore.save(password, account: account.sipAddress)
        var state = ManagedSIPAccountsState(accounts: managedAccounts, activeSIPAddress: activeManagedSIPAddress)
        state.add(account)
        try saveManagedAccountsState(state)
        unmanagedAccountAOR = nil
        restartBaresipForRegistrationTest()
    }

    func selectManagedAccount(_ account: ManagedSIPAccount) throws {
        guard !state.isInCall else { throw SIPAccountError.activeCall }
        var accountsState = ManagedSIPAccountsState(accounts: managedAccounts, activeSIPAddress: activeManagedSIPAddress)
        guard accountsState.activeSIPAddress != account.sipAddress else { return }
        accountsState.select(account)
        guard accountsState.activeSIPAddress == account.sipAddress else { return }
        try saveManagedAccountsState(accountsState)
        restartBaresipForRegistrationTest()
    }

    func removeManagedAccount(_ account: ManagedSIPAccount) throws {
        guard !state.isInCall else { throw SIPAccountError.activeCall }
        guard managedAccounts.contains(where: { $0.sipAddress == account.sipAddress }) else { return }
        var accountsState = ManagedSIPAccountsState(accounts: managedAccounts, activeSIPAddress: activeManagedSIPAddress)
        let removedActiveAccount = accountsState.activeSIPAddress == account.sipAddress
        accountsState.remove(account)
        try SIPPasswordStore.remove(account: account.sipAddress)
        try saveManagedAccountsState(accountsState)
        if accountsState.accounts.isEmpty {
            stopBaresipAndWait()
            try? FileManager.default.removeItem(at: configDirectory.appendingPathComponent("accounts"))
            registrationStatus = .idle
            state = .stopped
            requestAccountSetup()
        } else if removedActiveAccount {
            restartBaresipForRegistrationTest()
        }
    }

    func recoverFromError() {
        state = process == nil ? .stopped : (hasRegisteredAccount ? .ready : .starting)
        if process == nil { startBaresip() }
    }

    func dial() {
        guard state.isReady else { return }
        guard let value = validatedDialTarget(number) else {
            state = .error("Please enter a valid number")
            return
        }
        number = value
        UserDefaults.standard.set(value, forKey: "lastDialedNumber")
        currentDirection = .outgoing
        hasActiveEventCall = true
        state = .dialing(value)
        eventBus.publish(.callOutgoing(target: value))
        send("/dial \(value)")
    }

    func answer() {
        cancelAutoAnswer()
        performAnswer()
    }

    private func performAnswer() {
        guard case .ringing(let caller) = state else { return }
        state = .answering(caller)
        clearIncomingCallNotification()
        send("/accept")
    }

    func reject() {
        guard state.isRinging else { return }
        cancelAutoAnswer()
        clearIncomingCallNotification()
        recordCall(missed: false)
        send("/hangup")
        finishCall(missed: false)
        state = .ready
    }

    func hangup() {
        guard state.isInCall else { return }
        send("/hangup")
        recordCall(missed: false)
        finishCall()
        state = .ready
    }

    /// Toggles the microphone for the active call (baresip single-key command).
    func toggleMute() {
        guard state.isConnected else { return }
        send("/mute")
        isMuted.toggle()
    }

    func saveGeminiAPIKey(_ key: String) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw GeminiLiveError.invalidAPIKey }
        try GeminiAPIKeyStore.save(value)
        isGeminiConfigured = true
    }

    func toggleGeminiLive() {
        guard state.isConnected else { return }
        if isGeminiLiveActive {
            stopGeminiLive()
            return
        }
        startGeminiLive(sendsInitialGreeting: false)
    }

    private func startGeminiLive(sendsInitialGreeting: Bool) {
        guard state.isConnected else { return }
        guard let apiKey = GeminiAPIKeyStore.apiKey() else {
            geminiLiveState = .failed(GeminiLiveError.invalidAPIKey.localizedDescription)
            isGeminiConfigured = false
            return
        }
        let defaults = UserDefaults.standard
        let storedModel = defaults.string(forKey: "geminiLiveModel")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = storedModel.flatMap { $0.isEmpty ? nil : $0 } ?? defaultGeminiLiveModel
        let instructions = (defaults.string(forKey: "assistantInstructions") ?? defaultAssistantInstructions)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bridge = geminiLiveBridge
        geminiLiveState = .connecting
        geminiBridgeTask?.cancel()
        geminiBridgeTask = Task {
            guard !Task.isCancelled else { return }
            await bridge.start(
                apiKey: apiKey,
                model: model,
                instructions: instructions,
                sendsInitialGreeting: sendsInitialGreeting
            ) { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.geminiLiveState = state
                    if case .failed(let message) = state {
                        self?.appendDiagnostic("phone-app: Gemini Live failed: \(message)\n")
                    }
                }
            }
            if Task.isCancelled { await bridge.stop() }
        }
    }

    /// Sends a DTMF digit during an active call via the menu module.
    func sendDTMF(_ digit: Character) {
        guard state.isConnected, "0123456789*#".contains(digit) else { return }
        send("/sndcode \(digit)")
        eventBus.publish(.callDTMF(digit: String(digit)))
    }

    /// Handles tel:, callto:, and sip: URLs from other applications.
    func handleDialURL(_ url: URL) {
        guard let target = normalizedDialTarget(from: url) else { return }
        number = target
        if state.isReady { dial() }
    }

    func clearConversation() {
        transcript = []
        summary = nil
        draftIDs = [:]
    }

    func copyConversation() {
        let body = transcript.map { "\($0.speakerTitle): \($0.text)" }.joined(separator: "\n")
        let result = [summary?.text, body].compactMap { $0 }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
    }

    func openRuntimeConfig() {
        try? prepareRuntime()
        NSWorkspace.shared.open(configDirectory)
    }

    func quit() {
        shutdown()
        NSApp.terminate(nil)
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        cancelAutoAnswer()
        clearIncomingCallNotification()
        stopGeminiLive()
        audioTap.stop()
        controlServer.stop()
        stopBaresipAndWait()
    }

    private var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phone", isDirectory: true)
    }

    private var configDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("baresip", isDirectory: true)
    }

    private var bundledBaresipDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("baresip", isDirectory: true)
    }

    private var bundledModulesDirectory: URL? {
        bundledBaresipDirectory?.appendingPathComponent("modules", isDirectory: true)
    }

    private var developmentRuntimeDirectory: URL? {
        let root = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        let config = runtime.appendingPathComponent("baresip/config")
        return FileManager.default.fileExists(atPath: config.path) ? runtime : nil
    }

    private func prepareRuntime() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        guard let bundledBaresipDirectory, let bundledModulesDirectory else {
            throw CocoaError(.fileNoSuchFile)
        }
        let developmentConfig = developmentRuntimeDirectory?.appendingPathComponent("baresip", isDirectory: true)

        try copyIfMissing(
            to: configDirectory.appendingPathComponent("config"),
            from: [developmentConfig?.appendingPathComponent("config"), bundledBaresipDirectory.appendingPathComponent("config")]
        )
        try copyIfMissing(
            to: configDirectory.appendingPathComponent("accounts.example"),
            from: [bundledBaresipDirectory.appendingPathComponent("accounts.example")]
        )
        try copyIfMissing(
            to: configDirectory.appendingPathComponent("contacts"),
            from: [developmentConfig?.appendingPathComponent("contacts"), bundledBaresipDirectory.appendingPathComponent("contacts")]
        )
        if let developmentAccount = developmentConfig?.appendingPathComponent("accounts"),
           fileManager.fileExists(atPath: developmentAccount.path) {
            try copyIfMissing(to: configDirectory.appendingPathComponent("accounts"), from: [developmentAccount])
        }
        try updateModulePath(bundledModulesDirectory)
    }

    private func copyIfMissing(to destination: URL, from candidates: [URL?]) throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        guard let source = candidates.compactMap({ $0 }).first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try fileManager.copyItem(at: source, to: destination)
    }

    private func updateModulePath(_ modulesDirectory: URL) throws {
        let url = configDirectory.appendingPathComponent("config")
        let content = try String(contentsOf: url, encoding: .utf8)
        var lines = content.components(separatedBy: "\n")
        var foundModulePath = false
        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("module_path") {
                lines[index] = "module_path\t\t\(modulesDirectory.path)"
                foundModulePath = true
            }
        }
        if !foundModulePath {
            lines.append("module_path\t\t\(modulesDirectory.path)")
        }
        let updated = lines.joined(separator: "\n")
        if updated != content {
            try updated.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private var baresipExecutable: String? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/baresip").path,
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
        do {
            try regenerateManagedAccountsFile()
        } catch {
            registrationStatus = .failed(error.localizedDescription)
            state = .error(error.localizedDescription)
            return
        }
        guard FileManager.default.fileExists(atPath: configDirectory.appendingPathComponent("accounts").path) else {
            registrationStatus = .failed("No SIP account configured")
            state = .error("No SIP account configured")
            requestAccountSetup()
            return
        }
        guard let executable = baresipExecutable else {
            registrationStatus = .failed("baresip was not found")
            state = .error("baresip was not found")
            return
        }
        guard FileManager.default.fileExists(atPath: configDirectory.appendingPathComponent("config").path) else {
            registrationStatus = .failed("baresip configuration is missing")
            state = .error("baresip configuration is missing")
            return
        }

        let accountsContent = (try? String(contentsOf: configDirectory.appendingPathComponent("accounts"), encoding: .utf8)) ?? ""
        let aor = parseAccountAOR(from: accountsContent) ?? "unknown"
        appendDiagnostic("phone-app: starting baresip — accounts file AOR: \(aor), UI active: \(activeManagedSIPAddress ?? "none")\n")

        let task = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.currentDirectoryURL = applicationSupportDirectory
        task.arguments = ["-f", configDirectory.path, "-c"]
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.consume(text) }
        }
        task.terminationHandler = { [weak self, weak task] _ in
            guard let task else { return }
            Task { @MainActor in self?.didStop(task) }
        }

        process = task
        input = stdin
        do {
            try task.run()
            try? String(task.processIdentifier).write(to: pidFileURL, atomically: true, encoding: .utf8)
            hasRegisteredAccount = false
            registrationStatus = .registering
            state = .starting
        } catch {
            process = nil
            input = nil
            registrationStatus = .failed("baresip could not be started")
            state = .error("baresip could not be started")
        }
    }

    private func regenerateManagedAccountsFile() throws {
        guard !managedAccounts.isEmpty else { return }
        guard let account = activeManagedAccount else { throw SIPAccountError.missingManagedAccount }
        let password = try SIPPasswordStore.password(account: account.sipAddress)
        let line = try account.accountLine(password: password)
        let url = configDirectory.appendingPathComponent("accounts")
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Data(line.utf8))
        try handle.synchronize()
        try handle.close()
    }

    private func persistManagedAccounts() throws {
        let state = ManagedSIPAccountsState(accounts: managedAccounts, activeSIPAddress: activeManagedSIPAddress)
        try saveManagedAccountsState(state)
    }

    private func saveManagedAccountsState(_ state: ManagedSIPAccountsState) throws {
        let defaults = UserDefaults.standard
        if state.accounts.isEmpty {
            defaults.removeObject(forKey: "managedSIPAccounts")
            defaults.removeObject(forKey: "activeManagedSIPAccount")
        } else {
            let data = try JSONEncoder().encode(state.accounts)
            defaults.set(data, forKey: "managedSIPAccounts")
            defaults.set(state.activeSIPAddress, forKey: "activeManagedSIPAccount")
        }
        defaults.removeObject(forKey: "managedSIPAccount")
        defaults.removeObject(forKey: "managedAccount")
        managedAccounts = state.accounts
        activeManagedSIPAddress = state.activeSIPAddress
    }

    private func restartBaresipForRegistrationTest() {
        stopBaresipAndWait()
        guard process == nil else {
            registrationStatus = .failed("baresip could not be restarted")
            return
        }
        startBaresip()
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
            let killedDeadline = Date().addingTimeInterval(0.75)
            while task.isRunning, Date() < killedDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }
        try? FileManager.default.removeItem(at: pidFileURL)
        if !task.isRunning { didStop(task) }
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
        guard command.contains("baresip"), command.contains(configDirectory.path) else {
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

    private func didStop(_ stoppedProcess: Process) {
        guard process === stoppedProcess else { return }
        process = nil
        input = nil
        try? FileManager.default.removeItem(at: pidFileURL)
        if hasActiveEventCall { finishCall() }
        hasRegisteredAccount = false
        if registrationStatus == .registering {
            registrationStatus = .failed("baresip stopped before registration completed")
        }
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
        appendDiagnostic(redactSensitiveValues(in: text))
        lineBuffer += text.replacingOccurrences(of: "\r", with: "\n")
        while let newline = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<newline])
            lineBuffer.removeSubrange(...newline)
            consumeLine(line)
        }
        if lineBuffer.count > 16_000 { lineBuffer.removeFirst(lineBuffer.count - 16_000) }
    }

    private func consumeLine(_ line: String) {
        guard let event = Self.parseCallEvent(line) else { return }
        switch event {
        case .registered:
            hasRegisteredAccount = true
            registrationStatus = .registered
            if case .starting = state { state = .ready }
            if UserDefaults.standard.bool(forKey: "sipTrace") { send("/siptrace") }
        case .registrationFailed(let failure):
            hasRegisteredAccount = false
            registrationStatus = .failed(failure)
            state = .error(failure)
        case .incoming:
            guard !state.isRinging else { return }
            let caller = callerName(from: line)
            currentDirection = .incoming
            hasActiveEventCall = true
            state = .ringing(caller)
            eventBus.publish(.callIncoming(peer: caller))
            showIncomingCallNotification(caller: caller)
            armAutoAnswerIfNeeded()
        case .established:
            guard !state.isConnected else { return }
            pendingDialRetry = nil
            let startsAssistant = startsAssistantWhenConnected
            cancelAutoAnswer(resetAssistant: false)
            startsAssistantWhenConnected = false
            state = .connected(state.peer)
            eventBus.publish(.callAnswered(peer: state.peer))
            clearIncomingCallNotification()
            beginCallIntelligence()
            if startsAssistant { startGeminiLive(sendsInitialGreeting: true) }
        case .dialing:
            state = .dialing(number)
            clearIncomingCallNotification()
        case .securityViolation:
            finishCall()
            state = .error("The provider rejected the audio encryption")
        case .failed:
            recordCall(missed: false)
            finishCall()
            state = .error("The call could not be established")
        case .closed(let reason):
            if state.isInCall, !state.isConnected, let reason, !reason.isEmpty {
                if case .dialing(let target) = state, reason.hasPrefix("403"), pendingDialRetry == nil {
                    pendingDialRetry = target
                    finishCall()
                    state = .ready
                    appendDiagnostic("phone-app: 403 on first INVITE, retrying dial once\n")
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(1.5))
                        guard let self, self.pendingDialRetry == target, self.state.isReady else { return }
                        self.number = target
                        self.dial()
                    }
                    return
                }
                pendingDialRetry = nil
                recordCall(missed: false)
                finishCall()
                state = .error("Call rejected: \(reason)")
                clearIncomingCallNotification()
                return
            }
            pendingDialRetry = nil
            let missed = state.isRinging
            let caller = state.peer
            recordCall(missed: missed)
            finishCall(missed: missed)
            state = hasRegisteredAccount ? .ready : .starting
            clearIncomingCallNotification()
            if missed { showMissedCallNotification(caller: caller) }
        case .noAccounts(let failure):
            hasRegisteredAccount = false
            registrationStatus = .failed(failure.isEmpty ? "No SIP account configured" : failure)
            state = .error("No SIP account configured")
        }
    }

    enum CallEvent: Equatable {
        case registered
        case registrationFailed(String)
        case incoming
        case established
        case dialing
        case securityViolation
        case failed
        case closed(String?)
        case noAccounts(String)
    }

    /// Pure classification of a baresip output line. Help/menu chatter
    /// (lines starting with "/") must never be treated as call events.
    nonisolated static func parseCallEvent(_ line: String) -> CallEvent? {
        let lower = line.lowercased()
        if lower.trimmingCharacters(in: .whitespaces).hasPrefix("/") { return nil }
        if lower.contains("useragent registered successfully") || lower.contains("useragents registered successfully") {
            return .registered
        }
        if lower.contains("registration failed") || lower.contains("register failed") {
            return .registrationFailed(redactSensitiveValues(in: line).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if lower.contains("incoming call from") { return .incoming }
        if lower.contains("call established") || lower.contains("answered") { return .established }
        if lower.contains("call uri:") || lower.contains("connecting to") { return .dialing }
        if lower.contains("security violation") { return .securityViolation }
        if lower.contains("ua_connect failed") || lower.contains("call failed") { return .failed }
        if lower.contains("call closed") || lower.contains("session closed") || lower.contains("disconnected") {
            let reason = line.range(of: "closed:").map { String(line[$0.upperBound...]).trimmingCharacters(in: .whitespaces) }
            let isRejection = reason.map { $0.range(of: #"^[45][0-9][0-9] "#, options: .regularExpression) != nil } ?? false
            return .closed(isRejection ? reason : nil)
        }
        if lower.contains("no accounts") {
            return .noAccounts(redactSensitiveValues(in: line).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// Parses baresip contacts lines of the form `"Name" <sip:user@domain>`
    /// into a user-part → display-name map.
    private func loadContacts() {
        let url = configDirectory.appendingPathComponent("contacts")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            contacts = [:]
            return
        }
        contacts = parseContacts(content)
    }

    private func loadUnmanagedAccountAOR() {
        guard managedAccounts.isEmpty else {
            unmanagedAccountAOR = nil
            return
        }
        let url = configDirectory.appendingPathComponent("accounts")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            unmanagedAccountAOR = nil
            return
        }
        unmanagedAccountAOR = parseAccountAOR(from: content)
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
        guard let id = parseCallerName(from: line) else { return nil }
        return contacts[id] ?? id
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: "callHistory")
    }

    private func showAutomationStatus(_ message: String) {
        automationStatusTask?.cancel()
        automationStatus = message
        automationStatusTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            self?.automationStatus = nil
            self?.automationStatusTask = nil
        }
    }

    private func handleControlCommand(_ command: ControlCommand) -> ControlResponse {
        guard hasRegisteredAccount else {
            return .failure(ControlError(code: "not_registered", message: "Phone is not registered with a SIP provider."))
        }
        switch command {
        case .dial(let target):
            guard state.isReady else {
                return .failure(ControlError(code: "invalid_state", message: "Phone is not ready to dial."))
            }
            number = target
            dial()
            return .success(.object(["state": .string("dialing"), "target": .string(target)]))
        case .answer:
            guard state.isRinging else {
                return .failure(ControlError(code: "invalid_state", message: "There is no incoming call to answer."))
            }
            answer()
            return .success(.object(["state": .string("answering")]))
        case .hangup:
            guard state.isInCall else {
                return .failure(ControlError(code: "invalid_state", message: "There is no active call to hang up."))
            }
            hangup()
            return .success(.object(["state": .string("ready")]))
        case .sendDTMF(let digit):
            guard state.isConnected, let character = digit.first else {
                return .failure(ControlError(code: "invalid_state", message: "DTMF requires a connected call."))
            }
            sendDTMF(character)
            return .success(.object(["digit": .string(digit)]))
        case .getState:
            return .success(.object([
                "state": .string(controlStateName),
                "peer": state.peer.map(JSONValue.string) ?? .null,
                "registered": .bool(hasRegisteredAccount),
                "muted": .bool(isMuted)
            ]))
        case .getHistory(let limit):
            let formatter = ISO8601DateFormatter()
            let records = history.prefix(limit).map { record in
                JSONValue.object([
                    "id": .string(record.id.uuidString),
                    "direction": .string(record.direction.rawValue),
                    "peer": record.peer.map(JSONValue.string) ?? .null,
                    "timestamp": .string(formatter.string(from: record.date)),
                    "duration": .double(record.duration),
                    "missed": .bool(record.missed)
                ])
            }
            return .success(.array(records))
        case .getLastSummary:
            guard let summary else { return .success(.null) }
            return .success(.object([
                "text": .string(summary.text),
                "timestamp": .string(ISO8601DateFormatter().string(from: summary.createdAt))
            ]))
        }
    }

    private var controlStateName: String {
        switch state {
        case .stopped: "stopped"
        case .starting: "starting"
        case .ready: "ready"
        case .ringing: "ringing"
        case .dialing: "dialing"
        case .answering: "answering"
        case .connected: "connected"
        case .error: "error"
        }
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

    private var assistantAnswersIncomingCalls: Bool {
        UserDefaults.standard.object(forKey: "assistantAnswersIncomingCalls") as? Bool ?? false
    }

    private var assistantAnswerDelay: Int {
        let stored = UserDefaults.standard.object(forKey: "assistantAnswerDelay") as? Int ?? 5
        return min(max(stored, 0), 30)
    }

    private func armAutoAnswerIfNeeded() {
        cancelAutoAnswer()
        guard assistantAnswersIncomingCalls, isGeminiConfigured else { return }
        isAutoAnswerArmed = true
        let delay = assistantAnswerDelay
        autoAnswerTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            self.autoAnswerTask = nil
            guard self.state.isRinging else {
                self.isAutoAnswerArmed = false
                return
            }
            self.isAutoAnswerArmed = false
            self.startsAssistantWhenConnected = true
            self.performAnswer()
        }
    }

    private func cancelAutoAnswer(resetAssistant: Bool = true) {
        autoAnswerTask?.cancel()
        autoAnswerTask = nil
        isAutoAnswerArmed = false
        if resetAssistant { startsAssistantWhenConnected = false }
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
                await MainActor.run { self.appendDiagnostic("phone-app: transcription lanes started\n") }
                await MainActor.run { self.intelligenceStatus = "Live · on this Mac only" }
            } catch {
                await MainActor.run {
                    self.intelligenceRunning = false
                    self.intelligenceStatus = error.localizedDescription
                    self.appendDiagnostic("phone-app: transcription start failed: \(error)\n")
                }
            }
        }
    }

    private func receiveTranscript(speaker: Speaker, text: String, isFinal: Bool) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let isAssistant = speaker == .me && geminiLiveState == .live
        var didFinalize = false
        if transcript.isEmpty { appendDiagnostic("phone-app: first transcript result received\n") }
        if let draftID = draftIDs[speaker], let index = transcript.firstIndex(where: { $0.id == draftID }) {
            guard transcript[index].text != cleaned ||
                    transcript[index].isFinal != isFinal ||
                    (isAssistant && !transcript[index].isAssistant) else { return }
            transcript[index].text = cleaned
            transcript[index].isFinal = isFinal
            if isAssistant { transcript[index].isAssistant = true }
            if isFinal {
                draftIDs[speaker] = nil
                didFinalize = true
            }
        } else {
            let entry = TranscriptEntry(
                speaker: speaker,
                text: cleaned,
                isFinal: isFinal,
                isAssistant: isAssistant,
                createdAt: Date()
            )
            transcript.append(entry)
            if !isFinal { draftIDs[speaker] = entry.id }
            didFinalize = isFinal
        }
        if didFinalize {
            let label = isAssistant ? "Assistant" : speaker.title
            eventBus.publish(.transcriptFinal(speaker: label, text: cleaned))
        }
    }

    private func finishCall(missed: Bool = false) {
        cancelAutoAnswer()
        stopGeminiLive()
        isMuted = false
        let peer = state.peer
        let duration = callStartedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        if hasActiveEventCall {
            hasActiveEventCall = false
            eventBus.publish(.callHungup(peer: peer, duration: duration, missed: missed))
        }
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
                    self.eventBus.publish(.callSummary(text: text))
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

    private func stopGeminiLive() {
        guard geminiLiveState != .off else { return }
        geminiLiveState = .off
        geminiBridgeTask?.cancel()
        let bridge = geminiLiveBridge
        geminiBridgeTask = Task { await bridge.stop() }
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
