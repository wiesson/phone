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

func assistantCallInstructions(general: String, task: String, userDisplayName: String = "") -> String {
    let general = general.trimmingCharacters(in: .whitespacesAndNewlines)
    let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
    let taskSection = task.isEmpty ? "" : "Auftrag für diesen Anruf:\n\(task)"
    guard !taskSection.isEmpty else { return general }
    let displayName = userDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let handoverPhrase = displayName.isEmpty
        ? "Ich verbinde Sie jetzt."
        : "Ich verbinde Sie mit \(displayName)."
    let callControl = """
    Anrufsteuerung:
    DU rufst an. Sprich NICHT zuerst: Warte still, bis sich die Gegenseite gemeldet hat (z. B. „Pizzeria Luigi, hallo?“). Erst dann begrüßt du kurz und nennst dein Anliegen. Meldet sich länger niemand, obwohl der Anruf angenommen wurde, sage nach etwa fünf Sekunden ein einzelnes freundliches „Hallo?“.
    Du kannst auf automatische Telefonmenüs (IVR) und Warteschleifen treffen. Höre aufmerksam zu, wähle die passende Menüoption und rufe send_dtmf mit genau der benötigten Taste auf. Bleibe in Warteschleifen geduldig und warte weiter.
    Sobald ein echter Mensch antwortet, trage das Anliegen kurz vor. Sage danach exakt „\(handoverPhrase)“ und rufe unmittelbar handover_to_user auf.
    """
    return [general, taskSection, callControl].filter { !$0.isEmpty }.joined(separator: "\n\n")
}

func filteringAudioStatistics(from text: String) -> String {
    var result = ""
    var segmentStart = text.startIndex
    var index = text.startIndex

    func isAudioStatistics(_ segment: Substring) -> Bool {
        segment.range(
            of: #"^\s*\[[0-9]+:[0-9]{2}:[0-9]{2}\]\s+audio=.*\(bit/s\)\s*$"#,
            options: .regularExpression
        ) != nil
    }

    while index < text.endIndex {
        guard text[index] == "\r" || text[index] == "\n" else {
            index = text.index(after: index)
            continue
        }
        let segment = text[segmentStart..<index]
        var separatorEnd = text.index(after: index)
        if text[index] == "\r", separatorEnd < text.endIndex, text[separatorEnd] == "\n" {
            separatorEnd = text.index(after: separatorEnd)
        }
        if !isAudioStatistics(segment) {
            result += segment
            result += text[index..<separatorEnd]
        }
        segmentStart = separatorEnd
        index = separatorEnd
    }

    let trailingSegment = text[segmentStart...]
    if !isAudioStatistics(trailingSegment) { result += trailingSegment }
    return result
}

func configEnsuringPreferredAudioCodecModules(_ content: String, modules: [String]) -> String {
    var lines = content.components(separatedBy: "\n")
    let preferredModules = ["opus.so", "g722.so"].filter(modules.contains)
    var preferredLines: [String] = []

    for module in preferredModules {
        let indexes = lines.indices.filter { index in
            let fields = lines[index].split(whereSeparator: { $0.isWhitespace })
            return fields.count >= 2 && fields[0] == "module" && fields[1] == Substring(module)
        }
        preferredLines.append(indexes.first.map { lines[$0] } ?? "module\t\t\t\(module)")
        for index in indexes.reversed() {
            lines.remove(at: index)
        }
    }

    let g711Index = lines.firstIndex { line in
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        return fields.count >= 2 && fields[0] == "module" && fields[1] == "g711.so"
    } ?? lines.endIndex
    lines.insert(contentsOf: preferredLines, at: g711Index)
    return lines.joined(separator: "\n")
}

struct AssistantCallPlan {
    private(set) var task: String?
    private(set) var isActive = false

    var isPending: Bool { task != nil }

    mutating func begin(task: String) {
        self.task = task
        isActive = true
    }

    mutating func established() -> String? {
        let pendingTask = task
        task = nil
        return pendingTask
    }

