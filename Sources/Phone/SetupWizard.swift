import Foundation
import Security
import SwiftUI

enum SIPProviderPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case telekom = "Deutsche Telekom"
    case fritzBox = "FRITZ!Box"
    case sipgate = "sipgate"
    case easybell = "Easybell"
    case custom = "Custom SIP"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .telekom: "network"
        case .fritzBox: "router"
        case .sipgate: "phone.connection"
        case .easybell: "bell"
        case .custom: "slider.horizontal.3"
        }
    }

    var subtitle: String {
        switch self {
        case .telekom: "Direct landline registration"
        case .fritzBox: "Local router extension"
        case .sipgate: "sipgate account"
        case .easybell: "Easybell account"
        case .custom: "Any SIP registrar"
        }
    }

    var shortName: String {
        switch self {
        case .telekom: "Telekom"
        default: rawValue
        }
    }

    var defaults: (domain: String, outboundProxy: String, stunServer: String, mediaEncryption: String) {
        switch self {
        case .telekom: ("tel.t-online.de", "sip:tel.t-online.de", "stun:stun.t-online.de", "srtp-mand")
        case .fritzBox: ("fritz.box", "", "", "")
        case .sipgate: ("sipgate.de", "sip:proxy.live.sipgate.de", "", "")
        case .easybell: ("sip.easybell.de", "", "", "")
        case .custom: ("", "", "", "")
        }
    }
}

enum AssistantProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case personalAssistant
    case hotelDemo
    case travelIntake
    case custom

    var id: Self { self }

    var displayName: String {
        switch self {
        case .personalAssistant: "Personal"
        case .hotelDemo: "Hotel demo"
        case .travelIntake: "Travel intake"
        case .custom: "Custom"
        }
    }

    func presetInstructions(globalFallback: String) -> String {
        switch self {
        case .personalAssistant:
            globalFallback
        case .hotelDemo:
            "Du bist die freundliche, verkaufsaktive Telefonrezeption des fiktiven Hotels 'Strandhof' (Demo). Sei proaktiv wie eine gute Gastgeberin: Frage nach Zeitraum, Personenzahl und Wünschen, und mache dann von dir aus konkrete Vorschläge aus den Daten unten — nenne 1-2 passende Zimmer mit freien Terminen und Preis, statt nur auf Fragen zu antworten. Ist ein Wunschtermin ausgebucht, biete aktiv die nächstliegende freie Alternative oder ein anderes Zimmer an. Die Daten decken nur die nächsten 14 Tage ab; bei Anfragen danach sage das offen und biete an, den Wunsch als Vormerkung aufzunehmen. Beantworte Verfügbarkeit und Preise NUR anhand der Daten, erfinde nichts darüber hinaus. Nimm Reservierungswünsche mit Name und Rückrufnummer entgegen und bestätige sie als vorgemerkt (Demo, keine echte Buchung). Führe das Gespräch aktiv zum Abschluss: fasse am Ende zusammen, was vorgemerkt wurde."
        case .travelIntake:
            "Du bist der Telefon-Assistent eines Reisebüros (Demo). Es gibt zwei Anliegen:\n1) NEUE ANFRAGE: Nimm die Anfrage strukturiert auf und frage gezielt nach, bis du hast: Reiseziel/Region, Zeitraum oder Dauer, Anzahl und Alter der Reisenden, Budgetrahmen, Anlass und Vorlieben (z. B. Strand, Aktiv, Kultur), besondere Wünsche, Name und Rückrufnummer. Fasse am Ende alles kurz zusammen und bestätige, dass sich das Büro mit einem Angebot meldet.\n2) BESTEHENDE REISE: Wenn jemand nach einer gebuchten Reise fragt, verifiziere die Person zuerst: erfrage Nachnamen und Geburtsdatum und gleiche BEIDE mit den folgenden Buchungsdaten ab. Nur bei Übereinstimmung gibst du Auskunft (Reiseziel, Termine, Status, gebuchte Leistungen); bei Nichtübereinstimmung bittest du freundlich, sich mit der Buchungsnummer per E-Mail zu melden, und nennst keine Details. Erfinde keine Buchungen, die nicht in den Daten stehen."
        case .custom:
            ""
        }
    }

    func presetContextData(startingAt date: Date, calendar: Calendar = .current) -> String? {
        switch self {
        case .hotelDemo: hotelAvailabilityTable(startingAt: date, calendar: calendar)
        case .travelIntake: travelDemoBookings(startingAt: date, calendar: calendar)
        case .personalAssistant, .custom: nil
        }
    }
}

struct SavedAssistantProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var instructions: String
    var contextData: String?

    init(id: UUID = UUID(), name: String, instructions: String, contextData: String? = nil) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.contextData = contextData
    }
}

/// Adds a saved profile, or replaces the one that already carries that name.
/// The name is a profile's handle everywhere a line is pointed at one — the
/// lookup here is the same one `set_line_profile` uses — so a second profile
/// under a taken name is a copy nobody can select. Replacing instead of
/// appending is what lets the same call be repeated: it lands in the same
/// place rather than piling up duplicates behind one name.
func upsertSavedAssistantProfile(
    named name: String,
    instructions: String,
    contextData: String?,
    in profiles: [SavedAssistantProfile]
) -> (profiles: [SavedAssistantProfile], profile: SavedAssistantProfile) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedContext = contextData?.trimmingCharacters(in: .whitespacesAndNewlines)
    let contextData = trimmedContext?.isEmpty == false ? trimmedContext : nil
    var profiles = profiles
    if let index = profiles.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
        // Every field is replaced, including the one that was left out: the
        // result has to be the profile the arguments describe, not a mixture of
        // this call and the last one.
        profiles[index].name = name
        profiles[index].instructions = instructions
        profiles[index].contextData = contextData
        return (profiles, profiles[index])
    }
    let profile = SavedAssistantProfile(name: name, instructions: instructions, contextData: contextData)
    profiles.append(profile)
    return (profiles, profile)
}

