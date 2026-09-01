import AppKit
import SwiftUI

struct PhonePanel: View {
    @ObservedObject var phone: PhoneController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @FocusState private var numberFieldFocused: Bool
    @State private var showKeypad = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            callControls
            if phone.state.isReady && !phone.history.isEmpty {
                Divider().opacity(0.45)
                historySection
            }
            if !phone.transcript.isEmpty || phone.summary != nil {
                Divider().opacity(0.45)
                conversationPreview
            }
            Divider().opacity(0.45)
            footer
        }
        .frame(width: 380)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: phone.state.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, isActive: phone.state.isRinging)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(phone.callStateLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                PhoneAccountPicker(phone: phone)
                Text(phone.activityStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(phone.geminiLiveState == .off && !phone.isAutoAnswerArmed && !phone.isAssistantCallActive ? Color.secondary.opacity(0.7) : Color.purple)
                    .lineLimit(1)
            }
            Spacer()
            if phone.callStartedAt != nil {
                CallDuration(startedAt: phone.callStartedAt)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var callControls: some View {
        VStack(spacing: 12) {
            if phone.state.isReady {
                HStack(spacing: 8) {
                    TextField("Phone number or SIP address", text: $phone.number)
                        .textFieldStyle(.plain)
                        .focusEffectDisabled()
                        .focused($numberFieldFocused)
                        .font(.system(size: 15, design: .rounded))
                        .onSubmit { phone.dial() }
                    Button(action: phone.dial) {
                        Image(systemName: "phone.fill")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .tint(.green)
                    .help("Call")

                    AssistantDialButton(phone: phone)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.primary.opacity(0.055))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(numberFieldFocused ? Color.accentColor.opacity(0.65) : .clear, lineWidth: 1)
                }
            } else if phone.state.isRinging {
                HStack(spacing: 10) {
                    actionButton("Decline", symbol: "phone.down.fill", color: .red, action: phone.reject)
                    actionButton("Answer", symbol: "phone.fill", color: .green, action: phone.answer)
                }
            } else if phone.state.isInCall {
                HStack(spacing: 10) {
                    Button(action: phone.toggleMute) {
                        Image(systemName: phone.isMuted ? "mic.slash.fill" : "mic.fill")
                            .fontWeight(.semibold)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .tint(phone.isMuted ? .orange : nil)
                    .disabled(!phone.state.isConnected)
                    .help(phone.isMuted ? "Unmute" : "Mute")

                    if phone.isGeminiConfigured {
                        Button(action: phone.toggleGeminiLive) {
                            Image(systemName: "sparkles")
                                .fontWeight(.semibold)
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                        .tint(phone.isGeminiLiveActive ? .purple : nil)
                        .disabled(!phone.state.isConnected)
                        .help(phone.isGeminiLiveActive ? "Stop Assistant" : "Start Assistant")
                    }

                    Button(action: phone.hangup) {
                        Label("Hang up", systemImage: "phone.down.fill")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)

                    Button {
                        showKeypad.toggle()
                    } label: {
                        Image(systemName: "circle.grid.3x3.fill")
                            .fontWeight(.semibold)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .disabled(!phone.state.isConnected)
                    .help("Keypad")
                }
                if showKeypad && phone.state.isConnected {
                    DTMFKeypad(phone: phone)
                }
            } else if case .error = phone.state {
                Button("Back to dialing", action: phone.recoverFromError)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            } else if phone.state == .stopped {
                if phone.managedAccounts.isEmpty && phone.unmanagedAccountAOR == nil {
                    // Starting a phone with no line ends in an error message;
                    // the setup assistant is the only useful next step.
                    Button("Set up a line", action: phone.requestAccountSetup)
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                } else {
                    Button("Start phone", action: phone.toggleBaresip)
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                }
            } else {
                ProgressView("Registering with the provider …")
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Clear") { phone.clearHistory() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            ForEach(phone.history.prefix(4)) { record in
                Button {
                    if let peer = record.peer {
                        phone.number = peer
                        phone.dial()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: record.direction == .incoming
                              ? "arrow.down.left"
                              : "arrow.up.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(record.missed ? .red : .secondary)
                            .frame(width: 14)
                        Text(phone.displayName(for: record.peer) ?? record.peer ?? "Unknown")
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                        Text(record.date, format: .relative(presentation: .named))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(record.peer.map { "Call \($0)" } ?? "Caller unknown")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The panel has room for a few lines only, so the labelled summary is
    /// flattened into one readable run of text instead of a field list.
    private func summaryPreviewText(_ summary: CallSummary) -> String {
        let sections = parseCallSummary(summary.text)
        guard !sections.isEmpty else { return strippingMarkdownEmphasis(summary.text) }
        return sections.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }

    private var conversationPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(phone.summary == nil ? "Live transcript" : "Conversation")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Open") { NotificationCenter.default.post(name: .phoneOpenLibrary, object: nil) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            if let summary = phone.summary {
                Text(summaryPreviewText(summary))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            } else {
                ForEach(phone.transcript.suffix(2)) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label(
                            entry.speakerTitle,
                            systemImage: entry.isAssistant ? "sparkles" : (entry.speaker == .me ? "person.fill" : "phone.fill")
                        )
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(entry.isAssistant ? .orange : (entry.speaker == .me ? .blue : .purple))
                        .frame(width: 72, alignment: .leading)
                        Text(entry.text)
                            .font(.system(size: 12))
                            .foregroundStyle(entry.isFinal ? .primary : .secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    openWindow(id: "library")
                    NSApp.activate(ignoringOtherApps: true)
                }
            } label: {
                Image(systemName: "rectangle.stack")
            }
            .buttonStyle(.plain)
            .help("Open call library")

            Button {
                // From the menu bar popover, the settings window only opens
                // reliably once the app is active and the popover has closed.
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")

            Button {
                phone.openRuntimeConfig()
            } label: {
                Image(systemName: "wrench.and.screwdriver")
            }
            .buttonStyle(.plain)
            .help("Open technical configuration")

            Spacer()

            Button("Quit", action: phone.quit)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func actionButton(_ title: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .controlSize(.large)
    }

    private var statusColor: Color {
        switch phone.state {
        case .error: .orange
        case .starting: .yellow
        case .ringing: .green
        case .dialing, .answering, .connected: .blue
        case .ready: .green
        case .stopped: .secondary
        }
    }
}

struct PhoneSettingsView: View {
    @ObservedObject var phone: PhoneController
    @AppStorage("transcriptionEnabled") private var transcriptionEnabled = true
    @AppStorage(useSystemContactsDefaultsKey) private var useSystemContacts = true
    @AppStorage("retainTranscript") private var retainTranscript = true
    @AppStorage("archiveConversations") private var archiveConversations = true
    @AppStorage("transcriptionLocale") private var transcriptionLocale = ""
    @AppStorage("transcriptionEngine") private var transcriptionEngine = TranscriptionEngine.apple.rawValue
    @AppStorage("transcriptionSmartMode") private var transcriptionSmartMode = false
    @AppStorage("showDockIcon") private var showDockIcon = false
    @AppStorage("geminiLiveModel") private var geminiLiveModel = defaultGeminiLiveModel
    @AppStorage("assistantInstructions") private var assistantInstructions = defaultAssistantInstructions
    @AppStorage("assistantUserDisplayName") private var assistantUserDisplayName = ""
    @AppStorage("webhookURL") private var webhookURL = ""
    @AppStorage("webhookCallEvents") private var webhookCallEvents = true
    @AppStorage("webhookContentEvents") private var webhookContentEvents = false
    @State private var geminiAPIKey = ""
    @State private var geminiSettingsMessage: String?
    @State private var webhookSecret = ""
    @State private var webhookSecretConfigured = false
    @State private var webhookSettingsMessage: String?
    @State private var selectedAccountAddress: String?
    @State private var accountToEdit: ManagedSIPAccount?
    @State private var accountToRemove: ManagedSIPAccount?
    @State private var accountToRename: ManagedSIPAccount?
    @State private var renameLabel = ""
    @State private var accountError: String?
    @State private var showsAccountInstructions = false
    @State private var showsAccountData = false
    @State private var isNamingNewProfile = false
    @State private var newProfileName = ""
    @State private var profileToDelete: SavedAssistantProfile?
    @State private var isConfirmingArchiveDeletion = false

    private enum AssistantProfileSelection: Hashable {
        case builtIn(AssistantProfile)
        case saved(UUID)
    }

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("General", systemImage: "gearshape") }

            phoneSettings
                .tabItem { Label("Lines", systemImage: "simcard") }

            assistantSettings
                .tabItem { Label("Assistant", systemImage: "sparkles") }

            transcriptionSettings
                .tabItem { Label("Transcription", systemImage: "text.bubble") }

            automationSettings
                .tabItem { Label("Automation", systemImage: "bolt.horizontal") }
        }
        .frame(width: 560, height: 620)
        .alert(
            accountToRemove.map { "Remove \($0.displayName)?" } ?? "Remove account?",
            isPresented: isConfirmingRemoval
        ) {
            Button("Remove Account", role: .destructive, action: removeSelectedAccount)
            Button("Cancel", role: .cancel) { accountToRemove = nil }
        } message: {
            Text("Its password will also be removed from Keychain.")
        }
        .alert("Rename account", isPresented: isRenamingAccount) {
            TextField("Label", text: $renameLabel)
            Button("Save", action: saveAccountRename)
            Button("Cancel", role: .cancel) { accountToRename = nil }
        } message: {
            Text("Enter a local label for this account.")
        }
        .alert("Delete all archived conversations?", isPresented: $isConfirmingArchiveDeletion) {
            Button("Delete All", role: .destructive) {
                Task { await phone.deleteAllArchivedConversations() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes all locally archived transcripts, summaries, and call metadata. Recent calls in the menu bar are unaffected.")
        }
        .alert("Save as new profile", isPresented: $isNamingNewProfile) {
            TextField("Profile name", text: $newProfileName)
            Button("Save", action: saveAsNewProfile)
                .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { newProfileName = "" }
        } message: {
            Text("The current instructions and data will be available to every SIP account.")
        }
        .alert("Delete saved profile?", isPresented: isDeletingSavedProfile) {
            Button("Delete Profile", role: .destructive, action: deleteSavedProfile)
            Button("Cancel", role: .cancel) { profileToDelete = nil }
        } message: {
            Text("Accounts using this profile will keep a private copy of its instructions.")
        }
        .sheet(item: $accountToEdit) { account in
            SetupWizard(phone: phone, editing: account)
        }
        .onChange(of: useSystemContacts) { _, _ in
            phone.systemContactsSettingDidChange()
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Show the app in the Dock and app switcher", isOn: $showDockIcon)
            if showDockIcon != (NSApp.activationPolicy() == .regular) {
                Text("Takes effect after restarting Phone.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            Toggle("Use macOS Contacts for caller names", isOn: $useSystemContacts)
            Text("Contacts access is requested only when you first look up a caller or search for a contact.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Archive conversations on this Mac", isOn: $archiveConversations)
            Text("When enabled, final transcripts and summaries are stored locally on this Mac. Call metadata is always kept in the library.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Delete all archived conversations", role: .destructive) {
                isConfirmingArchiveDeletion = true
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Transcribe calls live", isOn: $transcriptionEnabled)
            Toggle("Keep the last transcript after hanging up", isOn: $retainTranscript)
                .disabled(!transcriptionEnabled)

            Picker("Transcription engine", selection: $transcriptionEngine) {
                Text("Apple (on-device)").tag(TranscriptionEngine.apple.rawValue)
                Text("Gemini (cloud)").tag(TranscriptionEngine.gemini.rawValue)
            }
            .disabled(!transcriptionEnabled)

            Toggle("Smart formatting (remove filler words)", isOn: $transcriptionSmartMode)
                .disabled(!transcriptionEnabled || transcriptionEngine != TranscriptionEngine.gemini.rawValue)

            Picker("Language", selection: $transcriptionLocale) {
                Text("System (\(Locale.current.identifier))").tag("")
                Text("Deutsch").tag("de-DE")
                Text("English (US)").tag("en-US")
                Text("English (UK)").tag("en-GB")
                Text("Français").tag("fr-FR")
                Text("Español").tag("es-ES")
                Text("Italiano").tag("it-IT")
            }
            .disabled(!transcriptionEnabled || transcriptionEngine != TranscriptionEngine.apple.rawValue)

            Divider()

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(transcriptionEngine == TranscriptionEngine.gemini.rawValue ? "Gemini cloud transcription" : "Processing on this Mac")
                        .fontWeight(.medium)
                    Text(
                        transcriptionEngine == TranscriptionEngine.gemini.rawValue
                            ? "Live call audio is sent to Gemini for transcription. Summaries still use the configured local or Gemini fallback path."
                            : "Transcription and summaries stay on this Mac. The assistant has its own settings in the Assistant tab."
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Two tabs, sorted by what the user wants rather than by technology:
    /// "who speaks for me" and "what is written down" are separate decisions
    /// even though both happen to run through a model.
    private var transcriptionSettings: some View {
        ScrollView {
            transcriptionSection
                .padding(24)
        }
    }

    private var assistantSettings: some View {
        ScrollView {
            assistantBridgeSection
                .padding(24)
        }
    }

    private var knownGeminiModels: [String] { [defaultGeminiLiveModel, "gemini-3.5-live-translate-preview"] }

    private var isCustomModel: Bool {
        !geminiLiveModel.isEmpty && !knownGeminiModels.contains(geminiLiveModel)
    }

    private var modelChoice: Binding<String> {
        Binding(
            get: {
                let value = geminiLiveModel.isEmpty ? defaultGeminiLiveModel : geminiLiveModel
                return knownGeminiModels.contains(value) ? value : "custom"
            },
            set: { choice in
                if choice == "custom" {
                    if knownGeminiModels.contains(geminiLiveModel) || geminiLiveModel.isEmpty { geminiLiveModel = " " }
                } else {
                    geminiLiveModel = choice == defaultGeminiLiveModel ? "" : choice
                }
            }
        )
    }

    private var assistantBridgeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Assistant")
                        .font(.headline)
                    Text("The assistant answers and places calls on your lines through Google Gemini Live. While it is on a call, the caller's audio is streamed to Google and the assistant's voice is sent back into the call.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LabeledContent("API key") {
                    SecureField(phone.isGeminiConfigured ? "Configured" : "Required", text: $geminiAPIKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                }

                LabeledContent("Model") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Picker("", selection: modelChoice) {
                            Text("Assistant · gemini-3.1-flash-live-preview").tag(defaultGeminiLiveModel)
                            Text("Live translation · gemini-3.5-live-translate-preview").tag("gemini-3.5-live-translate-preview")
                            Text("Custom …").tag("custom")
                        }
                        .labelsHidden()
                        .frame(maxWidth: 300)
                        if isCustomModel {
                            TextField("model id", text: $geminiLiveModel)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 300)
                        }
                    }
                }

                HStack {
                    Button("Save API Key", action: saveGeminiAPIKey)
                        .disabled(geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let geminiSettingsMessage {
                        Text(geminiSettingsMessage)
                            .font(.caption)
                            .foregroundStyle(geminiSettingsMessage == "API key saved." ? .green : .orange)
                    } else if phone.isGeminiConfigured {
                        Text("An API key is configured.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Label {
                    Text("Which profile answers on a line, when it answers, and after how long is set per line in the Lines tab — each number can behave differently.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "simcard")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Your name (for call handover)") {
                    TextField("Optional", text: $assistantUserDisplayName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Default assistant instructions")
                        .fontWeight(.medium)
                    TextEditor(text: $assistantInstructions)
                        .font(.system(size: 12))
                        .frame(minHeight: 100)
                        .padding(5)
                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    Text("Used by lines set to the Personal assistant profile. A line with its own profile ignores this text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Label {
                    Text("During any call, the sparkles button starts or stops the assistant by hand. Transcription is configured separately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(.purple)
                }
        }
        .onAppear { phone.refreshAssistantConfiguration() }
    }

    private var phoneSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("SIP accounts")
                    .font(.headline)

                if let summary = phone.registrationSummary {
                    Label(summary, systemImage: phone.registrationStatus == .registered ? "checkmark.circle.fill" : "network")
                        .font(.caption)
                        .foregroundStyle(phone.registrationStatus == .registered ? .green : .secondary)
                }

                if phone.managedAccounts.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Manual account file", systemImage: "doc.text")
                            .fontWeight(.medium)
                        if let address = phone.unmanagedAccountAOR {
                            Text(address)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Text("This account is managed through the technical configuration.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    List(selection: $selectedAccountAddress) {
                        ForEach(phone.managedAccounts) { account in
                            accountRow(account)
                                .tag(account.sipAddress)
                        }
                    }
                    .listStyle(.bordered)
                    .frame(height: 155)
                }

                HStack(spacing: 8) {
                    Button {
                        phone.requestAccountSetup()
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Add account")

                    Button {
                        accountToEdit = selectedAccount
                    } label: {
                        Image(systemName: "pencil")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(selectedAccount == nil)
                    .help("Edit selected account")

                    Button {
                        accountToRemove = selectedAccount
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(selectedAccount == nil)
                    .help("Remove selected account")

                    Spacer()
                    if let accountError {
                        Text(accountError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    } else {
                        Text(phone.managedAccounts.isEmpty ? "Add an account with the setup assistant." : "Passwords are stored in Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let account = selectedAccount {
                    accountProfileEditor(account)
                }
            }
            .padding(20)
        }
        .onAppear {
            selectedAccountAddress = phone.activeManagedSIPAddress
        }
        .onChange(of: phone.activeManagedSIPAddress) { _, address in
            if selectedAccountAddress == nil { selectedAccountAddress = address }
        }
        .onChange(of: phone.managedAccounts) { _, accounts in
            if !accounts.contains(where: { $0.sipAddress == selectedAccountAddress }) {
                selectedAccountAddress = phone.activeManagedSIPAddress
            }
        }
    }

    private var automationSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Webhook delivery")
                    .font(.headline)
                Text("Send selected Phone events to one HTTPS or HTTP endpoint as signed JSON.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Webhook URL") {
                TextField("https://example.com/phone", text: $webhookURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 330)
            }

            LabeledContent("Shared secret") {
                SecureField(webhookSecretConfigured ? "Configured" : "Required", text: $webhookSecret)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 330)
            }

            HStack {
                Button("Save Shared Secret", action: saveWebhookSecret)
                    .disabled(webhookSecret.isEmpty)
                if let webhookSettingsMessage {
                    Text(webhookSettingsMessage)
                        .font(.caption)
                        .foregroundStyle(webhookSettingsMessage == "Shared secret saved." ? .green : .orange)
                } else if webhookSecretConfigured {
                    Text("A shared secret is configured in Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Toggle("Call events", isOn: $webhookCallEvents)
            Text("Incoming, outgoing, answered, hangup, and DTMF events include call metadata.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)

            Toggle("Transcript & summary events", isOn: $webhookContentEvents)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text("Privacy: enabling this sends finalized transcript text and call summaries off this Mac to the webhook endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Label("Requests are signed with HMAC-SHA256 in the X-Phone-Signature header.", systemImage: "signature")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .onAppear {
            webhookSecretConfigured = PhoneWebhookSecretStore.secret() != nil
        }
    }

    private var selectedAccount: ManagedSIPAccount? {
        phone.managedAccounts.first { $0.sipAddress == selectedAccountAddress }
    }

    private var isConfirmingRemoval: Binding<Bool> {
        Binding(
            get: { accountToRemove != nil },
            set: { if !$0 { accountToRemove = nil } }
        )
    }

    private var isRenamingAccount: Binding<Bool> {
        Binding(
            get: { accountToRename != nil },
            set: { if !$0 { accountToRename = nil } }
        )
    }

    private var isDeletingSavedProfile: Binding<Bool> {
        Binding(
            get: { profileToDelete != nil },
            set: { if !$0 { profileToDelete = nil } }
        )
    }

    private func accountRow(_ account: ManagedSIPAccount) -> some View {
        let isActive = phone.activeManagedSIPAddress == account.sipAddress
        let isOnCall = phone.isOnCurrentCall(account)
        return HStack(spacing: 10) {
            Toggle("", isOn: enabledBinding(for: account))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(isOnCall)
                .help(
                    isOnCall
                        ? "This line is on a call"
                        : account.isEnabled ? "Online — registered with the provider" : "Offline — not registered"
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .fontWeight(.medium)
                Text(account.isEnabled ? account.sipAddress : "\(account.sipAddress) · Offline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if account.isEnabled {
                registrationIndicator(for: account)
            }
            Text(phone.assistantProfileDisplay(for: account))
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.purple.opacity(0.12), in: Capsule())
                .foregroundStyle(.purple)
            Text(account.provider.shortName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                selectAccount(account)
            } label: {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!account.isEnabled)
            .help(isActive ? "Outgoing calls use this line" : "Use this line for outgoing calls")
            Button {
                accountToEdit = account
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Edit account")
            Button {
                accountToRemove = account
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove account")
        }
        .opacity(account.isEnabled ? 1 : 0.55)
        .onTapGesture(count: 2) {
            selectedAccountAddress = account.sipAddress
            accountToEdit = account
        }
        .contextMenu {
            Button(account.isEnabled ? "Take Offline" : "Take Online") {
                selectedAccountAddress = account.sipAddress
                setAccountEnabled(account, isEnabled: !account.isEnabled)
            }
            .disabled(phone.isOnCurrentCall(account))
            Divider()
            Button("Rename…") {
                selectedAccountAddress = account.sipAddress
                renameLabel = account.label ?? ""
                accountToRename = account
            }
            Button("Edit…") {
                selectedAccountAddress = account.sipAddress
                accountToEdit = account
            }
            Button("Remove…", role: .destructive) {
                selectedAccountAddress = account.sipAddress
                accountToRemove = account
            }
        }
    }


    private func enabledBinding(for account: ManagedSIPAccount) -> Binding<Bool> {
        Binding(
            get: { account.isEnabled },
            set: { setAccountEnabled(account, isEnabled: $0) }
        )
    }

    private func setAccountEnabled(_ account: ManagedSIPAccount, isEnabled: Bool) {
        do {
            accountError = nil
            try phone.setManagedAccountEnabled(account, isEnabled: isEnabled)
        } catch {
            accountError = error.localizedDescription
        }
    }

    @ViewBuilder
    private func registrationIndicator(for account: ManagedSIPAccount) -> some View {
        switch phone.registrationStatus(for: account) {
        case .idle:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .registering:
            ProgressView()
                .controlSize(.small)
        case .registered:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .help(message)
        }
    }

    private func accountProfileEditor(_ account: ManagedSIPAccount) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Assistant profile", selection: profileSelectionBinding(for: account)) {
                    Section("Built-in profiles") {
                        ForEach(AssistantProfile.allCases) { profile in
                            Text(profile.displayName)
                                .tag(AssistantProfileSelection.builtIn(profile))
                        }
                    }
                    if !phone.savedAssistantProfiles.isEmpty {
                        Section("Saved profiles") {
                            ForEach(phone.savedAssistantProfiles) { profile in
                                Text(profile.name)
                                    .tag(AssistantProfileSelection.saved(profile.id))
                            }
                        }
                    }
                }

                Divider()

                Picker("Answer incoming calls", selection: answerModeBinding(for: account)) {
                    Text("Never").tag(AssistantAnswerMode.never)
                    Text("Always").tag(AssistantAnswerMode.always)
                    Text("Outside business hours").tag(AssistantAnswerMode.outsideBusinessHours)
                }

                if (selectedAccount ?? account).assistantAnswerMode == .outsideBusinessHours {
                    BusinessHoursRow(title: "Weekdays", group: accountBusinessHoursBinding(for: account, \.weekdays))
                    BusinessHoursRow(title: "Weekend", group: accountBusinessHoursBinding(for: account, \.weekend))
                }

                Stepper(
                    "Answer after \((selectedAccount ?? account).assistantAnswerDelay) seconds",
                    value: answerDelayBinding(for: account),
                    in: 0...30
                )
                .disabled((selectedAccount ?? account).assistantAnswerMode == .never)

                Divider()

                DisclosureGroup("Edit instructions…", isExpanded: $showsAccountInstructions) {
                    VStack(alignment: .trailing, spacing: 6) {
                        TextEditor(text: instructionsBinding(for: account))
                            .font(.system(size: 12))
                            .frame(minHeight: 95)
                            .padding(5)
                            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                        Button("Reset to preset") {
                            resetInstructions(for: account)
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 6)
                }

                DisclosureGroup("Edit data…", isExpanded: $showsAccountData) {
                    VStack(alignment: .trailing, spacing: 6) {
                        TextEditor(text: contextDataBinding(for: account))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 110)
                            .padding(5)
                            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                        Button("Reset to preset") {
                            resetContextData(for: account)
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 6)
                }

                HStack {
                    Button("Save as new profile…") {
                        newProfileName = ""
                        isNamingNewProfile = true
                    }
                    if let profile = phone.savedAssistantProfile(
                        id: (selectedAccount ?? account).savedProfileID
                    ) {
                        Button("Delete profile", role: .destructive) {
                            profileToDelete = profile
                        }
                    }
                }
                .controlSize(.small)
            }
        } label: {
            Text("Assistant for \(account.displayName)")
        }
    }

    private func profileSelectionBinding(for account: ManagedSIPAccount) -> Binding<AssistantProfileSelection> {
        Binding(
            get: {
                let current = selectedAccount ?? account
                if let id = current.savedProfileID,
                   phone.savedAssistantProfile(id: id) != nil {
                    return .saved(id)
                }
                return .builtIn(current.assistantProfile)
            },
            set: { selection in
                switch selection {
                case .builtIn(let profile):
                    updateAccount(account) {
                        $0.assistantProfile = profile
                        $0.assistantProfileName = nil
                        $0.savedProfileID = nil
                        $0.assistantInstructionsOverride = nil
                        $0.assistantContextData = nil
                    }
                case .saved(let id):
                    updateAccount(account) {
                        $0.assistantProfile = .custom
                        $0.savedProfileID = id
                    }
                }
            }
        )
    }

    private func answerModeBinding(for account: ManagedSIPAccount) -> Binding<AssistantAnswerMode> {
        Binding(
            get: { (selectedAccount ?? account).assistantAnswerMode },
            set: { value in updateAccount(account) { $0.assistantAnswerMode = value } }
        )
    }

    private func answerDelayBinding(for account: ManagedSIPAccount) -> Binding<Int> {
        Binding(
            get: { (selectedAccount ?? account).assistantAnswerDelay },
            set: { value in
                updateAccount(account) { $0.assistantAnswerDelay = ManagedSIPAccount.clampedAnswerDelay(value) }
            }
        )
    }

    private func accountBusinessHoursBinding(
        for account: ManagedSIPAccount,
        _ keyPath: WritableKeyPath<BusinessHoursSchedule, BusinessHoursSchedule.DayGroup>
    ) -> Binding<BusinessHoursSchedule.DayGroup> {
        Binding(
            get: { (selectedAccount ?? account).businessHours[keyPath: keyPath] },
            set: { value in
                updateAccount(account) { $0.businessHours[keyPath: keyPath] = value }
            }
        )
    }

    private func instructionsBinding(for account: ManagedSIPAccount) -> Binding<String> {
        Binding(
            get: {
                let current = selectedAccount ?? account
                return phone.savedAssistantProfile(id: current.savedProfileID)?.instructions
                    ?? current.assistantInstructionsOverride
                    ?? current.assistantProfile.presetInstructions(globalFallback: assistantInstructions)
            },
            set: { value in
                let current = selectedAccount ?? account
                if let id = current.savedProfileID {
                    updateSavedProfile(id: id) { $0.instructions = value }
                } else {
                    updateAccount(account) { $0.assistantInstructionsOverride = value }
                }
            }
        )
    }

    private func contextDataBinding(for account: ManagedSIPAccount) -> Binding<String> {
        Binding(
            get: {
                let current = selectedAccount ?? account
                return phone.savedAssistantProfile(id: current.savedProfileID)?.contextData
                    ?? current.assistantContextData
                    ?? current.assistantProfile.presetContextData(startingAt: Date())
                    ?? ""
            },
            set: { value in
                let current = selectedAccount ?? account
                if let id = current.savedProfileID {
                    updateSavedProfile(id: id) { $0.contextData = value }
                } else {
                    updateAccount(account) { $0.assistantContextData = value }
                }
            }
        )
    }

    private func resetInstructions(for account: ManagedSIPAccount) {
        let current = selectedAccount ?? account
        if let id = current.savedProfileID {
            updateSavedProfile(id: id) { $0.instructions = "" }
        } else {
            updateAccount(account) { $0.assistantInstructionsOverride = nil }
        }
    }

    private func resetContextData(for account: ManagedSIPAccount) {
        let current = selectedAccount ?? account
        if let id = current.savedProfileID {
            updateSavedProfile(id: id) { $0.contextData = nil }
        } else {
            updateAccount(account) { $0.assistantContextData = nil }
        }
    }

    private func updateSavedProfile(
        id: UUID,
        change: (inout SavedAssistantProfile) -> Void
    ) {
        accountError = nil
        do {
            try phone.updateSavedAssistantProfile(id: id, change: change)
        } catch {
            accountError = error.localizedDescription
        }
    }

    private func saveAsNewProfile() {
        guard let account = selectedAccount else { return }
        let instructions = instructionsBinding(for: account).wrappedValue
        let context = contextDataBinding(for: account).wrappedValue
        accountError = nil
        do {
            try phone.saveNewAssistantProfile(
                name: newProfileName,
                instructions: instructions,
                contextData: context.isEmpty ? nil : context,
                for: account
            )
            newProfileName = ""
        } catch {
            accountError = error.localizedDescription
        }
    }

    private func deleteSavedProfile() {
        guard let profile = profileToDelete else { return }
        profileToDelete = nil
        accountError = nil
        do {
            try phone.deleteSavedAssistantProfile(id: profile.id)
        } catch {
            accountError = error.localizedDescription
        }
    }

    private func updateAccount(_ account: ManagedSIPAccount, change: (inout ManagedSIPAccount) -> Void) {
        var updated = selectedAccount ?? account
        change(&updated)
        accountError = nil
        do {
            try phone.updateManagedAccountMetadata(updated)
        } catch {
            accountError = error.localizedDescription
        }
    }

    private func saveGeminiAPIKey() {
        geminiSettingsMessage = nil
        do {
            try phone.saveGeminiAPIKey(geminiAPIKey)
            geminiAPIKey = ""
            geminiSettingsMessage = "API key saved."
        } catch {
            geminiSettingsMessage = error.localizedDescription
        }
    }

    private func saveWebhookSecret() {
        webhookSettingsMessage = nil
        do {
            try PhoneWebhookSecretStore.save(webhookSecret)
            webhookSecret = ""
            webhookSecretConfigured = true
            webhookSettingsMessage = "Shared secret saved."
        } catch {
            webhookSettingsMessage = error.localizedDescription
        }
    }

    private func selectAccount(_ account: ManagedSIPAccount) {
        selectedAccountAddress = account.sipAddress
        accountError = nil
        do {
            try phone.selectManagedAccount(account)
        } catch {
            accountError = error.localizedDescription
        }
    }

    private func saveAccountRename() {
        guard let account = accountToRename else { return }
        var updated = phone.managedAccounts.first(where: { $0.sipAddress == account.sipAddress }) ?? account
        let trimmedLabel = renameLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.label = trimmedLabel.isEmpty ? nil : trimmedLabel
        accountError = nil
        do {
            try phone.updateManagedAccountMetadata(updated)
            accountToRename = nil
        } catch {
            accountError = error.localizedDescription
        }
    }

    private func removeSelectedAccount() {
        guard let account = accountToRemove else { return }
        accountToRemove = nil
        accountError = nil
        do {
            try phone.removeManagedAccount(account)
            selectedAccountAddress = phone.activeManagedSIPAddress
        } catch {
            accountError = error.localizedDescription
        }
    }
}

private struct BusinessHoursRow: View {
    let title: String
    @Binding var group: BusinessHoursSchedule.DayGroup

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 70, alignment: .leading)
            Toggle("Attended", isOn: $group.open)
                .toggleStyle(.checkbox)
            Spacer()
            HStack(spacing: 5) {
                Text("From")
                DatePicker("Start", selection: timeBinding(\.start), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .accessibilityLabel("\(title) start")
                Text("to")
                DatePicker("End", selection: timeBinding(\.end), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .accessibilityLabel("\(title) end")
            }
            .disabled(!group.open)
        }
    }

    private func timeBinding(_ keyPath: WritableKeyPath<BusinessHoursSchedule.DayGroup, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = group[keyPath: keyPath]
                return Calendar.current.date(
                    bySettingHour: minutes / 60,
                    minute: minutes % 60,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                group[keyPath: keyPath] = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }
}
