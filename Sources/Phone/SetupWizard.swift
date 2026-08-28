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

struct ManagedSIPAccount: Codable, Equatable, Sendable {
    var provider: SIPProviderPreset
    var username: String
    var domain: String
    var outboundProxy: String
    var stunServer: String
    var mediaEncryption: String

    var sipAddress: String { "\(username)@\(domain)" }

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

    static func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct SetupWizard: View {
    @ObservedObject var phone: PhoneController
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var provider = SIPProviderPreset.telekom
    @State private var username = ""
    @State private var password = ""
    @State private var domain = SIPProviderPreset.telekom.defaults.domain
    @State private var outboundProxy = SIPProviderPreset.telekom.defaults.outboundProxy
    @State private var stunServer = SIPProviderPreset.telekom.defaults.stunServer
    @State private var mediaEncryption = SIPProviderPreset.telekom.defaults.mediaEncryption
    @State private var submissionError: String?
    @State private var loaded = false
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
        .onAppear(perform: loadStoredAccount)
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
        ManagedSIPAccount(
            provider: provider,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            domain: domain.trimmingCharacters(in: .whitespacesAndNewlines),
            outboundProxy: outboundProxy.trimmingCharacters(in: .whitespacesAndNewlines),
            stunServer: stunServer.trimmingCharacters(in: .whitespacesAndNewlines),
            mediaEncryption: mediaEncryption
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

    private func loadStoredAccount() {
        guard !loaded else { return }
        loaded = true
        guard let stored = phone.managedAccount else { return }
        provider = stored.provider
        username = stored.username
        domain = stored.domain
        outboundProxy = stored.outboundProxy
        stunServer = stored.stunServer
        mediaEncryption = stored.mediaEncryption
        do {
            password = try phone.storedPassword(for: stored)
        } catch {
            submissionError = error.localizedDescription
        }
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