func travelDemoBookings(startingAt date: Date, calendar: Calendar = .current) -> String {
    var calendar = calendar
    let start = calendar.startOfDay(for: date)
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "de_DE_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "dd.MM.yyyy"
    func day(_ offset: Int) -> String {
        formatter.string(from: calendar.date(byAdding: .day, value: offset, to: start) ?? start)
    }
    return """
    Buchungsdaten (Demo, vertraulich — nur nach Verifikation herausgeben):

    Buchung TRV-2417
    Name: Petra Sommerfeld, Geburtsdatum: 14.03.1978
    Reise: Rundreise Andalusien, \(day(21))–\(day(31)), 2 Erwachsene
    Status: bestätigt, Restzahlung fällig am \(day(7))
    Leistungen: Flug ab Düsseldorf, Mietwagen, 4 Hotels, Alhambra-Führung

    Buchung TRV-2508
    Name: Familie Brandt (Ansprechpartner Jonas Brandt), Geburtsdatum: 02.11.1985
    Reise: Familienurlaub Kreta, \(day(42))–\(day(52)), 2 Erwachsene + 2 Kinder (6, 9)
    Status: Angebot angenommen, Anzahlung eingegangen
    Leistungen: Flug ab Köln, Familiensuite halbpension, Kinderclub
    """
}

func hotelAvailabilityTable(startingAt date: Date, calendar: Calendar = .current) -> String {
    var calendar = calendar
    calendar.locale = Locale(identifier: "de_DE_POSIX")
    let start = calendar.startOfDay(for: date)
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "de_DE_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    let seaViewBooked = Set([2, 8])
    let gardenBooked = Set([4, 11])
    let suiteBooked = Set([6, 12])
    var lines = [
        "Verfügbarkeit Hotel Strandhof (Demo)",
        "Datum | Doppelzimmer Meerblick (145 €/Nacht) | Doppelzimmer Garten (115 €/Nacht) | Suite (210 €/Nacht)"
    ]
    for offset in 0..<14 {
        guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
        let values = [
            seaViewBooked.contains(offset) ? "ausgebucht" : "frei",
            gardenBooked.contains(offset) ? "ausgebucht" : "frei",
            suiteBooked.contains(offset) ? "ausgebucht" : "frei"
        ]
        lines.append("\(formatter.string(from: day)) | \(values.joined(separator: " | "))")
    }
    return lines.joined(separator: "\n")
}

struct ManagedSIPAccount: Codable, Equatable, Identifiable, Sendable {
    var provider: SIPProviderPreset
    var username: String
    var domain: String
    var outboundProxy: String
    var stunServer: String
    var mediaEncryption: String
    var label: String? = nil
    var sipDisplayName: String? = nil
    var outboundCallerID: String? = nil
    var assistantProfile: AssistantProfile = .personalAssistant
    var assistantProfileName: String? = nil
    var savedProfileID: UUID? = nil
    var assistantInstructionsOverride: String? = nil
    var assistantContextData: String? = nil
    /// A disabled account keeps its configuration and password but does not
    /// register, so the line is invisible to the provider until it is enabled.
    var isEnabled: Bool = true
    /// Answering behaviour belongs to the line, not to the app: a business
    /// number and a private number want different rules on the same Mac.
    var assistantAnswerMode: AssistantAnswerMode = .never
    var assistantAnswerDelay: Int = 5
    var businessHours: BusinessHoursSchedule = BusinessHoursSchedule()

    init(
        provider: SIPProviderPreset,
        username: String,
        domain: String,
        outboundProxy: String,
        stunServer: String,
        mediaEncryption: String,
        label: String? = nil,
        sipDisplayName: String? = nil,
        outboundCallerID: String? = nil,
        assistantProfile: AssistantProfile = .personalAssistant,
        assistantProfileName: String? = nil,
        savedProfileID: UUID? = nil,
        assistantInstructionsOverride: String? = nil,
        assistantContextData: String? = nil,
        isEnabled: Bool = true,
        assistantAnswerMode: AssistantAnswerMode = .never,
        assistantAnswerDelay: Int = 5,
        businessHours: BusinessHoursSchedule = BusinessHoursSchedule()
    ) {
        self.provider = provider
        self.username = username
        self.domain = domain
        self.outboundProxy = outboundProxy
        self.stunServer = stunServer
        self.mediaEncryption = mediaEncryption
        self.label = label
        self.sipDisplayName = sipDisplayName
        self.outboundCallerID = Self.normalizedOutboundCallerID(outboundCallerID)
        self.assistantProfile = assistantProfile
        self.assistantProfileName = assistantProfileName
        self.savedProfileID = savedProfileID
        self.assistantInstructionsOverride = assistantInstructionsOverride
        self.assistantContextData = assistantContextData
        self.isEnabled = isEnabled
        self.assistantAnswerMode = assistantAnswerMode
        self.assistantAnswerDelay = Self.clampedAnswerDelay(assistantAnswerDelay)
        self.businessHours = businessHours
    }