    mutating func callFailed() {
        task = nil
        isActive = false
    }
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

func redactSensitiveValues(in text: String, secrets: [String] = []) -> String {
    var result = redactKnownPatterns(in: text)
    // A provider can reflect the password back in its own error text, where no
    // pattern matches it. The log is the one place that keeps it forever.
    for secret in secrets where secret.count >= 4 {
        result = result.replacingOccurrences(of: secret, with: "••••")
    }
    return result
}

private func redactKnownPatterns(in text: String) -> String {
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

func parseIncomingCalledAOR(from line: String) -> String? {
    guard let incoming = line.range(of: "incoming call from:", options: .caseInsensitive),
          let sip = line[..<incoming.lowerBound].range(of: "sip:", options: .caseInsensitive) else { return nil }
    let remainder = line[sip.upperBound..<incoming.lowerBound]
    let end = remainder.firstIndex {
        $0 == ":" || $0 == ";" || $0 == ">" || $0.isWhitespace
    } ?? remainder.endIndex
    let address = String(remainder[..<end])
    let decoded = address.removingPercentEncoding ?? address
    let parts = decoded.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    return decoded
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
    let store: PhoneStore

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
    private var mutedByBridge = false
    @Published private(set) var managedAccounts: [ManagedSIPAccount] = []
    @Published private(set) var savedAssistantProfiles: [SavedAssistantProfile] = []
    @Published private(set) var activeManagedSIPAddress: String?
    @Published private(set) var unmanagedAccountAOR: String?
    @Published private(set) var currentCallAccountAOR: String?
    @Published private(set) var registrationStatus: RegistrationStatus = .idle
    @Published private(set) var geminiLiveState: GeminiLiveState = .off
    @Published private(set) var isGeminiConfigured = false
    @Published private(set) var isAutoAnswerArmed = false
    @Published private(set) var isAssistantCallActive = false
    @Published private(set) var automationStatus: String?

    private var instances: [String: BaresipInstance] = [:]
    private var lineBuffers: [String: String] = [:]
    private var registrationStatuses: [String: RegistrationStatus] = [:]
    private var currentCallInstanceID: String?
    private var deferredIncomingCalls: [String: DeferredIncomingCall] = [:]
    private let intelligence = LocalIntelligence()
    private let geminiLiveBridge = GeminiLiveBridge()
    private var geminiBridgeTask: Task<Void, Never>?
    /// Counts bridge sessions started from here. A callback that belongs to
    /// an earlier session — one already stopped or replaced — must not touch
    /// the state of the one that followed it.
    private var bridgeGeneration = 0
    private var geminiTranscriptionActive = false
    /// Counts calls whose transcription was started. A teardown that outlives
    /// its call must not stop the next call's lanes or archive its words.
    private var callGeneration = 0
    private var autoAnswerTask: Task<Void, Never>?
    private var startsAssistantWhenConnected = false
    private var incomingCallAttentionRequest: Int?
    private var dialedTarget: String?
    private var linesChangingEnablement: Set<String> = []
    private var assistantCallPlan = AssistantCallPlan()
    private var draftIDs: [Speaker: UUID] = [:]
    private var intelligenceRunning = false
    private var currentDirection: CallDirection?
    private var currentCallStartedAt: Date?
    private var pendingArchiveRecord: CallRecord?
    private var pendingDialRetry: String?
    private var contacts: [String: String] = [:]
    private let contactsDirectory = ContactsDirectory()
    private var contactsDirectoryCancellables: Set<AnyCancellable> = []
    private var instancesWithSIPTrace: Set<String> = []
    private var isStoppingInstances = false
    private var isShuttingDown = false
    /// baresip answers a REGISTER with a success or a failure line — but a
    /// registrar that never answers (wrong port, firewall, DNS black hole)
    /// produces neither, and the line would sit on "Registering …" for as
    /// long as the app runs. The control socket already caps its wait; the
    /// interface needs the same cap, written back to the line so the wizard
    /// and the line list show a failure that can be retried.
    private let registrationTimeout: Duration = .seconds(30)
    private var registrationWatchdogs: [String: Task<Void, Never>] = [:]
    private var hasActiveEventCall = false
    private var automationStatusTask: Task<Void, Never>?
    private let eventBus = PhoneEventBus()
    private let webhookTransport = PhoneWebhookTransport()
    private let controlServer = PhoneControlServer()

    private struct DeferredIncomingCall {
        let caller: String?
        let accountAOR: String?
        let startedAt: Date
    }

    private var diagnosticLogURL: URL {
        applicationSupportDirectory.appendingPathComponent("phone.log")
    }

    private var pidFileURL: URL {
        applicationSupportDirectory.appendingPathComponent("baresip.pid")
    }

    private var controlSocketURL: URL {
        PhoneControlSocket.url()
    }

    var activeManagedAccount: ManagedSIPAccount? {
        managedAccounts.first { $0.sipAddress == activeManagedSIPAddress }
    }

    private var activeInstanceID: String? {
        if let address = activeManagedSIPAddress { return sanitizedBaresipInstanceAOR(address) }
        return managedAccounts.isEmpty ? "unmanaged" : nil
    }

    private var activeInstance: BaresipInstance? {
        activeInstanceID.flatMap { instances[$0] }
    }

    private var commandInstance: BaresipInstance? {
        currentCallInstanceID.flatMap { instances[$0] } ?? activeInstance
    }

    private var hasRegisteredAccount: Bool {
        guard let activeInstanceID else { return false }
        return registrationStatuses[activeInstanceID] == .registered
    }

    var registrationSummary: String? {
        guard !managedAccounts.isEmpty else { return nil }
        return aggregateRegistrationState(Array(registrationStatuses.values), total: enabledManagedAccounts.count).summary
    }

    var enabledManagedAccounts: [ManagedSIPAccount] {
        managedAccounts.filter(\.isEnabled)
    }

    func isOnCurrentCall(_ account: ManagedSIPAccount) -> Bool {
        currentCallInstanceID == sanitizedBaresipInstanceAOR(account.sipAddress)
    }

    func registrationStatus(for account: ManagedSIPAccount) -> RegistrationStatus {
        registrationStatuses[sanitizedBaresipInstanceAOR(account.sipAddress)] ?? .idle
    }

    var accountDisplay: String? {
        activeManagedAccount?.registrationDisplay ?? unmanagedAccountAOR
    }

    var currentCallAccountDisplay: String? {
        guard let currentCallAccountAOR else { return nil }
        let account = managedAccounts.first {
            normalizedSIPAOR($0.sipAddress) == normalizedSIPAOR(currentCallAccountAOR)
        }
        let number = account?.username ?? currentCallAccountAOR.split(separator: "@").first.map(String.init) ?? currentCallAccountAOR
        let label = account?.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? number : "\(number) · \(label)"
    }

    var isGeminiLiveActive: Bool {
        geminiLiveState == .connecting || geminiLiveState == .live
    }

    var activityStatus: String {
        if isAssistantCallActive { return "Assistant call" }
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
        migrateAssistantAnswerMode(defaults: UserDefaults.standard)
        store = (try? PhoneStore()) ?? (try! PhoneStore(path: ":memory:"))
        super.init()
        rotateDiagnosticLogIfNeeded()
        contactsDirectory.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &contactsDirectoryCancellables)
        contactsDirectory.$entries
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.state.isRinging else { return }
                    self.showIncomingCallNotification(caller: self.state.peer)
                }
            }
            .store(in: &contactsDirectoryCancellables)
        eventBus.subscribe { [weak self] event in
            self?.webhookTransport.deliver(event)
        }
        webhookTransport.onFailure = { [weak self] message in
            self?.showAutomationStatus(message)
        }
        controlServer.onCommand = { [weak self] command in
            guard let self else {
                return .failure(ControlError(code: "unavailable", message: "Phone control is unavailable."))
            }
            return await self.handleControlCommand(command)
        }
        let defaults = UserDefaults.standard
        if let file = Self.loadAccountsFile(from: accountsFileURL) {
            let state = ManagedSIPAccountsState(
                accounts: file.accounts,
                activeSIPAddress: file.activeSIPAddress
            )
            managedAccounts = state.accounts
            activeManagedSIPAddress = state.activeSIPAddress
            savedAssistantProfiles = file.savedProfiles ?? []
        } else {
            // Migration path: accept Data or (from external edits) String defaults.
            let storedAccounts = defaults.data(forKey: "managedSIPAccounts")
                ?? (defaults.string(forKey: "managedSIPAccounts")?.data(using: .utf8))
            let result = decodeManagedSIPAccounts(
                accountsData: storedAccounts,
                legacyAccountData: defaults.data(forKey: "managedSIPAccount"),
                activeSIPAddress: defaults.string(forKey: "activeManagedSIPAccount")
            )
            let migrated = migrateSavedAssistantProfiles(
                in: ManagedAccountsFile(
                    accounts: result.state.accounts,
                    activeSIPAddress: result.state.activeSIPAddress
                )
            )
            managedAccounts = migrated.accounts
            activeManagedSIPAddress = migrated.activeSIPAddress
            savedAssistantProfiles = migrated.savedProfiles ?? []
        }
        let needsAnsweringMigration = !defaults.bool(forKey: assistantAnsweringMigrationDefaultsKey)
        if needsAnsweringMigration {
            managedAccounts = accountsAdoptingGlobalAnswering(
                managedAccounts,
                mode: storedAssistantAnswerMode(defaults: defaults),
                delay: defaults.object(forKey: "assistantAnswerDelay") as? Int ?? 5,
                businessHours: storedBusinessHoursSchedule(defaults: defaults)
            )
        }
        do {
            try persistManagedAccounts()
            // Only claim the migration once the values are safely on disk.
            if needsAnsweringMigration { defaults.set(true, forKey: assistantAnsweringMigrationDefaultsKey) }
        } catch {
            phoneDiagnosticLog("phone-app: accounts could not be persisted at startup\n")
        }
        number = defaults.string(forKey: "lastDialedNumber") ?? ""
        if let data = defaults.data(forKey: "callHistory"),
           let stored = try? JSONDecoder().decode([CallRecord].self, from: data) {
            history = stored
        }
        refreshAssistantConfiguration()
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
        Task { [weak self] in
            guard let self else { return }
            do {
                let count = try await CallHistoryMigration.migrate(
                    defaults: .standard,
                    store: self.store,
                    displayName: self.existingDisplayName(for:)
                )
                if count > 0 { NotificationCenter.default.post(name: .phoneArchiveChanged, object: nil) }
            } catch { }
        }
        installNotifications()
        if managedAccounts.isEmpty && !FileManager.default.fileExists(atPath: configDirectory.appendingPathComponent("accounts").path) {
            state = .stopped
            // A phone with no lines opens the main window, not the wizard: the
            // empty state offers the setup command and keeps the wizard one
            // click away, rather than deciding for the user which way to go.
            requestLibraryWindow()
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

    /// "Start phone" starts whatever is not running; it must never take live
    /// lines down because one engine died.
    func toggleBaresip() {
        hasStoppedLine ? startBaresip() : stopBaresip()
    }

    private var hasStoppedLine: Bool {
        if managedAccounts.isEmpty { return instances["unmanaged"]?.isRunning != true }
        return enabledManagedAccounts.contains {
            instances[sanitizedBaresipInstanceAOR($0.sipAddress)]?.isRunning != true
        }
    }

    func requestAccountSetup() {
        menuBar.setupRequest &+= 1
    }

    func requestLibraryWindow() {
        menuBar.libraryRequest &+= 1
    }

    func saveManagedAccountAndTest(_ account: ManagedSIPAccount, password: String) throws {
        guard currentCallInstanceID == nil else { throw SIPAccountError.activeCall }
        try account.validate(password: password)
        guard !managedAccounts.contains(where: { $0.sipAddress == account.sipAddress }) else {
            throw SIPAccountError.duplicateAccount
        }
        let hadStoredPassword = (try? SIPPasswordStore.password(account: account.sipAddress)) != nil
        try SIPPasswordStore.save(password, account: account.sipAddress)
        invalidateAccountSecretCache()
        var state = ManagedSIPAccountsState(accounts: managedAccounts, activeSIPAddress: activeManagedSIPAddress)
        state.add(account)
        do {
            try saveManagedAccountsState(state)
        } catch {
            // Persisting failed, so the secret belongs to nothing. Leaving it
            // behind would keep a password for a line that does not exist.
            if !hadStoredPassword { try? SIPPasswordStore.remove(account: account.sipAddress) }
            invalidateAccountSecretCache()
            throw error
        }
        unmanagedAccountAOR = nil
        restartManagedInstance(for: account)
    }

    /// Re-registers one line. A full restart would re-register every line and
    /// trips provider-side rate limiting, so the retry from the wizard
    /// touches only the line being tested.
    func restartManagedAccountRegistrationTest(for account: ManagedSIPAccount) throws {
        guard currentCallInstanceID == nil else { throw SIPAccountError.activeCall }
        guard managedAccounts.contains(where: { $0.sipAddress == account.sipAddress }) else {
            throw SIPAccountError.missingManagedAccount
        }
        let instanceID = sanitizedBaresipInstanceAOR(account.sipAddress)
        guard !linesChangingEnablement.contains(instanceID) else { throw SIPAccountError.lineBusy }
        linesChangingEnablement.insert(instanceID)
        defer { linesChangingEnablement.remove(instanceID) }
        restartManagedInstance(for: account)
    }

    @discardableResult
    func editManagedAccount(
        _ account: ManagedSIPAccount,
        replacing originalSIPAddress: String,
        password replacementPassword: String
    ) throws -> ManagedSIPAccountEditPlan {
        guard let original = managedAccounts.first(where: { $0.sipAddress == originalSIPAddress }) else {
            throw SIPAccountError.missingManagedAccount
        }
        let plan = managedSIPAccountEditPlan(
            original: original,
            updated: account,
            replacementPassword: replacementPassword
        )
        var state = ManagedSIPAccountsState(accounts: managedAccounts, activeSIPAddress: activeManagedSIPAddress)
        try state.replace(accountAt: originalSIPAddress, with: account)

        guard plan.requiresEngineRestart else {
            try saveManagedAccountsState(state)
            return plan
        }

        guard currentCallInstanceID == nil else { throw SIPAccountError.activeCall }
        let storedPassword = replacementPassword.isEmpty
            ? try SIPPasswordStore.password(account: originalSIPAddress)
            : nil
        let passwordEdit = try managedSIPPasswordEdit(
            originalSIPAddress: originalSIPAddress,
            updatedSIPAddress: account.sipAddress,
            replacementPassword: replacementPassword,
            storedPassword: storedPassword
        )
        let effectivePassword = replacementPassword.isEmpty ? storedPassword ?? "" : replacementPassword
        try account.validate(password: effectivePassword)

        switch passwordEdit {
        case .keep:
            break
        case .save(let password, let address):
            try SIPPasswordStore.save(password, account: address)
        case .move(let password, _, let newAddress):
            try SIPPasswordStore.save(password, account: newAddress)
        }
        try saveManagedAccountsState(state)
        if case .move(_, let oldAddress, _) = passwordEdit {
            try SIPPasswordStore.remove(account: oldAddress)
        }
        unmanagedAccountAOR = nil
        restartManagedInstance(
            for: account,
            removingInstanceFor: originalSIPAddress == account.sipAddress ? nil : originalSIPAddress
        )
        return plan
    }

    func selectManagedAccount(_ account: ManagedSIPAccount) throws {
        guard currentCallInstanceID == nil else { throw SIPAccountError.activeCall }
        guard account.isEnabled else { throw SIPAccountError.accountOffline }
        var accountsState = ManagedSIPAccountsState(accounts: managedAccounts, activeSIPAddress: activeManagedSIPAddress)
        guard accountsState.activeSIPAddress != account.sipAddress else { return }
        accountsState.select(account)
        guard accountsState.activeSIPAddress == account.sipAddress else { return }
        try saveManagedAccountsState(accountsState)
        refreshIdleState()
    }

    func updateManagedAccountMetadata(_ account: ManagedSIPAccount) throws {
        guard var updated = managedAccounts.first(where: { $0.sipAddress == account.sipAddress }) else {
            throw SIPAccountError.missingManagedAccount
        }
        updated.label = account.label
        updated.assistantProfile = account.assistantProfile
        updated.assistantProfileName = account.assistantProfileName
        updated.savedProfileID = account.savedProfileID
        updated.assistantInstructionsOverride = account.assistantInstructionsOverride
        updated.assistantContextData = account.assistantContextData
        updated.assistantAnswerMode = account.assistantAnswerMode
        updated.assistantAnswerDelay = ManagedSIPAccount.clampedAnswerDelay(account.assistantAnswerDelay)
        updated.businessHours = account.businessHours
        var accountsState = ManagedSIPAccountsState(accounts: managedAccounts, activeSIPAddress: activeManagedSIPAddress)
        accountsState.update(updated)
        try saveManagedAccountsState(accountsState)
    }

    func savedAssistantProfile(id: UUID?) -> SavedAssistantProfile? {
        guard let id else { return nil }
        return savedAssistantProfiles.first { $0.id == id }
    }

    func assistantProfileDisplay(for account: ManagedSIPAccount) -> String {
        account.assistantProfileDisplay(savedProfiles: savedAssistantProfiles)
    }

    func updateSavedAssistantProfile(
        id: UUID,
        change: (inout SavedAssistantProfile) -> Void
    ) throws {
        guard let index = savedAssistantProfiles.firstIndex(where: { $0.id == id }) else {
            throw SIPAccountError.missingSavedAssistantProfile
        }
        var profiles = savedAssistantProfiles
        change(&profiles[index])
        let state = ManagedSIPAccountsState(
            accounts: managedAccounts,
            activeSIPAddress: activeManagedSIPAddress
        )
        try saveManagedAccountsState(state, savedProfiles: profiles)
    }

    /// Creates the named profile, or brings the existing one under that name up
    /// to the given prompt. An agent that repeats the call — after a dropped
    /// answer, or simply on a second run of the same setup — must not end up
    /// with two profiles sharing a name.
    @discardableResult
    func createSavedAssistantProfile(
        name: String,
        instructions: String,
        contextData: String?
    ) throws -> SavedAssistantProfile {
        let result = upsertSavedAssistantProfile(
            named: name,
            instructions: instructions,
            contextData: contextData,
            in: savedAssistantProfiles
        )
        let state = ManagedSIPAccountsState(
            accounts: managedAccounts,
            activeSIPAddress: activeManagedSIPAddress
        )
        try saveManagedAccountsState(state, savedProfiles: result.profiles)
        return result.profile
    }

    @discardableResult
    func saveNewAssistantProfile(
        name: String,
        instructions: String,
        contextData: String?,
        for account: ManagedSIPAccount
    ) throws -> SavedAssistantProfile {
        guard var updated = managedAccounts.first(where: { $0.sipAddress == account.sipAddress }) else {
            throw SIPAccountError.missingManagedAccount
        }
        let profile = SavedAssistantProfile(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            instructions: instructions,
            contextData: contextData
        )
        var profiles = savedAssistantProfiles
        profiles.append(profile)
        updated.assistantProfile = .custom
        updated.savedProfileID = profile.id
        updated.assistantInstructionsOverride = instructions
        updated.assistantContextData = contextData
        var state = ManagedSIPAccountsState(
            accounts: managedAccounts,
            activeSIPAddress: activeManagedSIPAddress
        )
        state.update(updated)
        try saveManagedAccountsState(state, savedProfiles: profiles)
        return profile
    }

    func deleteSavedAssistantProfile(id: UUID) throws {
        guard let profile = savedAssistantProfiles.first(where: { $0.id == id }) else {
            throw SIPAccountError.missingSavedAssistantProfile
        }
        var state = ManagedSIPAccountsState(
            accounts: managedAccounts,
            activeSIPAddress: activeManagedSIPAddress
        )
        for var account in state.accounts where account.savedProfileID == id {
            account.savedProfileID = nil
            account.assistantProfile = .custom
            account.assistantProfileName = profile.name
            account.assistantInstructionsOverride = profile.instructions
            account.assistantContextData = profile.contextData ?? account.assistantContextData
            state.update(account)
        }
        let profiles = savedAssistantProfiles.filter { $0.id != id }
        try saveManagedAccountsState(state, savedProfiles: profiles)
    }

    func removeManagedAccount(_ account: ManagedSIPAccount) throws {
        guard currentCallInstanceID == nil else { throw SIPAccountError.activeCall }
        guard managedAccounts.contains(where: { $0.sipAddress == account.sipAddress }) else { return }
        var accountsState = ManagedSIPAccountsState(accounts: managedAccounts, activeSIPAddress: activeManagedSIPAddress)
        accountsState.remove(account)
        // Persist first: a removed password with a still-configured line would
        // leave a line that can never register again.
        try saveManagedAccountsState(accountsState)
        try SIPPasswordStore.remove(account: account.sipAddress)
        invalidateAccountSecretCache()
        let removedDirectory = instancesDirectory.appendingPathComponent(
            sanitizedBaresipInstanceAOR(account.sipAddress),
            isDirectory: true
        )
        if accountsState.accounts.isEmpty {
            stopBaresipAndWait()
            try? FileManager.default.removeItem(at: removedDirectory)
            try? FileManager.default.removeItem(at: configDirectory.appendingPathComponent("accounts"))
            registrationStatus = .idle
            state = .stopped
            // Removing the last line lands back on the empty state, the same
            // screen a fresh install shows.
            requestLibraryWindow()
        } else {
            // Only the removed line's engine goes; the other lines keep their
            // registrations rather than all re-registering at once.
            stopManagedInstance(id: sanitizedBaresipInstanceAOR(account.sipAddress))
            try? FileManager.default.removeItem(at: removedDirectory)
            refreshAggregateRegistrationStatus()
            refreshIdleState()
        }
    }

    /// The way back from an error state. A failed or dead outgoing line is
    /// re-registered on its own; a call error on a healthy line only needs the
    /// idle state recomputed.
    func recoverFromError() {
        guard currentCallInstanceID == nil else { return }
        if let account = activeManagedAccount {
            let instanceID = sanitizedBaresipInstanceAOR(account.sipAddress)
            var needsRestart = instances[instanceID]?.isRunning != true
            if case .failed = registrationStatuses[instanceID] ?? .idle { needsRestart = true }
            if needsRestart {
                restartManagedInstance(for: account)
                return
            }
        } else if activeInstance?.isRunning != true {
            startBaresip()
            return
        }
        refreshIdleState()
    }

    func dial() {
        clearAssistantCall()
        pendingDialRetry = nil
        guard state.isReady else { return }
        guard let value = validatedDialTarget(number) else {
            state = .error("Please enter a valid number")
            return
        }
        number = value
        UserDefaults.standard.set(value, forKey: "lastDialedNumber")
        currentDirection = .outgoing
        currentCallInstanceID = activeInstanceID
        currentCallAccountAOR = activeManagedAccount?.sipAddress ?? unmanagedAccountAOR
        currentCallStartedAt = Date()
        hasActiveEventCall = true
        state = .dialing(value)
        eventBus.publish(.callOutgoing(target: value))
        send("/dial \(value)")
    }

    func dialWithAssistant(task: String) {
        guard state.isReady, isGeminiConfigured else { return }
        let value = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else {
            state = .error("Please enter a valid number")
            return
        }
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return }
        assistantCallPlan.begin(task: task)
        isAssistantCallActive = true
        beginDial(value, clearsRetry: true)
    }

