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
        case .sipgate: ("sipgate.de", "", "", "")
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
            "Du bist die freundliche Telefonrezeption des fiktiven Hotels 'Strandhof' (Demo). Beantworte Fragen zu Verfügbarkeit und Preisen NUR anhand der folgenden Daten, erfinde nichts darüber hinaus. Nimm Reservierungswünsche mit Name und Rückrufnummer entgegen und bestätige sie als vorgemerkt (Demo, keine echte Buchung)."
        case .travelIntake:
            "Du bist der Reise-Anfrage-Assistent eines Reisebüros. Nimm die Anfrage strukturiert auf und frage gezielt nach, bis du hast: Reiseziel/Region, Zeitraum oder Dauer, Anzahl und Alter der Reisenden, Budgetrahmen, Anlass und Vorlieben (z. B. Strand, Aktiv, Kultur), besondere Wünsche, Name und Rückrufnummer. Fasse am Ende alles kurz zusammen und bestätige, dass sich das Büro mit einem Angebot meldet."
        case .custom:
            ""
        }
    }

    func presetContextData(startingAt date: Date, calendar: Calendar = .current) -> String? {
        switch self {
        case .hotelDemo: hotelAvailabilityTable(startingAt: date, calendar: calendar)
        case .personalAssistant, .travelIntake, .custom: nil
        }
    }
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
    var assistantProfile: AssistantProfile = .personalAssistant
    var assistantInstructionsOverride: String? = nil
    var assistantContextData: String? = nil

    init(
        provider: SIPProviderPreset,
        username: String,
        domain: String,
        outboundProxy: String,
        stunServer: String,
        mediaEncryption: String,
        label: String? = nil,
        assistantProfile: AssistantProfile = .personalAssistant,
        assistantInstructionsOverride: String? = nil,
        assistantContextData: String? = nil
    ) {
        self.provider = provider
        self.username = username
        self.domain = domain
        self.outboundProxy = outboundProxy
        self.stunServer = stunServer
        self.mediaEncryption = mediaEncryption
        self.label = label
        self.assistantProfile = assistantProfile
        self.assistantInstructionsOverride = assistantInstructionsOverride
        self.assistantContextData = assistantContextData
    }

    var id: String { sipAddress }
    var sipAddress: String { "\(username)@\(domain)" }
    var displayName: String {
        let value = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? username : value
    }
    var registrationDisplay: String {
        let address = provider == .custom ? sipAddress : username
        return "\(address) · \(provider.shortName)"
    }

    func accountLine(password: String) throws -> String {
        try validate(password: password)
        var parameters = ["auth_pass=\"\(quoted(password))\"", "regint=300"]
        if !outboundProxy.isEmpty { parameters.append("outbound=\"\(quoted(outboundProxy))\"") }
        if !stunServer.isEmpty { parameters.append("stunserver=\(stunServer)") }
        if !mediaEncryption.isEmpty { parameters.append("mediaenc=\(mediaEncryption)") }
        return "<sip:\(sipAddress)>;\(parameters.joined(separator: ";"))\n"
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
    }

    private func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
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
        case assistantProfile
        case assistantInstructionsOverride
        case assistantContextData
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
        assistantProfile = try container.decodeIfPresent(AssistantProfile.self, forKey: .assistantProfile) ?? .personalAssistant
        assistantInstructionsOverride = try container.decodeIfPresent(String.self, forKey: .assistantInstructionsOverride)
        assistantContextData = try container.decodeIfPresent(String.self, forKey: .assistantContextData)
    }
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
        self.activeSIPAddress = unique.contains { $0.sipAddress == activeSIPAddress } ? activeSIPAddress : unique.first?.sipAddress
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

    mutating func remove(_ account: ManagedSIPAccount) {
        accounts.removeAll { $0.sipAddress == account.sipAddress }
        if activeSIPAddress == account.sipAddress {
            activeSIPAddress = accounts.first?.sipAddress
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
    case activeCall
    case invalidProviderSettings
    case invalidUsername
    case invalidPassword
    case keychain(OSStatus)
    case missingDomain
    case missingManagedAccount
    case missingPassword
    case missingStoredPassword
    case missingUsername

    var errorDescription: String? {
        switch self {
        case .activeCall: "Finish the current call before changing the SIP account."
        case .invalidProviderSettings: "The provider settings contain unsupported characters."
        case .invalidUsername: "Enter a username without spaces, @, or SIP punctuation."
        case .invalidPassword: "The password cannot contain a line break."
        case .keychain(let status):
            SecCopyErrorMessageString(status, nil).map { ($0 as NSString) as String } ?? "The password could not be saved in Keychain."
        case .missingDomain: "Enter the SIP registrar."
        case .missingManagedAccount: "The managed SIP account is missing."
        case .missingPassword: "Enter the SIP password."
        case .missingStoredPassword: "The SIP password is missing from Keychain."
        case .missingUsername: "Enter the phone number or SIP username."
        }
    }
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
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var provider = SIPProviderPreset.telekom
    @State private var label = ""
    @State private var username = ""
    @State private var password = ""
    @State private var domain = SIPProviderPreset.telekom.defaults.domain
    @State private var outboundProxy = SIPProviderPreset.telekom.defaults.outboundProxy
    @State private var stunServer = SIPProviderPreset.telekom.defaults.stunServer
    @State private var mediaEncryption = SIPProviderPreset.telekom.defaults.mediaEncryption
    @State private var submissionError: String?
    @FocusState private var focusedField: Field?

    private enum Field {
        case username
        case password
        case registrar
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
        .frame(width: 620, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reset)
    }

    private var wizardHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up your SIP account")
                    .font(.title2.weight(.semibold))
                Text("Connect Phone directly to your provider or local router.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                ForEach(Array(["Provider", "Credentials", "Test"].enumerated()), id: \.offset) { index, title in
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.16))
                                .frame(width: 24, height: 24)
                            if index < step {
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
        if provider == .custom {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connection details")
                    .font(.subheadline.weight(.semibold))
                setupField("Registrar", text: $domain, prompt: "sip.example.com")
                setupField("Outbound proxy", text: $outboundProxy, prompt: "Optional")
                setupField("STUN server", text: $stunServer, prompt: "Optional")
                Picker("Media encryption", selection: $mediaEncryption) {
                    Text("None required").tag("")
                    Text("SRTP preferred").tag("srtp")
                    Text("SRTP required").tag("srtp-mand")
                }
            }
            .padding(16)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if provider == .fritzBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Router address")
                    .font(.subheadline.weight(.semibold))
                TextField("fritz.box", text: $domain)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .registrar)
                Text("Use the local hostname or IP address of the router where the IP phone is configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            VStack(spacing: 8) {
                configurationRow("Registrar", value: domain)
                configurationRow("Outbound proxy", value: outboundProxy.isEmpty ? "Automatic" : outboundProxy)
                configurationRow("STUN", value: stunServer.isEmpty ? "Not used" : stunServer)
                configurationRow("Media encryption", value: mediaEncryption.isEmpty ? "Provider default" : mediaEncryption)
            }
            .padding(14)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var credentialsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Enter your credentials")
                    .font(.headline)
                Text("The password is stored in your login Keychain and is never saved with the account settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 14) {
                setupField("Label", text: $label, prompt: "Optional, for example Private or Work")
                setupField("Number or username", text: $username, prompt: provider == .telekom ? "+49…" : "SIP username")
                    .focused($focusedField, equals: .username)
                LabeledContent("Password") {
                    SecureField("Required", text: $password)
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
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.green)
                Text(username.isEmpty || domain.isEmpty ? "Your SIP address will appear here." : "SIP address: \(username)@\(domain)")
                    .font(.callout)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(28)
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
                Button("Test again", action: startRegistrationTest)
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
                Button("Test registration", action: startRegistrationTest)
                    .buttonStyle(.borderedProminent)
                    .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else if displayedStatus == .registered {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var account: ManagedSIPAccount {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return ManagedSIPAccount(
            provider: provider,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            domain: domain.trimmingCharacters(in: .whitespacesAndNewlines),
            outboundProxy: outboundProxy.trimmingCharacters(in: .whitespacesAndNewlines),
            stunServer: stunServer.trimmingCharacters(in: .whitespacesAndNewlines),
            mediaEncryption: mediaEncryption,
            label: trimmedLabel.isEmpty ? nil : trimmedLabel
        )
    }

    private var displayedStatus: RegistrationStatus {
        submissionError.map { .failed($0) } ?? phone.registrationStatus
    }

    private var statusTitle: String {
        switch displayedStatus {
        case .idle: "Ready to test"
        case .registering: "Registering …"
        case .registered: "Phone is registered"
        case .failed: "Registration failed"
        }
    }

    private var statusDetail: String {
        switch displayedStatus {
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
        applyPreset(value)
    }

    private func reset() {
        step = 0
        provider = .telekom
        label = ""
        username = ""
        password = ""
        submissionError = nil
        applyPreset(.telekom)
        focusedField = nil
    }

    private func startRegistrationTest() {
        submissionError = nil
        step = 2
        let account = account
        let password = password
        Task { @MainActor in
            do {
                try phone.saveManagedAccountAndTest(account, password: password)
            } catch {
                submissionError = error.localizedDescription
            }
        }
    }
}