    static func clampedAnswerDelay(_ value: Int) -> Int { min(max(value, 0), 30) }

    var id: String { sipAddress }
    var sipAddress: String { "\(username)@\(domain)" }
    var displayName: String {
        let value = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? username : value
    }
    var assistantProfileDisplay: String {
        let custom = assistantProfileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? assistantProfile.displayName : custom
    }
    func assistantProfileDisplay(savedProfiles: [SavedAssistantProfile]) -> String {
        if let savedProfileID,
           let profile = savedProfiles.first(where: { $0.id == savedProfileID }) {
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return assistantProfileDisplay
    }
    /// What the panel header calls this line: its label when it has one, so
    /// the header and the line bar in the main window agree, otherwise the
    /// number, or the full address for a custom registrar.
    var registrationDisplay: String {
        let name = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let address = name.isEmpty ? (provider == .custom ? sipAddress : username) : name
        return "\(address) · \(provider.shortName)"
    }

    func accountLine(password: String) throws -> String {
        try validate(password: password)
        var parameters = ["auth_pass=\"\(quoted(password))\"", "regint=300"]
        if !outboundProxy.isEmpty { parameters.append("outbound=\"\(quoted(outboundProxy))\"") }
        if !stunServer.isEmpty { parameters.append("stunserver=\(stunServer)") }
        if !mediaEncryption.isEmpty { parameters.append("mediaenc=\(mediaEncryption)") }
        let trimmedDisplayName = sipDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // baresip 4.11's src/account.c decodes `extra` only as opaque metadata,
        // while include/baresip.h exposes custom INVITE headers solely through
        // linked UA APIs. The vendored child-process modules provide no per-account
        // config or command for those APIs, so P-Preferred-Identity cannot be added
        // cleanly here. Use the caller ID as the AOR display name fallback instead.
        let effectiveDisplayName = Self.normalizedOutboundCallerID(outboundCallerID) ?? trimmedDisplayName
        let prefix = effectiveDisplayName.isEmpty ? "" : "\"\(quoted(effectiveDisplayName))\" "
        return "\(prefix)<sip:\(sipAddress)>;\(parameters.joined(separator: ";"))\n"
    }

    func validate(password: String) throws {
        guard !username.isEmpty else { throw SIPAccountError.missingUsername }
        guard !domain.isEmpty else { throw SIPAccountError.missingDomain }
        guard !password.isEmpty else { throw SIPAccountError.missingPassword }
        let forbidden = CharacterSet(charactersIn: "\r\n;<>\"")
        guard username.rangeOfCharacter(from: forbidden.union(.whitespacesAndNewlines)) == nil,
              !username.contains("@") else { throw SIPAccountError.invalidUsername }
        let providerForbidden = forbidden.union(.whitespacesAndNewlines)
        for value in [domain, outboundProxy, stunServer, mediaEncryption] where value.rangeOfCharacter(from: providerForbidden) != nil {
            throw SIPAccountError.invalidProviderSettings
        }
        guard !domain.contains("@") else { throw SIPAccountError.invalidProviderSettings }
        guard password.rangeOfCharacter(from: .newlines) == nil else { throw SIPAccountError.invalidPassword }
        guard sipDisplayName?.rangeOfCharacter(from: .newlines) == nil else {
            throw SIPAccountError.invalidProviderSettings
        }
        if let outboundCallerID = Self.normalizedOutboundCallerID(outboundCallerID) {
            let digits = outboundCallerID.hasPrefix("+") ? outboundCallerID.dropFirst() : outboundCallerID[...]
            guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw SIPAccountError.invalidOutboundCallerID
            }
        }
    }

    private static func normalizedOutboundCallerID(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.replacingOccurrences(of: " ", with: "")
        return normalized.isEmpty ? nil : normalized
    }

    private func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum ManagedSIPAccountField: CaseIterable, Hashable, Sendable {
    case provider
    case username
    case domain
    case password
    case outboundProxy
    case stunServer
    case mediaEncryption
    case label
    case sipDisplayName
    case outboundCallerID
    case assistantProfile
    case assistantProfileName
    case savedProfileID
    case assistantInstructionsOverride
    case assistantContextData

    var isRegistrationRelevant: Bool {
        switch self {
        case .username, .domain, .password, .outboundProxy, .stunServer, .mediaEncryption, .sipDisplayName, .outboundCallerID:
            true
        case .provider, .label, .assistantProfile, .assistantProfileName, .savedProfileID, .assistantInstructionsOverride, .assistantContextData:
            false
        }
    }

    var requiresRegistrationTest: Bool {
        isRegistrationRelevant && self != .sipDisplayName && self != .outboundCallerID
    }
}

struct ManagedSIPAccountEditPlan: Equatable, Sendable {
    let changedFields: Set<ManagedSIPAccountField>

    var requiresEngineRestart: Bool {
        changedFields.contains { $0.isRegistrationRelevant }
    }