    private func beginDial(_ value: String, clearsRetry: Bool) {
        if clearsRetry { pendingDialRetry = nil }
        dialedTarget = value
        number = value
        UserDefaults.standard.set(value, forKey: "lastDialedNumber")
        currentDirection = .outgoing
        currentCallInstanceID = activeInstanceID
        currentCallAccountAOR = activeManagedAccount?.sipAddress ?? unmanagedAccountAOR
        if currentCallStartedAt == nil {
            currentCallStartedAt = Date()
            hasActiveEventCall = true
            eventBus.publish(.callOutgoing(target: value))
        }
        state = .dialing(value)
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
        pendingDialRetry = nil
        clearAssistantCall()
        cancelAutoAnswer()
        clearIncomingCallNotification()
        recordCall(missed: false)
        send("/hangup")
        finishCall(missed: false)
        refreshIdleState()
        promoteDeferredIncomingCallIfAvailable()
    }

    func hangup() {
        guard state.isInCall else { return }
        send("/hangup")
        recordCall(missed: false)
        finishCall()
        refreshIdleState()
        promoteDeferredIncomingCallIfAvailable()
    }

    /// Toggles the microphone for the active call (baresip single-key command).
    func toggleMute() {
        guard state.isConnected else { return }
        send("/mute")
        isMuted.toggle()
        mutedByBridge = false
    }