    var requiresRegistrationTest: Bool {
        changedFields.contains { $0.requiresRegistrationTest }
    }
}

func managedSIPAccountEditPlan(
    original: ManagedSIPAccount,
    updated: ManagedSIPAccount,
    replacementPassword: String
) -> ManagedSIPAccountEditPlan {
    var changedFields: Set<ManagedSIPAccountField> = []
    if original.provider != updated.provider { changedFields.insert(.provider) }
    if original.username != updated.username { changedFields.insert(.username) }
    if original.domain != updated.domain { changedFields.insert(.domain) }
    if !replacementPassword.isEmpty { changedFields.insert(.password) }
    if original.outboundProxy != updated.outboundProxy { changedFields.insert(.outboundProxy) }
    if original.stunServer != updated.stunServer { changedFields.insert(.stunServer) }
    if original.mediaEncryption != updated.mediaEncryption { changedFields.insert(.mediaEncryption) }
    if original.label != updated.label { changedFields.insert(.label) }
    if original.sipDisplayName != updated.sipDisplayName { changedFields.insert(.sipDisplayName) }
    if original.outboundCallerID != updated.outboundCallerID { changedFields.insert(.outboundCallerID) }
    if original.assistantProfile != updated.assistantProfile { changedFields.insert(.assistantProfile) }
    if original.assistantProfileName != updated.assistantProfileName { changedFields.insert(.assistantProfileName) }
    if original.savedProfileID != updated.savedProfileID { changedFields.insert(.savedProfileID) }
    if original.assistantInstructionsOverride != updated.assistantInstructionsOverride {
        changedFields.insert(.assistantInstructionsOverride)
    }
    if original.assistantContextData != updated.assistantContextData { changedFields.insert(.assistantContextData) }
    return ManagedSIPAccountEditPlan(changedFields: changedFields)
}

extension ManagedSIPAccount {

    private enum CodingKeys: String, CodingKey {
        case provider
        case username
        case domain
        case outboundProxy
        case stunServer
        case mediaEncryption
        case label
        case sipDisplayName
        case outboundCallerID
        case assistantProfile
        case assistantProfileName
        case savedProfileID
        case assistantInstructionsOverride
        case assistantContextData
        case isEnabled
        case assistantAnswerMode
        case assistantAnswerDelay
        case businessHours
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(SIPProviderPreset.self, forKey: .provider)
        username = try container.decode(String.self, forKey: .username)
        domain = try container.decode(String.self, forKey: .domain)
        outboundProxy = try container.decode(String.self, forKey: .outboundProxy)
        stunServer = try container.decode(String.self, forKey: .stunServer)
        mediaEncryption = try container.decode(String.self, forKey: .mediaEncryption)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        sipDisplayName = try container.decodeIfPresent(String.self, forKey: .sipDisplayName)
        outboundCallerID = Self.normalizedOutboundCallerID(
            try container.decodeIfPresent(String.self, forKey: .outboundCallerID)
        )
        assistantProfile = try container.decodeIfPresent(AssistantProfile.self, forKey: .assistantProfile) ?? .personalAssistant
        assistantProfileName = try container.decodeIfPresent(String.self, forKey: .assistantProfileName)
        savedProfileID = try container.decodeIfPresent(UUID.self, forKey: .savedProfileID)
        assistantInstructionsOverride = try container.decodeIfPresent(String.self, forKey: .assistantInstructionsOverride)
        assistantContextData = try container.decodeIfPresent(String.self, forKey: .assistantContextData)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        assistantAnswerMode = try container.decodeIfPresent(AssistantAnswerMode.self, forKey: .assistantAnswerMode) ?? .never
        assistantAnswerDelay = Self.clampedAnswerDelay(
            try container.decodeIfPresent(Int.self, forKey: .assistantAnswerDelay) ?? 5
        )
        businessHours = try container.decodeIfPresent(BusinessHoursSchedule.self, forKey: .businessHours)
            ?? BusinessHoursSchedule()
    }
}

/// After a line was taken online or offline the outgoing line may have to move:
/// an offline line cannot place calls, and the first line to come back online
/// adopts an active address that still points at an offline line.
func activeSIPAddress(
    after change: ManagedSIPAccount,
    accounts: [ManagedSIPAccount],
    previousActive: String?
) -> String? {
    let activeIsOnline = accounts.first { $0.sipAddress == previousActive }?.isEnabled == true
    if change.isEnabled {
        return activeIsOnline ? previousActive : change.sipAddress
    }
    guard previousActive == change.sipAddress else { return previousActive }
    return accounts.first(where: \.isEnabled)?.sipAddress ?? previousActive
}

func orderedManagedAccounts(_ accounts: [ManagedSIPAccount], activeSIPAddress: String?) -> [ManagedSIPAccount] {
    guard let activeSIPAddress,
          let activeIndex = accounts.firstIndex(where: { $0.sipAddress == activeSIPAddress }),
          activeIndex != accounts.startIndex else { return accounts }
    var ordered = accounts
    let active = ordered.remove(at: activeIndex)
    ordered.insert(active, at: ordered.startIndex)
    return ordered
}

func managedAccountsFileContent(
    accounts: [ManagedSIPAccount],
    activeSIPAddress: String?,
    passwordFor: (ManagedSIPAccount) throws -> String
) throws -> String {
    try orderedManagedAccounts(accounts, activeSIPAddress: activeSIPAddress)
        .map { account in try account.accountLine(password: passwordFor(account)) }
        .joined()
}

struct ManagedAccountsFile: Codable, Equatable, Sendable {
    var accounts: [ManagedSIPAccount]
    var activeSIPAddress: String?
    var savedProfiles: [SavedAssistantProfile]?

    init(
        accounts: [ManagedSIPAccount],
        activeSIPAddress: String?,
        savedProfiles: [SavedAssistantProfile]? = nil
    ) {
        self.accounts = accounts
        self.activeSIPAddress = activeSIPAddress
        self.savedProfiles = savedProfiles
    }
}

let assistantAnsweringMigrationDefaultsKey = "didMigrateAssistantAnsweringToAccounts"

/// Answering used to be one setting for the whole app. The first launch after
/// the move stamps those values onto every existing line, so no phone silently
/// changes how it answers.
func accountsAdoptingGlobalAnswering(
    _ accounts: [ManagedSIPAccount],
    mode: AssistantAnswerMode,
    delay: Int,
    businessHours: BusinessHoursSchedule
) -> [ManagedSIPAccount] {
    accounts.map { account in
        var account = account
        account.assistantAnswerMode = mode
        account.assistantAnswerDelay = ManagedSIPAccount.clampedAnswerDelay(delay)
        account.businessHours = businessHours
        return account
    }
}

func migrateSavedAssistantProfiles(in file: ManagedAccountsFile) -> ManagedAccountsFile {
    guard file.savedProfiles == nil else { return file }
    var accounts = file.accounts
    var profiles: [SavedAssistantProfile] = []

    for index in accounts.indices {
        guard accounts[index].assistantProfile == .custom,
              accounts[index].savedProfileID == nil,
              let instructions = accounts[index].assistantInstructionsOverride,
              !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

        if let existing = profiles.first(where: { $0.instructions == instructions }) {
            accounts[index].savedProfileID = existing.id
        } else {
            let trimmedName = accounts[index].assistantProfileName?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let profile = SavedAssistantProfile(
                name: trimmedName.isEmpty ? "Custom (\(accounts[index].displayName))" : trimmedName,
                instructions: instructions,
                contextData: accounts[index].assistantContextData
            )
            profiles.append(profile)
            accounts[index].savedProfileID = profile.id
        }
    }

    return ManagedAccountsFile(
        accounts: accounts,
        activeSIPAddress: file.activeSIPAddress,
        savedProfiles: profiles
    )
}

struct ManagedSIPAccountsState: Equatable, Sendable {
    private(set) var accounts: [ManagedSIPAccount]
    private(set) var activeSIPAddress: String?

    init(accounts: [ManagedSIPAccount], activeSIPAddress: String?) {
        var unique: [ManagedSIPAccount] = []
        for account in accounts {
            if let index = unique.firstIndex(where: { $0.sipAddress == account.sipAddress }) {
                unique[index] = account
            } else {
                unique.append(account)
            }
        }
        self.accounts = unique
        self.activeSIPAddress = unique.contains { $0.sipAddress == activeSIPAddress }
            ? activeSIPAddress
            : Self.fallbackActiveAddress(in: unique)
    }

    var activeAccount: ManagedSIPAccount? {
        accounts.first { $0.sipAddress == activeSIPAddress }
    }

    mutating func add(_ account: ManagedSIPAccount) {
        if let index = accounts.firstIndex(where: { $0.sipAddress == account.sipAddress }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        activeSIPAddress = account.sipAddress
    }

    mutating func select(_ account: ManagedSIPAccount) {
        guard accounts.contains(where: { $0.sipAddress == account.sipAddress }) else { return }
        activeSIPAddress = account.sipAddress
    }

    mutating func update(_ account: ManagedSIPAccount) {
        guard let index = accounts.firstIndex(where: { $0.sipAddress == account.sipAddress }) else { return }
        accounts[index] = account
    }

    mutating func replace(accountAt originalSIPAddress: String, with account: ManagedSIPAccount) throws {
        guard let index = accounts.firstIndex(where: { $0.sipAddress == originalSIPAddress }) else {
            throw SIPAccountError.missingManagedAccount
        }
        guard originalSIPAddress == account.sipAddress
                || !accounts.contains(where: { $0.sipAddress == account.sipAddress }) else {
            throw SIPAccountError.duplicateAccount
        }
        accounts[index] = account
        if activeSIPAddress == originalSIPAddress {
            activeSIPAddress = account.sipAddress
        }
    }

    /// Prefers an online line: making an offline line the outgoing one leaves
    /// the app unregistered even though another line is up.
    static func fallbackActiveAddress(in accounts: [ManagedSIPAccount]) -> String? {
        (accounts.first(where: \.isEnabled) ?? accounts.first)?.sipAddress
    }

    mutating func remove(_ account: ManagedSIPAccount) {
        accounts.removeAll { $0.sipAddress == account.sipAddress }
        if activeSIPAddress == account.sipAddress {
            activeSIPAddress = Self.fallbackActiveAddress(in: accounts)
        }
    }
}

struct ManagedSIPAccountsLoadResult: Equatable, Sendable {
    let state: ManagedSIPAccountsState
    let migratedLegacyAccount: Bool
}

func decodeManagedSIPAccounts(
    accountsData: Data?,
    legacyAccountData: Data?,
    activeSIPAddress: String?
) -> ManagedSIPAccountsLoadResult {
    let decoder = JSONDecoder()
    if let accountsData,
       let accounts = try? decoder.decode([ManagedSIPAccount].self, from: accountsData) {
        return ManagedSIPAccountsLoadResult(
            state: ManagedSIPAccountsState(accounts: accounts, activeSIPAddress: activeSIPAddress),
            migratedLegacyAccount: false
        )
    }
    if let legacyAccountData,
       let account = try? decoder.decode(ManagedSIPAccount.self, from: legacyAccountData) {
        return ManagedSIPAccountsLoadResult(
            state: ManagedSIPAccountsState(accounts: [account], activeSIPAddress: account.sipAddress),
            migratedLegacyAccount: true
        )
    }
    return ManagedSIPAccountsLoadResult(
        state: ManagedSIPAccountsState(accounts: [], activeSIPAddress: nil),
        migratedLegacyAccount: false
    )
}

enum SIPAccountError: LocalizedError {
    case accountOffline
    case activeCall
    case duplicateAccount
    case invalidOutboundCallerID
    case invalidProviderSettings
    case invalidUsername
    case invalidPassword
    case keychain(OSStatus)
    case lineBusy
    case missingDomain
    case missingManagedAccount
    case missingPassword
    case missingSavedAssistantProfile
    case missingStoredPassword
    case missingUsername