    func saveGeminiAPIKey(_ key: String) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw GeminiLiveError.invalidAPIKey }
        try GeminiAPIKeyStore.save(value)
        refreshAssistantConfiguration()
    }

    func refreshAssistantConfiguration() {
        isGeminiConfigured = GeminiAPIKeyStore.apiKey() != nil
    }

    func toggleGeminiLive() {
        guard state.isConnected else { return }
        if isGeminiLiveActive {
            clearAssistantCall()
            stopGeminiLive()
            return
        }
        startGeminiLive(sendsInitialGreeting: false)
    }

    private func startGeminiLive(sendsInitialGreeting: Bool, instructions instructionOverride: String? = nil) {
        guard state.isConnected else { return }
        let defaults = UserDefaults.standard
        guard let apiKey = GeminiAPIKeyStore.apiKey() else {
            geminiLiveState = .failed(GeminiLiveError.invalidAPIKey.localizedDescription)
            isGeminiConfigured = false
            clearAssistantCall()
            return
        }
        let storedModel = defaults.string(forKey: "geminiLiveModel")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = storedModel.flatMap { $0.isEmpty ? nil : $0 } ?? defaultGeminiLiveModel
        let globalInstructions = defaults.string(forKey: "assistantInstructions")
            ?? assistantInstructionsDefault(for: defaults.string(forKey: "assistantUserDisplayName"))
        let profileInstructions = instructionOverride ?? assistantSystemInstruction(
            calledAOR: currentDirection == .incoming ? currentCallAccountAOR : nil,
            globalInstructions: globalInstructions,
            date: Date()
        )
        let callerContext: String?
        if sendsInitialGreeting, currentDirection == .incoming, let peer = state.peer,
           let name = displayName(for: peer), name != peer {
            callerContext = "Der Anrufer heißt \(name)."
        } else {
            callerContext = nil
        }
        let contextualInstructions = [profileInstructions, callerContext]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        let instructions = composeAssistantSystemInstruction(
            instructions: contextualInstructions,
            contextData: nil,
            includesGreetingTrigger: sendsInitialGreeting
        )
        guard let injectionSocketPath = commandInstance?.socketPaths.injection else {
            geminiLiveState = .failed("Audio bridge unavailable")
            clearAssistantCall()
            return
        }
        let bridge = geminiLiveBridge
        geminiLiveState = .connecting
        geminiBridgeTask?.cancel()
        bridgeGeneration &+= 1
        let generation = bridgeGeneration
        geminiBridgeTask = Task {
            guard !Task.isCancelled else { return }
            await bridge.start(
                apiKey: apiKey,
                model: model,
                instructions: instructions,
                sendsInitialGreeting: sendsInitialGreeting,
                injectionSocketPath: injectionSocketPath,
                onState: { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard let self, self.bridgeGeneration == generation else { return }
                        self.geminiLiveState = state
                        if case .live = state {
                            self.finalizeLocalDrafts()
                            self.geminiTranscriptionActive = true
                            self.muteForBridgeIfNeeded()
                        }
                        if case .failed(let message) = state {
                            self.geminiTranscriptionActive = false
                            self.unmuteAfterBridgeIfNeeded()
                            self.clearAssistantCall()
                            self.appendDiagnostic("phone-app: Gemini Live failed: \(redactSensitiveValues(in: message))\n")
                        }
                    }
                },
                onTranscript: { [weak self] speaker, text in
                    Task { @MainActor [weak self] in
                        guard let self, self.bridgeGeneration == generation else { return }
                        self.receiveGeminiTranscript(speaker: speaker, text: text)
                    }
                },
                onToolCall: { [weak self] call in
                    await MainActor.run { [weak self] in
                        guard let self, self.bridgeGeneration == generation else { return }
                        self.handleGeminiToolCall(call)
                    }
                }
            )
            // No stop here on cancellation: whoever cancelled — a stop or a
            // replacement start — already owns the bridge's next state, and a
            // stop from this side would take down the session that replaced
            // this one.
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
        try ensurePreferredAudioCodecModules(bundledModulesDirectory)
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

    private func ensurePreferredAudioCodecModules(_ modulesDirectory: URL) throws {
        let fileManager = FileManager.default
        let modules = ["opus.so", "g722.so"].filter { module in
            fileManager.fileExists(atPath: modulesDirectory.appendingPathComponent(module).path)
        }
        guard !modules.isEmpty else { return }

        let url = configDirectory.appendingPathComponent("config")
        let content = try String(contentsOf: url, encoding: .utf8)
        let updated = configEnsuringPreferredAudioCodecModules(content, modules: modules)
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

    private var instancesDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("instances", isDirectory: true)
    }

    private func startBaresip() {
        // Entries whose process is gone are dropped so the line can start
        // again; entries that are still running are left alone.
        for (id, instance) in instances where !instance.isRunning {
            detach(instance)
            instances[id] = nil
            registrationStatuses[id] = nil
            lineBuffers[id] = nil
            deferredIncomingCalls[id] = nil
        }
        if !instances.isEmpty {
            startMissingManagedInstances()
            return
        }
        isShuttingDown = false
        instancesWithSIPTrace = []
        cleanupOrphanedBaresip()

        guard let executable = baresipExecutable else {
            recordStartupFailure("baresip was not found")
            return
        }

        do {
            try prepareRuntime()
            instances = try makeBaresipInstances()
        } catch {
            recordStartupFailure(error.localizedDescription)
            return
        }

        registrationStatuses = Dictionary(uniqueKeysWithValues: instances.keys.map { ($0, .registering) })
        refreshAggregateRegistrationStatus()
        state = .starting
        for instance in instances.values {
            configureCallbacks(for: instance)
            appendDiagnostic("phone-app[\(instance.id)]: starting baresip\n")
            do {
                try instance.start(executable: executable, currentDirectory: applicationSupportDirectory)
                armRegistrationWatchdog(for: instance)
            } catch {
                updateRegistrationStatus(.failed("baresip could not be started"), for: instance)
            }
        }
        refreshIdleState()
    }

    /// Starts every enabled managed line that has no running engine, without
    /// touching the ones that do. Used when one engine died or a line was
    /// added while the others were up.
    private func startMissingManagedInstances() {
        isShuttingDown = false
        guard !managedAccounts.isEmpty else { return }
        for (index, account) in managedAccounts.enumerated() where account.isEnabled {
            let instanceID = sanitizedBaresipInstanceAOR(account.sipAddress)
            guard instances[instanceID] == nil else { continue }
            startManagedInstance(for: account, index: index)
        }
        refreshAggregateRegistrationStatus()
        refreshIdleState()
    }

    /// Brings one line's engine to the state its configuration describes and
    /// leaves the other lines alone. Falls back to the full start when no
    /// engine is running yet, or when a hand-edited account file is still in
    /// charge and has to make way for managed lines.
    private func restartManagedInstance(
        for account: ManagedSIPAccount,
        removingInstanceFor previousSIPAddress: String? = nil
    ) {
        if let previousSIPAddress, previousSIPAddress != account.sipAddress {
            let previousID = sanitizedBaresipInstanceAOR(previousSIPAddress)
            stopManagedInstance(id: previousID)
            try? FileManager.default.removeItem(
                at: instancesDirectory.appendingPathComponent(previousID, isDirectory: true)
            )
        }
        stopManagedInstance(id: sanitizedBaresipInstanceAOR(account.sipAddress))
        if instances["unmanaged"] != nil {
            restartBaresip()
            return
        }
        guard instances.values.contains(where: \.isRunning),
              let index = managedAccounts.firstIndex(where: { $0.sipAddress == account.sipAddress }) else {
            startBaresip()
            return
        }
        if managedAccounts[index].isEnabled {
            startManagedInstance(for: managedAccounts[index], index: index)
        }
        refreshAggregateRegistrationStatus()
        refreshIdleState()
    }

    private func armRegistrationWatchdog(for instance: BaresipInstance) {
        registrationWatchdogs[instance.id]?.cancel()
        let timeout = registrationTimeout
        registrationWatchdogs[instance.id] = Task { @MainActor [weak self, weak instance] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, let instance,
                  self.instances[instance.id] === instance else { return }
            self.registrationWatchdogs[instance.id] = nil
            // baresip keeps retrying on its own; a later success line still
            // flips the entry back to registered.
            guard instance.registrationStatus == .registering else { return }
            self.appendDiagnostic("phone-app[\(instance.id)]: no registration answer within \(timeout)\n")
            self.updateRegistrationStatus(.failed(registrationTimeoutMessage(timeout)), for: instance)
        }
    }

    private func detach(_ instance: BaresipInstance) {
        instance.onOutput = nil
        instance.onTermination = nil
        instance.onAudioFrame = nil
        registrationWatchdogs[instance.id]?.cancel()
        registrationWatchdogs[instance.id] = nil
    }

    /// A start that fails before any instance exists still has to reach the
    /// lines: the setup screen and the line bar read the entry per line, and a
    /// failure recorded only in the aggregate leaves them showing an idle line.
    /// The aggregate is set directly rather than derived — with no enabled line
    /// there is nothing to derive it from, and the message would be lost.
    private func recordStartupFailure(_ message: String) {
        registrationStatuses = failedRegistrationStatuses(for: enabledManagedAccounts, message: message)
        registrationStatus = .failed(message)
        state = .error(message)
    }

    private func makeBaresipInstances() throws -> [String: BaresipInstance] {
        if managedAccounts.isEmpty {
            guard FileManager.default.fileExists(atPath: configDirectory.appendingPathComponent("accounts").path) else {
                throw SIPAccountError.missingManagedAccount
            }
            let instance = BaresipInstance(
                id: "unmanaged",
                accountAOR: unmanagedAccountAOR,
                configDirectory: configDirectory,
                pidFileURL: pidFileURL
            )
            return [instance.id: instance]
        }

        var result: [String: BaresipInstance] = [:]
        // The index decides the instance's RTP port range, so it is taken from
        // the full account list: taking one line offline must not move the
        // ports of the lines around it.
        for (index, account) in managedAccounts.enumerated() where account.isEnabled {
            let instance = try makeBaresipInstance(account: account, index: index)
            result[instance.id] = instance
        }
        return result
    }

    private func makeBaresipInstance(account: ManagedSIPAccount, index: Int) throws -> BaresipInstance {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: instancesDirectory, withIntermediateDirectories: true)
        let sharedConfig = try String(contentsOf: configDirectory.appendingPathComponent("config"), encoding: .utf8)
        let contactsURL = configDirectory.appendingPathComponent("contacts")
        let id = sanitizedBaresipInstanceAOR(account.sipAddress)
        let directory = instancesDirectory.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try perInstanceBaresipConfig(sharedConfig: sharedConfig, instanceIndex: index)
            .write(to: directory.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let password = try SIPPasswordStore.password(account: account.sipAddress)
        try writePrivateFile(
            managedInstanceAccountLine(account: account, password: password),
            to: directory.appendingPathComponent("accounts")
        )
        if fileManager.fileExists(atPath: contactsURL.path) {
            let contacts = try Data(contentsOf: contactsURL)
            try contacts.write(to: directory.appendingPathComponent("contacts"), options: .atomic)
        }
        return BaresipInstance(
            id: id,
            accountAOR: account.sipAddress,
            configDirectory: directory,
            pidFileURL: directory.appendingPathComponent("baresip.pid"),
            ownsAccountsFile: true
        )
    }

    /// Registers or unregisters a single line. A full restart would re-register
    /// every account and trips provider-side rate limiting, so enabling and
    /// disabling deliberately touches only the affected instance.
    func setManagedAccountEnabled(_ account: ManagedSIPAccount, isEnabled: Bool) throws {
        guard let index = managedAccounts.firstIndex(where: { $0.sipAddress == account.sipAddress }) else {
            throw SIPAccountError.missingManagedAccount
        }
        guard managedAccounts[index].isEnabled != isEnabled else { return }
        let instanceID = sanitizedBaresipInstanceAOR(account.sipAddress)
        guard currentCallInstanceID != instanceID else { throw SIPAccountError.activeCall }
        // Stopping pumps the run loop, so a second flip can arrive mid-flight
        // and would race the first over the same instance id and pid file.
        guard !linesChangingEnablement.contains(instanceID) else { throw SIPAccountError.lineBusy }
        linesChangingEnablement.insert(instanceID)
        defer { linesChangingEnablement.remove(instanceID) }

        var accounts = managedAccounts
        accounts[index].isEnabled = isEnabled
        let updated = accounts[index]

        let activeAddress = activeSIPAddress(
            after: updated,
            accounts: accounts,
            previousActive: activeManagedSIPAddress
        )

        try saveManagedAccountsState(
            ManagedSIPAccountsState(accounts: accounts, activeSIPAddress: activeAddress)
        )

        if isEnabled {
            startManagedInstance(for: updated, index: index)
        } else {
            stopManagedInstance(id: instanceID)
        }
        refreshAggregateRegistrationStatus()
        refreshIdleState()
    }

    private func startManagedInstance(for account: ManagedSIPAccount, index: Int) {
        let instanceID = sanitizedBaresipInstanceAOR(account.sipAddress)
        guard instances[instanceID] == nil else { return }
        guard let executable = baresipExecutable else {
            registrationStatuses[instanceID] = .failed("baresip was not found")
            return
        }
        isShuttingDown = false
        do {
            try prepareRuntime()
            let instance = try makeBaresipInstance(account: account, index: index)
            instance.cleanupOrphanedProcess()
            instances[instance.id] = instance
            registrationStatuses[instance.id] = .registering
            configureCallbacks(for: instance)
            appendDiagnostic("phone-app[\(instance.id)]: starting baresip\n")
            try instance.start(executable: executable, currentDirectory: applicationSupportDirectory)
            armRegistrationWatchdog(for: instance)
        } catch {
            registrationStatuses[instanceID] = .failed(error.localizedDescription)
        }
    }

    private func stopManagedInstance(id: String) {
        guard let instance = instances[id] else { return }
        // stopAndWait() pumps the run loop, so everything observable has to be
        // correct before it is called: the instance is detached from its
        // callbacks so no late output is attributed to a line that no longer
        // exists, and the published state already reflects the line being gone.
        // The global `isStoppingInstances` flag is deliberately not used — it
        // would also swallow the termination of a different line on a call.
        detach(instance)
        instances[id] = nil
        registrationStatuses[id] = nil
        lineBuffers[id] = nil
        deferredIncomingCalls[id] = nil
        instancesWithSIPTrace.remove(id)
        refreshAggregateRegistrationStatus()
        refreshIdleState()
        instance.stopAndWait()
    }

    private func writePrivateFile(_ content: String, to url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Data(content.utf8))
        try handle.synchronize()
        try handle.close()
    }

    private func configureCallbacks(for instance: BaresipInstance) {
        instance.onOutput = { [weak self] instance, text in
            self?.consume(text, from: instance)
        }
        instance.onTermination = { [weak self] instance in
            self?.didStop(instance)
        }
        instance.onAudioFrame = { [weak self] instanceID, frame in
            Task { @MainActor [weak self] in self?.consumeAudioFrame(frame, from: instanceID) }
        }
    }

    private func consumeAudioFrame(_ frame: AudioFrame, from instanceID: String) {
        guard currentCallInstanceID == instanceID else { return }
        Task { await intelligence.append(frame) }
        Task { await geminiLiveBridge.append(frame) }
    }

    private func restartBaresip(removingInstanceFor sipAddress: String? = nil) {
        stopBaresipAndWait()
        if let sipAddress {
            try? FileManager.default.removeItem(
                at: instancesDirectory.appendingPathComponent(
                    sanitizedBaresipInstanceAOR(sipAddress),
                    isDirectory: true
                )
            )
        }
        startBaresip()
    }

    private func stopBaresip() {
        clearIncomingCallNotification()
        for instance in instances.values { instance.stop() }
    }

    private func stopBaresipAndWait() {
        isStoppingInstances = true
        for task in registrationWatchdogs.values { task.cancel() }
        registrationWatchdogs = [:]
        BaresipInstance.stopAndWait(Array(instances.values))
        instances = [:]
        lineBuffers = [:]
        registrationStatuses = [:]
        deferredIncomingCalls = [:]
        isStoppingInstances = false
    }

    private func cleanupOrphanedBaresip() {
        let unmanaged = BaresipInstance(
            id: "unmanaged",
            accountAOR: nil,
            configDirectory: configDirectory,
            pidFileURL: pidFileURL
        )
        unmanaged.cleanupOrphanedProcess()
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: instancesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for directory in directories {
            let instance = BaresipInstance(
                id: directory.lastPathComponent,
                accountAOR: nil,
                configDirectory: directory,
                pidFileURL: directory.appendingPathComponent("baresip.pid")
            )
            instance.cleanupOrphanedProcess()
        }
    }

    private func didStop(_ instance: BaresipInstance) {
        // A line that was taken offline is already gone from `instances`, and a
        // replacement may already hold its id. Nothing may be touched before
        // this instance is confirmed to still be the current one.
        guard instances[instance.id] === instance else { return }
        lineBuffers[instance.id] = nil
        deferredIncomingCalls[instance.id] = nil
        if instance.registrationStatus == .registering {
            updateRegistrationStatus(.failed("baresip stopped before registration completed"), for: instance)
        } else if registrationStatuses[instance.id] != nil {
            updateRegistrationStatus(.idle, for: instance)
        }
        guard !isStoppingInstances, !isShuttingDown else { return }
        if currentCallInstanceID == instance.id {
            if hasActiveEventCall {
                recordCall(missed: false)
                finishCall()
            }
            refreshIdleState()
            promoteDeferredIncomingCallIfAvailable()
        } else {
            refreshIdleState()
        }
    }

    private func send(_ command: String, to instance: BaresipInstance? = nil) {
        let target = instance ?? commandInstance
        let label = target?.id ?? "none"
        appendDiagnostic("phone-app[\(label)] > \(command)\n")
        target?.send(command)
    }

    private func updateRegistrationStatus(_ status: RegistrationStatus, for instance: BaresipInstance) {
        instance.setRegistrationStatus(status)
        registrationStatuses[instance.id] = status
        refreshAggregateRegistrationStatus()
        refreshIdleState()
    }

    /// Records a status for a line by id instead of through a live instance, for
    /// callers that suspended while waiting: the line may have been taken
    /// offline meanwhile, and writing an entry back for a line that is gone
    /// would make it reappear in every status listing.
    private func updateRegistrationStatus(_ status: RegistrationStatus, forInstanceID id: String) {
        guard registrationStatuses[id] != nil || instances[id] != nil else { return }
        instances[id]?.setRegistrationStatus(status)
        registrationStatuses[id] = status
        refreshAggregateRegistrationStatus()
        refreshIdleState()
    }

    private func refreshAggregateRegistrationStatus() {
        let total = managedAccounts.isEmpty ? (instances.isEmpty ? 0 : 1) : enabledManagedAccounts.count
        registrationStatus = aggregateRegistrationState(Array(registrationStatuses.values), total: total).status
    }

    private func refreshIdleState() {
        guard currentCallInstanceID == nil else { return }
        guard let activeInstanceID else {
            state = .stopped
            return
        }
        switch registrationStatuses[activeInstanceID] ?? .idle {
        case .registered: state = .ready
        case .registering: state = .starting
        case .failed(let message): state = .error(message)
        case .idle: state = instances[activeInstanceID]?.isRunning == true ? .starting : .stopped
        }
    }

    private func persistManagedAccounts() throws {
        let state = ManagedSIPAccountsState(accounts: managedAccounts, activeSIPAddress: activeManagedSIPAddress)
        try saveManagedAccountsState(state)
    }

    private func saveManagedAccountsState(
        _ state: ManagedSIPAccountsState,
        savedProfiles profiles: [SavedAssistantProfile]? = nil
    ) throws {
        // accounts.json is the single canonical store; the UserDefaults keys are
        // removed after migration so no second representation can drift.
        let profiles = profiles ?? savedAssistantProfiles
        if state.accounts.isEmpty && profiles.isEmpty {
            try? FileManager.default.removeItem(at: accountsFileURL)
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let file = ManagedAccountsFile(
                accounts: state.accounts,
                activeSIPAddress: state.activeSIPAddress,
                savedProfiles: profiles
            )
            let data = try encoder.encode(file)
            try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
            try data.write(to: accountsFileURL, options: .atomic)
        }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "managedSIPAccounts")
        defaults.removeObject(forKey: "activeManagedSIPAccount")
        defaults.removeObject(forKey: "managedSIPAccount")
        defaults.removeObject(forKey: "managedAccount")
        managedAccounts = state.accounts
        savedAssistantProfiles = profiles
        activeManagedSIPAddress = state.activeSIPAddress
    }

    private var accountsFileURL: URL {
        applicationSupportDirectory.appendingPathComponent("accounts.json")
    }

    private static func loadAccountsFile(from url: URL) -> ManagedAccountsFile? {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ManagedAccountsFile.self, from: data),
              !file.accounts.isEmpty || !(file.savedProfiles ?? []).isEmpty else { return nil }
        return migrateSavedAssistantProfiles(in: file)
    }

    private var cachedAccountSecrets: [String]?
    /// Provisioning suspends while registration settles; a second change during
    /// that window would report a state that never existed.
    private var isProvisioningLine = false

    private var provisioningBusyError: ControlError {
        ControlError(
            code: "busy",
            message: "Another line change is still settling. Retry once it reports its registration."
        )
    }

    private func appendDiagnostic(_ text: String) {
        let filtered = filteringAudioStatistics(from: text)
        guard !filtered.isEmpty, let data = filtered.data(using: .utf8) else { return }
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

    private func consume(_ text: String, from instance: BaresipInstance) {
        var buffer = lineBuffers[instance.id, default: ""]
        buffer += text.replacingOccurrences(of: "\r", with: "\n")
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty {
                appendDiagnostic(redactSensitiveValues(
                    in: "baresip[\(instance.id)]: \(line)\n",
                    secrets: knownAccountSecrets()
                ))
            }
            consumeLine(line, from: instance)
        }
        if buffer.count > 16_000 { buffer.removeFirst(buffer.count - 16_000) }
        lineBuffers[instance.id] = buffer
    }

    private func consumeLine(_ line: String, from instance: BaresipInstance) {
        guard let event = Self.parseCallEvent(line) else { return }
        switch event {
        case .registered:
            instance.removeOwnedAccountsFile()
            updateRegistrationStatus(.registered, for: instance)
            if UserDefaults.standard.bool(forKey: "sipTrace"), !instancesWithSIPTrace.contains(instance.id) {
                instancesWithSIPTrace.insert(instance.id)
                send("/siptrace", to: instance)
            }
        case .registrationFailed(let failure):
            instance.removeOwnedAccountsFile()
            // The parser only knows the patterns; a registrar that echoes the
            // password back in its own words is caught by the values here.
            updateRegistrationStatus(
                .failed(redactSensitiveValues(in: failure, secrets: knownAccountSecrets())),
                for: instance
            )
            if currentCallInstanceID == instance.id {
                pendingDialRetry = nil
                clearAssistantCall()
            }
        case .incoming(let calledAOR):
            let caller = callerName(from: line)
            let accountAOR = resolvedCallAccountAOR(instanceAOR: instance.accountAOR, parsedCalledAOR: calledAOR)
            guard incomingCallDisposition(
                currentInstanceID: currentCallInstanceID,
                incomingInstanceID: instance.id
            ) == .present else {
                deferredIncomingCalls[instance.id] = DeferredIncomingCall(
                    caller: caller,
                    accountAOR: accountAOR,
                    startedAt: Date()
                )
                return
            }
            presentIncomingCall(
                caller: caller,
                accountAOR: accountAOR,
                startedAt: Date(),
                instanceID: instance.id
            )
        case .closed where currentCallInstanceID != instance.id:
            deferredIncomingCalls[instance.id] = nil
        case .noAccounts(let failure):
            instance.removeOwnedAccountsFile()
            let message = redactSensitiveValues(in: failure, secrets: knownAccountSecrets())
            updateRegistrationStatus(
                .failed(message.isEmpty ? "No SIP account configured" : message),
                for: instance
            )
        default:
            guard currentCallInstanceID == instance.id else { return }
            consumeCurrentCallEvent(event)
        }
    }

    private func presentIncomingCall(
        caller: String?,
        accountAOR: String?,
        startedAt: Date,
        instanceID: String
    ) {
        pendingDialRetry = nil
        clearAssistantCall()
        currentCallInstanceID = instanceID
        currentDirection = .incoming
        currentCallAccountAOR = accountAOR
        currentCallStartedAt = startedAt
        hasActiveEventCall = true
        state = .ringing(caller)
        eventBus.publish(.callIncoming(peer: caller))
        showIncomingCallNotification(caller: caller)
        armAutoAnswerIfNeeded(for: instanceID)
    }

    private func promoteDeferredIncomingCallIfAvailable() {
        guard currentCallInstanceID == nil,
              let (instanceID, call) = deferredIncomingCalls.first,
              instances[instanceID]?.isRunning == true else { return }
        deferredIncomingCalls[instanceID] = nil
        presentIncomingCall(
            caller: call.caller,
            accountAOR: call.accountAOR,
            startedAt: call.startedAt,
            instanceID: instanceID
        )
    }

    private func consumeCurrentCallEvent(_ event: CallEvent) {
        switch event {
        case .established:
            guard !state.isConnected else { return }
            pendingDialRetry = nil
            let assistantCallTask = assistantCallPlan.established()
            let startsAssistant = startsAssistantWhenConnected
            cancelAutoAnswer(resetAssistant: false)
            startsAssistantWhenConnected = false
            state = .connected(state.peer)
            eventBus.publish(.callAnswered(peer: state.peer))
            clearIncomingCallNotification()
            beginCallIntelligence()
            // The assistant owns this call from the first second: the Mac's
            // microphone must not reach the line while Gemini is still
            // connecting, and it comes back only on handover or failure.
            if assistantCallTask != nil || startsAssistant { muteForBridgeIfNeeded() }
            if let assistantCallTask {
                let globalInstructions = UserDefaults.standard.string(forKey: "assistantInstructions")
                    ?? assistantInstructionsDefault(for: UserDefaults.standard.string(forKey: "assistantUserDisplayName"))
                let general = assistantSystemInstruction(
                    calledAOR: nil,
                    globalInstructions: globalInstructions,
                    date: Date()
                )
                let displayName = UserDefaults.standard.string(forKey: "assistantUserDisplayName") ?? ""
                let instructions = assistantCallInstructions(
                    general: general,
                    task: assistantCallTask,
                    userDisplayName: displayName
                )
                startGeminiLive(sendsInitialGreeting: false, instructions: instructions)
            } else if startsAssistant {
                startGeminiLive(sendsInitialGreeting: true)
            }
        case .dialing:
            // `number` is bound to a text field and may have been edited since
            // the dial started; the retry path reads this state back.
            state = .dialing(dialedTarget ?? number)
            clearIncomingCallNotification()
        case .securityViolation:
            recordCall(missed: false)
            finishCall()
            state = .error("The provider rejected the audio encryption")
            promoteDeferredIncomingCallIfAvailable()
        case .failed:
            recordCall(missed: false)
            finishCall()
            state = .error("The call could not be established")
            promoteDeferredIncomingCallIfAvailable()
        case .closed(let reason):
            if state.isInCall, !state.isConnected, let reason, !reason.isEmpty {
                if case .dialing(let target) = state, reason.hasPrefix("403"), pendingDialRetry == nil {
                    pendingDialRetry = target
                    finishCall(preservingDialRetry: true, preservingAssistantCall: true)
                    state = .ready
                    appendDiagnostic("phone-app: 403 on first INVITE, retrying dial once\n")
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(1.5))
                        guard let self, self.pendingDialRetry == target else { return }
                        guard self.state.isReady else {
                            self.pendingDialRetry = nil
                            self.clearAssistantCall()
                            return
                        }
                        self.number = target
                        self.beginDial(target, clearsRetry: false)
                    }
                    return
                }
                pendingDialRetry = nil
                recordCall(missed: false)
                finishCall()
                state = .error("Call rejected: \(reason)")
                clearIncomingCallNotification()
                promoteDeferredIncomingCallIfAvailable()
                return
            }
            pendingDialRetry = nil
            let missed = state.isRinging
            let caller = state.peer
            recordCall(missed: missed)
            finishCall(missed: missed)
            refreshIdleState()
            clearIncomingCallNotification()
            if missed { showMissedCallNotification(caller: caller) }
            promoteDeferredIncomingCallIfAvailable()
        case .registered, .registrationFailed, .incoming, .noAccounts:
            break
        }
    }

    enum CallEvent: Equatable {
        case registered
        case registrationFailed(String)
        case incoming(String?)
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
        if lower.contains("incoming call from") { return .incoming(parseIncomingCalledAOR(from: line)) }
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
        guard let user = displayLookupUser(for: peer) else { return nil }
        let existing = existingDisplayName(forUser: user)
        guard !normalizedPhoneNumber(user).isEmpty else { return existing }
        let system = existing == nil ? contactsDirectory.displayName(for: user) : nil
        return preferredContactDisplayName(existing: existing, system: system)
    }

    var callStateLabel: String {
        switch state {
        case .stopped: "Phone is off"
        case .starting: "Registering SIP …"
        case .ready: "Ready"
        case .ringing(let peer):
            peer.map { "Call from \(displayName(for: $0) ?? $0)" } ?? "Incoming call"
        case .dialing(let peer):
            "Calling \(displayName(for: peer) ?? peer)"
        case .answering: "Connecting …"
        case .connected(let peer):
            peer.map { "Connected to \(displayName(for: $0) ?? $0)" } ?? "Connected"
        case .error(let message): message
        }
    }

    func contactSuggestions(matching query: String, limit: Int = 8) -> [ContactsDirectoryEntry] {
        contactsDirectory.search(matching: query, limit: limit)
    }

    func systemContactsSettingDidChange() {
        contactsDirectory.settingsDidChange()
    }

    private func existingDisplayName(for peer: String?) -> String? {
        guard let user = displayLookupUser(for: peer) else { return nil }
        return existingDisplayName(forUser: user)
    }

    private func existingDisplayName(forUser user: String) -> String? {
        if let contact = contacts[user] { return contact }
        let account = managedAccounts.first { account in
            if normalizedSIPAOR(account.sipAddress) == normalizedSIPAOR(user) { return true }
            return [account.username, account.outboundCallerID]
                .compactMap { $0 }
                .contains { phoneNumbersMatch($0, user) }
        }
        return account?.displayName
    }

    private func displayLookupUser(for peer: String?) -> String? {
        guard var value = peer?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.lowercased().hasPrefix("sip:") { value.removeFirst(4) }
        return value.split(separator: "@").first.map(String.init) ?? value
    }

    private func callerName(from line: String) -> String? {
        parseCallerName(from: line)
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: "callHistory")
    }

    func deleteAllArchivedConversations() async {
        do {
            try await store.deleteAll()
            NotificationCenter.default.post(name: .phoneArchiveChanged, object: nil)
        } catch { }
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

    private func callPayload(_ call: ArchivedCall) -> JSONValue {
        .object([
            "call_id": .string(call.id.uuidString),
            "direction": .string(call.direction.rawValue),
            "peer": call.peer.map { JSONValue.string(presentablePeer($0)) } ?? .null,
            "name": (displayName(for: call.peer) ?? call.displayName).map(JSONValue.string) ?? .null,
            "timestamp": .string(ISO8601DateFormatter().string(from: call.startedAt)),
            "duration": .double(call.duration),
            "missed": .bool(call.missed),
            "has_summary": .bool(call.summary != nil)
        ])
    }

    private func linePayload(_ account: ManagedSIPAccount) -> JSONValue {
        controlLinePayload(
            for: account,
            status: registrationStatus(for: account),
            activeSIPAddress: activeManagedSIPAddress,
            assistantProfileDisplay: assistantProfileDisplay(for: account),
            sensitiveValues: controlSensitiveValues(for: account)
        )
    }

    /// Every password and provider token currently configured, so provider
    /// output that reflects one back never reaches the on-disk log.
    private func knownAccountSecrets() -> [String] {
        if let cached = cachedAccountSecrets { return cached }
        var secrets = managedAccounts.compactMap { account -> String? in
            guard let password = try? SIPPasswordStore.password(account: account.sipAddress),
                  !password.isEmpty else { return nil }
            return password
        }
        if let credentials = SipgateCredentialStore.credentials() {
            secrets.append(contentsOf: [credentials.tokenID, credentials.token])
        }
        cachedAccountSecrets = secrets
        return secrets
    }

    func invalidateAccountSecretCache() {
        cachedAccountSecrets = nil
    }

    private func controlSensitiveValues(for account: ManagedSIPAccount) -> [String] {
        guard let password = try? SIPPasswordStore.password(account: account.sipAddress),
              !password.isEmpty else { return [] }
        return [password]
    }

    private func assistantConfigurationPayload(_ account: ManagedSIPAccount) -> JSONValue {
        controlAssistantConfigurationPayload(
            for: account,
            savedProfile: savedAssistantProfile(id: account.savedProfileID)
        )
    }

    private func settledRegistrationStatus(
        for account: ManagedSIPAccount,
        timeout: Duration = .seconds(20)
    ) async -> RegistrationStatus {
        guard account.isEnabled else { return .idle }
        let instanceID = sanitizedBaresipInstanceAOR(account.sipAddress)
        let instance = instances[instanceID]
        let clock = ContinuousClock()
        let settled = await registrationStatusOnceSettled(
            timeout: timeout,
            now: { clock.now },
            status: { self.registrationStatus(for: account) },
            sleep: { try? await Task.sleep(for: .milliseconds(100)) }
        )
        if let settled { return settled }
        // baresip answered neither way. The timeout has to be written back, not
        // just returned: the line would otherwise keep the `registering` entry
        // it was polled on and the interface would show a registration that
        // never finishes.
        let timedOut = RegistrationStatus.failed(registrationTimeoutMessage(timeout))
        // Only for the process this wait was started for: a restart during the
        // wait puts a new one behind the same id, and its registration has had
        // less than the full timeout to arrive.
        if instances[instanceID] === instance {
            updateRegistrationStatus(timedOut, forInstanceID: instanceID)
        }
        return timedOut
    }

    /// Matches the name an agent is most likely to use: the label from
    /// list_lines, the bare user part, or the full SIP address.
    private func managedAccount(matching query: String) -> ManagedSIPAccount? {
        let query = query.lowercased()
        return managedAccounts.first {
            $0.displayName.lowercased() == query
                || $0.username.lowercased() == query
                || $0.sipAddress.lowercased() == query
        }
    }

    /// Ships the labelled fields next to the text so a receiving agent does not
    /// have to parse prose.
    private func summaryPayload(
        text: String,
        createdAt: Date,
        callID: UUID? = nil,
        source: String
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "text": .string(text),
            "timestamp": .string(ISO8601DateFormatter().string(from: createdAt)),
            "call_id": callID.map { JSONValue.string($0.uuidString) } ?? .null,
            // "live" is the call in progress or the one just finished, whose
            // archive entry may not exist yet; "archive" is a stored call.
            "source": .string(source)
        ]
        let sections = parseCallSummary(text)
        if !sections.isEmpty {
            payload["fields"] = .object(Dictionary(
                sections.map { ($0.field.rawValue, JSONValue.string($0.value)) },
                uniquingKeysWith: { first, _ in first }
            ))
        }
        return .object(payload)
    }

    private func switchAccountForControl(_ accountQuery: String?) -> ControlError? {
        guard let accountQuery else { return nil }
        let query = accountQuery.lowercased()
        guard let match = managedAccounts.first(where: {
            $0.label?.lowercased() == query
                || $0.username.lowercased() == query
                || $0.sipAddress.lowercased() == query
        }) else {
            return ControlError(code: "unknown_account", message: "No configured account matches '\(accountQuery)'.")
        }
        do {
            try selectManagedAccount(match)
            return nil
        } catch {
            return ControlError(code: "invalid_state", message: "Cannot switch account: \(error.localizedDescription)")
        }
    }

    private func handleControlCommand(_ command: ControlCommand) async -> ControlResponse {
        // Only the commands that need a line on the wire require registration.
        // Reading, and putting a line back online, must keep working — otherwise
        // an agent that takes the last line offline can never undo it.
        switch command {
        case .dial, .assistantCall, .answer, .hangup, .sendDTMF:
            guard hasRegisteredAccount else {
                return .failure(ControlError(code: "not_registered", message: "Phone is not registered with a SIP provider. Use list_lines to see which lines are offline."))
            }
        default:
            break
        }
        switch command {
        case .dial(let target, let accountQuery):
            if let error = switchAccountForControl(accountQuery) { return .failure(error) }
            guard state.isReady else {
                return .failure(ControlError(code: "invalid_state", message: "Phone is not ready to dial."))
            }
            number = target
            dial()
            return .success(.object(["state": .string("dialing"), "target": .string(target)]))
        case .assistantCall(let target, let task, let accountQuery):
            if let error = switchAccountForControl(accountQuery) { return .failure(error) }
            guard state.isReady else {
                return .failure(ControlError(code: "invalid_state", message: "Phone is not ready to dial."))
            }
            guard isGeminiConfigured else {
                return .failure(ControlError(code: "invalid_state", message: "No Gemini API key is configured for assistant calls."))
            }
            number = target
            dialWithAssistant(task: task)
            guard case .dialing = state else {
                return .failure(ControlError(code: "invalid_state", message: "Assistant call could not be started."))
            }
            return .success(.object(["state": .string("dialing"), "target": .string(target), "assistant": .bool(true)]))
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
        case .getHistory(let limit, let query):
            do {
                let calls = try await store.fetchCalls(query: query, limit: limit, offset: 0)
                return .success(.array(calls.map(callPayload)))
            } catch {
                return .failure(ControlError(code: "unavailable", message: error.localizedDescription))
            }
        case .listLines:
            return .success(.array(managedAccounts.map(linePayload)))
        case .listProvisioningEndpoints:
            var sensitiveValues: [String] = []
            do {
                guard let credentials = SipgateCredentialStore.credentials() else {
                    throw SipgateProvisioningError.missingPAT
                }
                sensitiveValues = [credentials.tokenID, credentials.token]
                invalidateAccountSecretCache()
                let service = SipgateProvisioningService(client: SipgateAPIClient(credentials: credentials))
                let devices = try await service.listDevices()
                return .success(controlProvisioningEndpointsPayload(
                    devices,
                    sensitiveValues: sensitiveValues
                ))
            } catch {
                return .failure(controlError(
                    for: error,
                    fallbackCode: "sipgate_unavailable",
                    sensitiveValues: sensitiveValues
                ))
            }
        case .provisioningStatus:
            return .success(controlSipgateCredentialsStatusPayload(SipgateCredentialStore.status()))
        case .provisionLine(let arguments):
            guard !isProvisioningLine else { return .failure(provisioningBusyError) }
            isProvisioningLine = true
            defer { isProvisioningLine = false }
            var sensitiveValues: [String] = []
            do {
                guard let credentials = SipgateCredentialStore.credentials() else {
                    throw SipgateProvisioningError.missingPAT
                }
                sensitiveValues = [credentials.tokenID, credentials.token]
                invalidateAccountSecretCache()
                let service = SipgateProvisioningService(client: SipgateAPIClient(credentials: credentials))
                // Refuse locally before a rotation makes the device's old password
                // worthless: the save would fail afterwards and nobody would hold
                // the new one.
                guard currentCallInstanceID == nil else { throw SIPAccountError.activeCall }
                let plan = try await service.provisioningPlan(for: arguments)
                sensitiveValues.append(plan.password)
                // Keep the create-line persistence ordering: validate, save the
                // Keychain secret, invalidate redaction, then persist/restart.
                try plan.account.validate(password: plan.password)
                try saveManagedAccountAndTest(plan.account, password: plan.password)
                let status = await settledRegistrationStatus(for: plan.account)
                guard let saved = managedAccounts.first(where: { $0.sipAddress == plan.account.sipAddress }) else {
                    return .failure(ControlError(
                        code: "unknown_line",
                        message: "The line was removed while its registration was still settling."
                    ))
                }
                let line = controlLinePayload(
                    for: saved,
                    status: status,
                    activeSIPAddress: activeManagedSIPAddress,
                    assistantProfileDisplay: assistantProfileDisplay(for: saved),
                    sensitiveValues: sensitiveValues
                )
                return .success(controlSipgateProvisioningPayload(
                    linePayload: line,
                    device: plan.device,
                    sensitiveValues: sensitiveValues
                ))
            } catch {
                return .failure(controlError(
                    for: error,
                    fallbackCode: "sipgate_provisioning_failed",
                    sensitiveValues: sensitiveValues
                ))
            }
        case .createLine(let arguments):
            guard !isProvisioningLine else { return .failure(provisioningBusyError) }
            isProvisioningLine = true
            defer { isProvisioningLine = false }
            do {
                let account = try managedSIPAccount(from: arguments)
                // Validate before either Keychain or account persistence changes.
                try account.validate(password: arguments.password)
                try saveManagedAccountAndTest(account, password: arguments.password)
                let status = await settledRegistrationStatus(for: account)
                // The wait suspends, so the line can be gone by now. Reporting a
                // status for an account that no longer exists would be fiction.
                guard let saved = managedAccounts.first(where: { $0.sipAddress == account.sipAddress }) else {
                    return .failure(ControlError(
                        code: "unknown_line",
                        message: "The line was removed while its registration was still settling."
                    ))
                }
                return .success(controlLinePayload(
                    for: saved,
                    status: status,
                    activeSIPAddress: activeManagedSIPAddress,
                    assistantProfileDisplay: assistantProfileDisplay(for: saved),
                    sensitiveValues: [arguments.password]
                ))
            } catch {
                return .failure(controlError(for: error))
            }
        case .updateLine(let arguments):
            guard !isProvisioningLine else { return .failure(provisioningBusyError) }
            isProvisioningLine = true
            defer { isProvisioningLine = false }
            guard let original = managedAccount(matching: arguments.line) else {
                return .failure(ControlError(code: "unknown_line", message: "No configured line matches '\(arguments.line)'."))
            }
            do {
                let updated = try managedSIPAccount(applying: arguments, to: original)
                let replacementPassword = arguments.password ?? ""
                let validationPassword = replacementPassword.isEmpty
                    ? try SIPPasswordStore.password(account: original.sipAddress)
                    : replacementPassword
                // Metadata-only edits also validate the complete stored account.
                try updated.validate(password: validationPassword)
                let plan = try editManagedAccount(
                    updated,
                    replacing: original.sipAddress,
                    password: replacementPassword
                )
                let saved = managedAccounts.first { $0.sipAddress == updated.sipAddress } ?? updated
                let status = plan.requiresRegistrationTest
                    ? await settledRegistrationStatus(for: saved)
                    : registrationStatus(for: saved)
                return .success(controlLinePayload(
                    for: saved,
                    status: status,
                    activeSIPAddress: activeManagedSIPAddress,
                    assistantProfileDisplay: assistantProfileDisplay(for: saved),
                    sensitiveValues: [validationPassword]
                ))
            } catch {
                return .failure(controlError(for: error))
            }
        case .deleteLine(let line):
            guard let account = managedAccount(matching: line) else {
                return .failure(ControlError(code: "unknown_line", message: "No configured line matches '\(line)'."))
            }
            do {
                try removeManagedAccount(account)
                return .success(.object([
                    "deleted": .bool(true),
                    "line": .string(account.displayName),
                    "sip_address": .string(account.sipAddress),
                    "active_line": activeManagedAccount.map { .string($0.displayName) } ?? .null
                ]))
            } catch {
                return .failure(controlError(for: error))
            }
        case .selectActiveLine(let line):
            guard let account = managedAccount(matching: line) else {
                return .failure(ControlError(code: "unknown_line", message: "No configured line matches '\(line)'."))
            }
            do {
                try selectManagedAccount(account)
                let selected = activeManagedAccount ?? account
                return .success(linePayload(selected))
            } catch {
                return .failure(controlError(for: error))
            }
        case .getRegistrationStatus(let line):
            if let line {
                guard let account = managedAccount(matching: line) else {
                    return .failure(ControlError(code: "unknown_line", message: "No configured line matches '\(line)'."))
                }
                return .success(controlRegistrationPayload(
                    for: account,
                    status: registrationStatus(for: account),
                    sensitiveValues: controlSensitiveValues(for: account)
                ))
            }
            return .success(.array(managedAccounts.map {
                controlRegistrationPayload(
                    for: $0,
                    status: registrationStatus(for: $0),
                    sensitiveValues: controlSensitiveValues(for: $0)
                )
            }))
        case .setLineEnabled(let line, let enabled):
            guard let account = managedAccount(matching: line) else {
                return .failure(ControlError(code: "unknown_line", message: "No configured line matches '\(line)'."))
            }
            do {
                try setManagedAccountEnabled(account, isEnabled: enabled)
                let updated = managedAccounts.first { $0.sipAddress == account.sipAddress } ?? account
                return .success(linePayload(updated))
            } catch {
                return .failure(controlError(for: error))
            }
        case .setLineProfile(let line, let profileName):
            guard var account = managedAccount(matching: line) else {
                return .failure(ControlError(code: "unknown_line", message: "No configured line matches '\(line)'."))
            }
            let query = profileName.lowercased()
            if let saved = savedAssistantProfiles.first(where: { $0.name.lowercased() == query }) {
                account.assistantProfile = .custom
                account.savedProfileID = saved.id
                account.assistantProfileName = saved.name
            } else if let preset = AssistantProfile.allCases.first(where: {
                $0.displayName.lowercased() == query || $0.rawValue.lowercased() == query
            }) {
                account.assistantProfile = preset
                account.savedProfileID = nil
                account.assistantProfileName = nil
                account.assistantInstructionsOverride = nil
                account.assistantContextData = nil
            } else {
                let available = (AssistantProfile.allCases.map(\.displayName) + savedAssistantProfiles.map(\.name))
                    .joined(separator: ", ")
                return .failure(ControlError(code: "unknown_profile", message: "No profile named '\(profileName)'. Available: \(available)."))
            }
            do {
                try updateManagedAccountMetadata(account)
                let updated = managedAccounts.first { $0.sipAddress == account.sipAddress } ?? account
                return .success(linePayload(updated))
            } catch {
                return .failure(controlError(for: error))
            }
        case .setLinePrompt(let line, let instructions, let contextData):
            guard let account = managedAccount(matching: line) else {
                return .failure(ControlError(code: "unknown_line", message: "No configured line matches '\(line)'."))
            }
            let updated = accountSettingCustomPrompt(
                account,
                instructions: instructions,
                contextData: contextData
            )
            do {
                try updateManagedAccountMetadata(updated)
                let saved = managedAccounts.first { $0.sipAddress == account.sipAddress } ?? updated
                return .success(assistantConfigurationPayload(saved))
            } catch {
                return .failure(controlError(for: error))
            }
        case .createAssistantProfile(let name, let instructions, let contextData):
            do {
                let profile = try createSavedAssistantProfile(
                    name: name,
                    instructions: instructions,
                    contextData: contextData
                )
                return .success(controlAssistantProfilePayload(profile))
            } catch {
                return .failure(controlError(for: error, fallbackCode: "unavailable"))
            }
        case .updateAssistantProfile(let profileID, let name, let instructions, let contextData):
            guard let id = UUID(uuidString: profileID) else {
                return .failure(ControlError(code: "invalid_arguments", message: "profile_id must be a UUID from list_assistant_profiles."))
            }
            do {
                try updateSavedAssistantProfile(id: id) { profile in
                    if let name { profile.name = name }
                    if let instructions { profile.instructions = instructions }
                    if let contextData {
                        profile.contextData = contextData.isEmpty ? nil : contextData
                    }
                }
                guard let updated = savedAssistantProfile(id: id) else {
                    throw SIPAccountError.missingSavedAssistantProfile
                }
                return .success(controlAssistantProfilePayload(updated))
            } catch {
                return .failure(controlError(for: error))
            }
        case .deleteAssistantProfile(let profileID):
            guard let id = UUID(uuidString: profileID) else {
                return .failure(ControlError(code: "invalid_arguments", message: "profile_id must be a UUID from list_assistant_profiles."))
            }
            do {
                guard let profile = savedAssistantProfile(id: id) else {
                    throw SIPAccountError.missingSavedAssistantProfile
                }
                try deleteSavedAssistantProfile(id: id)
                return .success(.object([
                    "deleted": .bool(true),
                    "profile_id": .string(profile.id.uuidString),
                    "name": .string(profile.name)
                ]))
            } catch {
                return .failure(controlError(for: error))
            }
        case .listAssistantProfiles:
            return .success(.array(savedAssistantProfiles.map(controlAssistantProfilePayload)))
        case .setLineAnswerMode(let line, let mode, let answerDelaySeconds):
            guard let account = managedAccount(matching: line) else {
                return .failure(ControlError(code: "unknown_line", message: "No configured line matches '\(line)'."))
            }
            let updated = accountSettingAnswerMode(
                account,
                mode: mode,
                answerDelaySeconds: answerDelaySeconds
            )
            do {
                try updateManagedAccountMetadata(updated)
                let saved = managedAccounts.first { $0.sipAddress == account.sipAddress } ?? updated
                return .success(assistantConfigurationPayload(saved))
            } catch {
                return .failure(controlError(for: error))
            }
        case .setLineBusinessHours(let line, let weekdays, let weekend):
            guard let account = managedAccount(matching: line) else {
                return .failure(ControlError(code: "unknown_line", message: "No configured line matches '\(line)'."))
            }
            let updated = accountSettingBusinessHours(
                account,
                weekdays: weekdays,
                weekend: weekend
            )
            do {
                try updateManagedAccountMetadata(updated)
                let saved = managedAccounts.first { $0.sipAddress == account.sipAddress } ?? updated
                return .success(assistantConfigurationPayload(saved))
            } catch {
                return .failure(controlError(for: error))
            }
        case .findContact(let name):
            let matches = contactSuggestions(matching: name, limit: 10).map { entry in
                JSONValue.object([
                    "name": .string(entry.displayName),
                    "number": .string(entry.number),
                    "label": .string(entry.label)
                ])
            }
            return .success(.array(matches))
        case .getLastSummary:
            if let summary {
                return .success(summaryPayload(text: summary.text, createdAt: summary.createdAt, source: "live"))
            }
            do {
                let calls = try await store.fetchCalls(limit: 50, offset: 0)
                guard let call = calls.first(where: { $0.summary != nil }), let text = call.summary else {
                    return .success(.null)
                }
                return .success(summaryPayload(text: text, createdAt: call.startedAt, callID: call.id, source: "archive"))
            } catch {
                return .failure(ControlError(code: "unavailable", message: error.localizedDescription))
            }
        case .getTranscript(let identifier, let limit):
            do {
                let call: ArchivedCall?
                if let identifier {
                    guard let parsed = UUID(uuidString: identifier) else {
                        return .failure(ControlError(code: "invalid_arguments", message: "call_id must be a UUID from get_history."))
                    }
                    call = try await store.call(id: parsed)
                    guard call != nil else {
                        return .failure(ControlError(code: "not_found", message: "No archived call has the id \(parsed.uuidString)."))
                    }
                } else {
                    call = try await store.fetchCalls(limit: 1, offset: 0).first
                }
                guard let call else {
                    return .failure(ControlError(code: "not_found", message: "The call archive is empty."))
                }
                let entries = try await store.fetchUtterances(callId: call.id)
                // The control client reads at most 64 KiB, so a long call has to
                // arrive in pieces rather than be truncated into invalid JSON.
                let page = entries.prefix(limit)
                let formatter = ISO8601DateFormatter()
                return .success(.object([
                    "call_id": .string(call.id.uuidString),
                    "utterance_count": .integer(entries.count),
                    "truncated": .bool(entries.count > page.count),
                    "utterances": .array(page.map { entry in
                        JSONValue.object([
                            "speaker": .string(entry.speakerTitle.lowercased()),
                            "text": .string(entry.text),
                            "timestamp": .string(formatter.string(from: entry.createdAt))
                        ])
                    })
                ]))
            } catch {
                return .failure(ControlError(code: "unavailable", message: error.localizedDescription))
            }
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
        let startedAt = currentCallStartedAt ?? callStartedAt ?? Date()
        currentCallStartedAt = nil
        let record = CallRecord(
            direction: direction,
            peer: state.peer,
            date: startedAt,
            duration: duration,
            missed: missed
        )
        pendingArchiveRecord = record
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

    private var archiveConversations: Bool {
        UserDefaults.standard.object(forKey: "archiveConversations") as? Bool ?? true
    }

    private func assistantSystemInstruction(calledAOR: String?, globalInstructions: String, date: Date) -> String {
        let resolved = resolveAssistantProfile(
            accounts: managedAccounts,
            savedProfiles: savedAssistantProfiles,
            calledAOR: calledAOR,
            activeSIPAddress: activeManagedSIPAddress,
            globalInstructions: globalInstructions,
            date: date
        )
        return composeAssistantSystemInstruction(
            instructions: resolved.instructions,
            contextData: resolved.contextData
        )
    }

    func managedAccount(forInstanceID instanceID: String) -> ManagedSIPAccount? {
        managedAccounts.first { sanitizedBaresipInstanceAOR($0.sipAddress) == instanceID }
    }

    private func armAutoAnswerIfNeeded(for instanceID: String) {
        cancelAutoAnswer()
        guard isGeminiConfigured else { return }
        // Answering is a property of the line that is ringing. A hand-edited
        // accounts file has no managed line, so that setup keeps the old
        // app-wide values.
        let defaults = UserDefaults.standard
        let account = managedAccount(forInstanceID: instanceID)
        let answers = shouldAssistantAnswer(
            mode: account?.assistantAnswerMode ?? storedAssistantAnswerMode(defaults: defaults),
            businessHours: account?.businessHours ?? storedBusinessHoursSchedule(defaults: defaults),
            date: Date()
        )
        guard answers else { return }
        isAutoAnswerArmed = true
        let delay = account?.assistantAnswerDelay
            ?? ManagedSIPAccount.clampedAnswerDelay(defaults.object(forKey: "assistantAnswerDelay") as? Int ?? 5)
        autoAnswerTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            self.autoAnswerTask = nil
            guard self.state.isRinging, canArmAutoAnswer(currentInstanceID: self.currentCallInstanceID, armedInstanceID: instanceID) else {
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
        geminiTranscriptionActive = false
        callStartedAt = Date()
        guard transcriptionEnabled else {
            intelligenceStatus = "Transcription is off"
            return
        }
        intelligenceRunning = true
        callGeneration &+= 1
        intelligenceStatus = "Preparing local models …"
        Task {
            do {
                try await intelligence.start { [weak self] speaker, text, isFinal in
                    Task { @MainActor in self?.receiveLocalTranscript(speaker: speaker, text: text, isFinal: isFinal) }
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

    private func receiveLocalTranscript(speaker: Speaker, text: String, isFinal: Bool) {
        guard !geminiTranscriptionActive else { return }
        receiveTranscript(speaker: speaker, text: text, isFinal: isFinal)
    }

    private func finalizeLocalDrafts() {
        for (speaker, draftID) in draftIDs {
            guard let index = transcript.firstIndex(where: { $0.id == draftID }) else { continue }
            transcript[index].isFinal = true
            eventBus.publish(.transcriptFinal(speaker: speaker.title, text: transcript[index].text))
        }
        draftIDs = [:]
    }

    private func receiveGeminiTranscript(speaker: Speaker, text: String) {
        guard transcriptionEnabled else { return }
        receiveTranscript(
            speaker: speaker,
            text: text,
            isFinal: true,
            isAssistantOverride: speaker == .me
        )
    }

    private func receiveTranscript(
        speaker: Speaker,
        text: String,
        isFinal: Bool,
        isAssistantOverride: Bool? = nil
    ) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let isAssistant = isAssistantOverride ?? (speaker == .me && geminiLiveState == .live)
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

    private func finishCall(missed: Bool = false, preservingDialRetry: Bool = false, preservingAssistantCall: Bool = false) {
        let finishingInstanceID = currentCallInstanceID
        let finishedAssistantTask = isAssistantCallActive ? assistantCallPlan.task : nil
        if !preservingDialRetry { currentCallInstanceID = nil }
        if !preservingDialRetry { pendingDialRetry = nil }
        if !preservingDialRetry { currentCallAccountAOR = nil }
        if !preservingAssistantCall { clearAssistantCall() }
        cancelAutoAnswer()
        stopGeminiLive(preservingTranscriptionRouting: true)
        let bridgeStopTask = geminiBridgeTask
        isMuted = false
        let peer = state.peer
        // Only an incoming call tells us where to call back. On an outgoing one
        // the peer is the number we dialled, and a SIP address is not a number
        // anybody can ring.
        let callbackNumberForSummary: String? = {
            guard currentDirection == .incoming, let peer else { return nil }
            let presentable = presentablePeer(peer)
            let digits = presentable.filter(\.isNumber)
            guard digits.count >= 6, !presentable.contains("@") else { return nil }
            return presentable
        }()
        let archiveRecord = pendingArchiveRecord
        pendingArchiveRecord = nil
        let includesContent = archiveConversations
        let wasIntelligenceRunning = intelligenceRunning
        let generation = callGeneration
        // Taken now: should another call start before the teardown below has
        // run, the shared transcript belongs to that call by the time it reads.
        let entriesBeforeTeardown = transcript.filter(\.isFinal)
        let duration = callStartedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        if hasActiveEventCall {
            hasActiveEventCall = false
            eventBus.publish(.callHungup(peer: peer, duration: duration, missed: missed))
        }
        let counts = finishingInstanceID.flatMap { instances[$0]?.drainAudioFrameCounts() } ?? [:]
        appendDiagnostic("phone-app: audio frames this call — me: \(counts[.me] ?? 0), caller: \(counts[.caller] ?? 0)\n")
        intelligenceRunning = false
        callStartedAt = nil
        if wasIntelligenceRunning { intelligenceStatus = "Summarizing the call …" }

        Task {
            await bridgeStopTask?.value
            let isStillThisCall = callGeneration == generation
            if wasIntelligenceRunning, isStillThisCall { await intelligence.stop() }
            await Task.yield()
            let entries = isStillThisCall ? transcript.filter(\.isFinal) : entriesBeforeTeardown
            if isStillThisCall { geminiTranscriptionActive = false }

            if let archiveRecord {
                do {
                    try await store.archiveCall(
                        archiveRecord,
                        displayName: displayName(for: archiveRecord.peer),
                        utterances: entries,
                        summary: nil,
                        includeConversationContent: includesContent
                    )
                    NotificationCenter.default.post(name: .phoneArchiveChanged, object: nil)
                } catch {
                    appendDiagnostic("phone-app: archiving the call failed: \(error)\n")
                    showAutomationStatus("The call could not be archived.")
                }
            }

            // A call that started meanwhile owns the lanes and the summary.
            guard wasIntelligenceRunning, isStillThisCall else { return }
            do {
                let text = try await intelligence.summarize(
                    entries: entries,
                    assistantTask: finishedAssistantTask,
                    callerNumber: callbackNumberForSummary
                )
                if includesContent, let archiveRecord {
                    do {
                        try await store.attachSummary(text, to: archiveRecord.id)
                    } catch {
                        appendDiagnostic("phone-app: attaching the summary failed: \(error)\n")
                        showAutomationStatus("The summary could not be archived.")
                    }
                }
                summary = CallSummary(text: text, createdAt: Date())
                eventBus.publish(
                    .callSummary(
                        text: text,
                        fields: Dictionary(
                            parseCallSummary(text).map { ($0.field.rawValue, $0.value) },
                            uniquingKeysWith: { first, _ in first }
                        )
                    )
                )
                intelligenceStatus = "Processed locally"
                if !retainTranscript { clearConversation() }
                if includesContent, archiveRecord != nil {
                    NotificationCenter.default.post(name: .phoneArchiveChanged, object: nil)
                }
            } catch {
                intelligenceStatus = "Summary unavailable"
                if !retainTranscript { clearConversation() }
            }
        }
    }

    private func muteForBridgeIfNeeded() {
        guard state.isConnected, !isMuted else { return }
        send("/mute")
        isMuted = true
        mutedByBridge = true
    }

    private func unmuteAfterBridgeIfNeeded() {
        guard mutedByBridge else { return }
        mutedByBridge = false
        guard isMuted, state.isConnected else { return }
        send("/mute")
        isMuted = false
    }

    private func handleGeminiToolCall(_ call: GeminiToolCall) {
        guard isAssistantCallActive, state.isConnected else { return }
        switch call.name {
        case "send_dtmf":
            guard let value = call.arguments["digit"]?.stringValue,
                  value.count == 1,
                  let digit = value.first else { return }
            sendDTMF(digit)
        case "handover_to_user":
            unmuteAfterBridgeIfNeeded()
            let content = UNMutableNotificationContent()
            content.title = "Assistant Call"
            content.body = "Der Assistent verbindet dich jetzt"
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "assistant-handover-\(UUID())", content: content, trigger: nil)
            )
            NSSound.beep()
        default:
            return
        }
    }

    private func stopGeminiLive(preservingTranscriptionRouting: Bool = false) {
        if !preservingTranscriptionRouting { geminiTranscriptionActive = false }
        guard geminiLiveState != .off else { return }
        bridgeGeneration &+= 1
        geminiLiveState = .off
        unmuteAfterBridgeIfNeeded()
        geminiBridgeTask?.cancel()
        let bridge = geminiLiveBridge
        geminiBridgeTask = Task { await bridge.stop() }
    }

    private func clearAssistantCall() {
        assistantCallPlan.callFailed()
        isAssistantCallActive = false
    }

    private func rotateDiagnosticLogIfNeeded() {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: diagnosticLogURL.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 5 * 1_024 * 1_024 else { return }
        let rotatedURL = diagnosticLogURL.appendingPathExtension("1")
        try? fileManager.removeItem(at: rotatedURL)
        try? fileManager.moveItem(at: diagnosticLogURL, to: rotatedURL)
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
            if actionIdentifier == UNNotificationDefaultActionIdentifier {
                NotificationCenter.default.post(name: .phoneOpenLibrary, object: nil)
            }
        }
    }

    private func showIncomingCallNotification(caller: String?) {
        let content = UNMutableNotificationContent()
        let displayedCaller = caller.map { displayName(for: $0) ?? $0 }
        content.title = "Incoming call"
        content.body = displayedCaller.map { "Call from \($0)" } ?? "The phone is ringing."
        content.sound = .default
        content.categoryIdentifier = "incoming-call"
        clearIncomingCallNotification()
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "incoming-call", content: content, trigger: nil))
        requestIncomingCallAttention()
    }

    private func showMissedCallNotification(caller: String?) {
        let content = UNMutableNotificationContent()
        let displayedCaller = caller.map { displayName(for: $0) ?? $0 }
        content.title = "Missed call"
        content.body = displayedCaller.map { "Call from \($0)" } ?? "A call was not answered."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "missed-\(UUID())", content: content, trigger: nil))
    }

    private func clearIncomingCallNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["incoming-call"])
        center.removeDeliveredNotifications(withIdentifiers: ["incoming-call"])
        cancelIncomingCallAttention()
    }

    /// Bounces the Dock icon until the app is activated. Only visible while the
    /// app runs with a Dock icon; in menu bar only mode AppKit ignores it.
    private func requestIncomingCallAttention() {
        guard incomingCallAttentionRequest == nil else { return }
        incomingCallAttentionRequest = NSApp.requestUserAttention(.criticalRequest)
    }

    private func cancelIncomingCallAttention() {
        guard let request = incomingCallAttentionRequest else { return }
        incomingCallAttentionRequest = nil
        NSApp.cancelUserAttentionRequest(request)
    }
}