    var errorDescription: String? {
        switch self {
        case .accountOffline: "Take this line online before calling from it."
        case .activeCall: "Finish the current call before changing the SIP account."
        case .duplicateAccount: "An account with this SIP address already exists."
        case .invalidOutboundCallerID: "Enter an outbound caller ID containing only an optional leading +, digits, and spaces."
        case .invalidProviderSettings: "The provider settings contain unsupported characters."
        case .invalidUsername: "Enter a username without spaces, @, or SIP punctuation."
        case .invalidPassword: "The password cannot contain a line break."
        case .lineBusy: "This line is still going online or offline. Try again in a moment."
        case .keychain(let status):
            SecCopyErrorMessageString(status, nil).map { ($0 as NSString) as String } ?? "The password could not be saved in Keychain."
        case .missingDomain: "Enter the SIP registrar."
        case .missingManagedAccount: "The managed SIP account is missing."
        case .missingPassword: "Enter the SIP password."
        case .missingSavedAssistantProfile: "The saved assistant profile is missing."
        case .missingStoredPassword: "The SIP password is missing from Keychain."
        case .missingUsername: "Enter the phone number or SIP username."
        }
    }
}

enum ManagedSIPPasswordEdit: Equatable, Sendable {
    case keep(account: String)
    case save(password: String, account: String)
    case move(password: String, from: String, to: String)
}

func managedSIPPasswordEdit(
    originalSIPAddress: String,
    updatedSIPAddress: String,
    replacementPassword: String,
    storedPassword: String?
) throws -> ManagedSIPPasswordEdit {
    if originalSIPAddress == updatedSIPAddress {
        return replacementPassword.isEmpty
            ? .keep(account: originalSIPAddress)
            : .save(password: replacementPassword, account: updatedSIPAddress)
    }
    let password = replacementPassword.isEmpty ? storedPassword : replacementPassword
    guard let password, !password.isEmpty else { throw SIPAccountError.missingStoredPassword }
    return .move(password: password, from: originalSIPAddress, to: updatedSIPAddress)
}

enum SIPPasswordStore {
    static let service = "Phone SIP"

    static func save(_ password: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(password.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw SIPAccountError.keychain(updateStatus) }
        var item = query
        item[kSecValueData as String] = Data(password.utf8)
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw SIPAccountError.keychain(addStatus) }
    }

    static func password(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw SIPAccountError.missingStoredPassword }
        guard status == errSecSuccess else { throw SIPAccountError.keychain(status) }
        guard let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else { throw SIPAccountError.missingStoredPassword }
        return password
    }

    static func remove(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SIPAccountError.keychain(status) }
    }
}

struct SetupWizard: View {
    @ObservedObject var phone: PhoneController
    let editingAccount: ManagedSIPAccount?
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var provider = SIPProviderPreset.telekom
    @State private var label = ""
    @State private var sipDisplayName = ""
    @State private var outboundCallerID = ""
    @State private var username = ""
    @State private var password = ""
    @State private var domain = SIPProviderPreset.telekom.defaults.domain
    @State private var outboundProxy = SIPProviderPreset.telekom.defaults.outboundProxy
    @State private var stunServer = SIPProviderPreset.telekom.defaults.stunServer
    @State private var mediaEncryption = SIPProviderPreset.telekom.defaults.mediaEncryption
    @State private var submissionError: String?
    @State private var showsAdvanced = false
    @State private var editingSIPAddress: String?
    /// The line whose registration the test step reports. The aggregate over
    /// all lines would show another line's failure here, and would never
    /// reach "registered" while any other line is down.
    @State private var testedSIPAddress: String?
    /// The account this wizard created. From then on a corrected password or
    /// username is an edit of that line, not a second line with the same
    /// address — which is what the first attempt after a typo used to be.
    @State private var savedAccount: ManagedSIPAccount?
    @FocusState private var focusedField: Field?

    private enum Field {
        case username
        case password
        case registrar
    }

    init(phone: PhoneController, editing editingAccount: ManagedSIPAccount? = nil) {
        self.phone = phone
        self.editingAccount = editingAccount
    }

    var body: some View {
        VStack(spacing: 0) {
            wizardHeader
            Divider()
            Group {
                switch step {
                case 0: providerStep
                case 1: credentialsStep
                default: testStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
        .frame(width: 560, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reset)
    }

    private var wizardHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(editingAccount == nil ? "Set up your SIP account" : "Edit SIP account")
                    .font(.title2.weight(.semibold))
                Text(editingAccount == nil ? "Connect Phone directly to your provider or local router." : "Update account details. Registration is tested only when needed.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                ForEach(Array(wizardStepTitles.enumerated()), id: \.offset) { index, title in
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.16))
                                .frame(width: 24, height: 24)
                            if index == 2 && !requiresRegistrationTest {
                                Image(systemName: "minus")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)
                            } else if index < step {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(index == step ? .white : .secondary)
                            }
                        }
                        Text(title)
                            .font(.system(size: 12, weight: index == step ? .semibold : .regular))
                            .foregroundStyle(index <= step ? .primary : .secondary)
                    }
                    if index < 2 {
                        Capsule()
                            .fill(index < step ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.16))
                            .frame(height: 2)
                            .padding(.horizontal, 12)
                    }
                }
            }
        }
        .padding(24)
    }

    private var providerStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Choose your provider")
                    .font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(SIPProviderPreset.allCases) { item in
                        Button {
                            selectProvider(item)
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(provider == item ? Color.accentColor : .secondary)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.rawValue)
                                        .fontWeight(.medium)
                                    Text(item.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if provider == item {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                            .background(provider == item ? Color.accentColor.opacity(0.085) : Color.primary.opacity(0.035))
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(provider == item ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.07))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                providerConfiguration
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private var providerConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            if provider != .custom {
                VStack(spacing: 8) {
                    configurationRow("Registrar", value: domain)
                    configurationRow("Outbound proxy", value: outboundProxy.isEmpty ? "Automatic" : outboundProxy)
                    configurationRow("STUN", value: stunServer.isEmpty ? "Not used" : stunServer)
                    configurationRow("Media encryption", value: mediaEncryption.isEmpty ? "Provider default" : mediaEncryption)
                }
            }
            DisclosureGroup("Advanced settings", isExpanded: $showsAdvanced) {
                VStack(spacing: 12) {
                    setupField("Registrar", text: $domain, prompt: "sip.example.com")
                    setupField("Outbound proxy", text: $outboundProxy, prompt: "Optional")
                    setupField("STUN server", text: $stunServer, prompt: "Optional")
                    Picker("Media encryption", selection: $mediaEncryption) {
                        Text("None").tag("")
                        Text("SRTP").tag("srtp")
                        Text("SRTP required").tag("srtp-mand")
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var credentialsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Enter your credentials")
                    .font(.headline)
                Text("The password is stored in your login Keychain and is never saved with the account settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            // The two fields every line needs come first; the rest is optional
            // and says so, instead of three optional rows standing in front
            // of the username on a first-time screen.
            VStack(spacing: 14) {
                setupField("Number or username", text: $username, prompt: provider == .telekom ? "+49…" : "SIP username")
                    .focused($focusedField, equals: .username)
                LabeledContent("Password") {
                    SecureField(editingAccount == nil ? "Required" : "Leave empty to keep stored password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .focused($focusedField, equals: .password)
                }
                if let submissionError {
                    Text(submissionError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(18)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 14) {
                Text("Optional")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                setupField("Label", text: $label, prompt: "For example Private or Work")
                setupField("Display name", text: $sipDisplayName, prompt: "Shown to the people you call")
                VStack(alignment: .leading, spacing: 5) {
                    setupField("Outbound caller ID", text: $outboundCallerID, prompt: "+49 170 1234567")
                    Text("Applies only to this line. Your provider must support CLIP no screening.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(18)
            .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.green)
                Text(username.isEmpty || domain.isEmpty ? "Your SIP address will appear here." : "SIP address: \(username)@\(domain)")
                    .font(.callout)
                    .textSelection(.enabled)
            }
            }
            .padding(28)
        }
        .onAppear { focusedField = .username }
    }

    private var testStep: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 96, height: 96)
                statusSymbol
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            VStack(spacing: 7) {
                Text(statusTitle)
                    .font(.title2.weight(.semibold))
                Text(statusDetail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 440)
            }
            if case .failed = displayedStatus {
                Button("Test again", action: retryRegistrationTest)
                    .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding(28)
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") {
                    submissionError = nil
                    step -= 1
                }
            }
            Spacer()
            if step == 0 {
                Button("Continue") { step = 1 }
                    .buttonStyle(.borderedProminent)
                    .disabled(domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else if step == 1 {
                Button(requiresRegistrationTest ? "Test registration" : "Save", action: saveAccount)
                    .buttonStyle(.borderedProminent)
                    .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (editingAccount == nil && password.isEmpty) || domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else if displayedStatus == .registered || (step == 2 && testedLineIsOffline) {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var account: ManagedSIPAccount {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDisplayName = sipDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ManagedSIPAccount(
            provider: provider,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            domain: domain.trimmingCharacters(in: .whitespacesAndNewlines),
            outboundProxy: outboundProxy.trimmingCharacters(in: .whitespacesAndNewlines),
            stunServer: stunServer.trimmingCharacters(in: .whitespacesAndNewlines),
            mediaEncryption: mediaEncryption,
            label: trimmedLabel.isEmpty ? nil : trimmedLabel,
            sipDisplayName: trimmedDisplayName.isEmpty ? nil : trimmedDisplayName,
            outboundCallerID: outboundCallerID,
            assistantProfile: editingAccount?.assistantProfile ?? .personalAssistant,
            assistantProfileName: editingAccount?.assistantProfileName,
            savedProfileID: editingAccount?.savedProfileID,
            assistantInstructionsOverride: editingAccount?.assistantInstructionsOverride,
            assistantContextData: editingAccount?.assistantContextData,
            // Editing a line must not change whether it is online or how it
            // answers; the wizard only owns the connection settings.
            isEnabled: editingAccount?.isEnabled ?? true,
            assistantAnswerMode: editingAccount?.assistantAnswerMode ?? .never,
            assistantAnswerDelay: editingAccount?.assistantAnswerDelay ?? 5,
            businessHours: editingAccount?.businessHours ?? BusinessHoursSchedule()
        )
    }

    private var editPlan: ManagedSIPAccountEditPlan? {
        (editingAccount ?? savedAccount).map {
            managedSIPAccountEditPlan(original: $0, updated: account, replacementPassword: password)
        }
    }

    /// A line taken offline is saved but not registered; the test step has
    /// nothing to wait for and says so.
    private var testedLineIsOffline: Bool {
        testedAccount?.isEnabled == false
    }

    private var requiresRegistrationTest: Bool {
        editPlan?.requiresRegistrationTest ?? true
    }

    private var wizardStepTitles: [String] {
        ["Provider", "Credentials", requiresRegistrationTest ? "Test" : "Test not needed"]
    }

    private var testedAccount: ManagedSIPAccount? {
        guard let testedSIPAddress else { return nil }
        return phone.managedAccounts.first { $0.sipAddress == testedSIPAddress }
    }

    private var displayedStatus: RegistrationStatus {
        if let submissionError { return .failed(submissionError) }
        if let testedAccount { return phone.registrationStatus(for: testedAccount) }
        return phone.registrationStatus
    }

    private var statusTitle: String {
        if testedLineIsOffline, submissionError == nil { return "Saved, line is offline" }
        return switch displayedStatus {
        case .idle: "Ready to test"
        case .registering: "Registering …"
        case .registered: "Phone is registered"
        case .failed: "Registration failed"
        }
    }

    private var statusDetail: String {
        if testedLineIsOffline, submissionError == nil {
            return "The settings are saved. The line registers when it is taken online in Settings › Lines."
        }
        return switch displayedStatus {
        case .idle: "Phone will restart its SIP connection with these settings."
        case .registering: "Contacting \(domain) with the bundled SIP engine."
        case .registered: "Your account is ready for incoming and outgoing calls."
        case .failed(let message): message
        }
    }

    private var statusColor: Color {
        switch displayedStatus {
        case .idle: .secondary
        case .registering: .blue
        case .registered: .green
        case .failed: .orange
        }
    }

    @ViewBuilder
    private var statusSymbol: some View {
        switch displayedStatus {
        case .idle:
            Image(systemName: "phone.badge.clock")
        case .registering:
            ProgressView()
                .controlSize(.large)
        case .registered:
            Image(systemName: "checkmark")
        case .failed:
            Image(systemName: "exclamationmark")
        }
    }

    private func setupField(_ title: String, text: Binding<String>, prompt: String) -> some View {
        LabeledContent(title) {
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
        }
    }

    private func configurationRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func applyPreset(_ value: SIPProviderPreset) {
        guard value != .custom else { return }
        let defaults = value.defaults
        domain = defaults.domain
        outboundProxy = defaults.outboundProxy
        stunServer = defaults.stunServer
        mediaEncryption = defaults.mediaEncryption
    }

    private func selectProvider(_ value: SIPProviderPreset) {
        provider = value
        if value == .custom {
            // A custom registrar starts from nothing. Carrying the previous
            // preset's servers across put Telekom's registrar in front of
            // someone who had just said their provider is none of the above.
            domain = ""
            outboundProxy = ""
            stunServer = ""
            mediaEncryption = ""
        } else {
            applyPreset(value)
        }
        showsAdvanced = editingAccount != nil || value == .custom || value == .fritzBox
    }

    private func reset() {
        step = 0
        if let editingAccount {
            provider = editingAccount.provider
            label = editingAccount.label ?? ""
            sipDisplayName = editingAccount.sipDisplayName ?? ""
            outboundCallerID = editingAccount.outboundCallerID ?? ""
            username = editingAccount.username
            domain = editingAccount.domain
            outboundProxy = editingAccount.outboundProxy
            if editingAccount.provider == .sipgate && outboundProxy.isEmpty {
                outboundProxy = SIPProviderPreset.sipgate.defaults.outboundProxy
            }
            stunServer = editingAccount.stunServer
            mediaEncryption = editingAccount.mediaEncryption
            editingSIPAddress = editingAccount.sipAddress
            showsAdvanced = true
        } else {
            provider = .telekom
            label = ""
            sipDisplayName = ""
            outboundCallerID = ""
            username = ""
            editingSIPAddress = nil
            showsAdvanced = false
            applyPreset(.telekom)
        }
        testedSIPAddress = nil
        savedAccount = nil
        password = ""
        submissionError = nil
        focusedField = nil
    }

    private func saveAccount() {
        submissionError = nil
        let account = account
        let password = password
        do {
            if let editingSIPAddress {
                let plan = managedSIPAccountEditPlan(
                    original: editingAccount ?? savedAccount ?? account,
                    updated: account,
                    replacementPassword: password
                )
                if plan.requiresRegistrationTest {
                    step = 2
                    testedSIPAddress = account.sipAddress
                }
                let performedPlan = try phone.editManagedAccount(
                    account,
                    replacing: editingSIPAddress,
                    password: password
                )
                self.editingSIPAddress = account.sipAddress
                if editingAccount == nil { savedAccount = account }
                if !performedPlan.requiresRegistrationTest { dismiss() }
            } else {
                step = 2
                testedSIPAddress = account.sipAddress
                try phone.saveManagedAccountAndTest(account, password: password)
                savedAccount = account
                editingSIPAddress = account.sipAddress
            }
        } catch {
            submissionError = error.localizedDescription
        }
    }

    private func retryRegistrationTest() {
        submissionError = nil
        guard let testedAccount else {
            step = 1
            return
        }
        do {
            try phone.restartManagedAccountRegistrationTest(for: testedAccount)
        } catch {
            submissionError = error.localizedDescription
        }
    }
}
