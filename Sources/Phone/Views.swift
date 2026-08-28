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
                Text(phone.state.label)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if let accountDisplay = phone.accountDisplay {
                    Text(accountDisplay)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(phone.activityStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(phone.geminiLiveState == .off ? Color.secondary.opacity(0.7) : Color.purple)
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
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.primary.opacity(0.055))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(numberFieldFocused ? Color.accentColor.opacity(0.65) : .clear, lineWidth: 1)
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
                        .help(phone.isGeminiLiveActive ? "Stop Gemini Live" : "Start Gemini Live")
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
                    keypad
                }
            } else if case .error = phone.state {
                Button("Back to dialing", action: phone.recoverFromError)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            } else if phone.state == .stopped {
                Button("Start phone", action: phone.toggleBaresip)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            } else {
                ProgressView("Registering with the provider …")
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
    }

    private var keypad: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 6) {
            ForEach(Array("123456789*0#"), id: \.self) { digit in
                Button {
                    phone.sendDTMF(digit)
                } label: {
                    Text(String(digit))
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            }
        }
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

    private var conversationPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(phone.summary == nil ? "Live transcript" : "Conversation")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Open") { openWindow(id: "conversation") }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            if let summary = phone.summary {
                Text(summary.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            } else {
                ForEach(phone.transcript.suffix(2)) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.speaker.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(entry.speaker == .me ? .blue : .purple)
                            .frame(width: 42, alignment: .leading)
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

struct ConversationView: View {
    @ObservedObject var phone: PhoneController

    var body: some View {
        VStack(spacing: 0) {
            conversationHeader
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if phone.transcript.isEmpty {
                            ContentUnavailableView(
                                "No transcript yet",
                                systemImage: "waveform",
                                description: Text("Once the call is connected, both sides of the conversation appear here live.")
                            )
                            .frame(maxWidth: .infinity, minHeight: 300)
                        }
                        ForEach(phone.transcript) { entry in
                            TranscriptRow(entry: entry)
                                .id(entry.id)
                        }
                        if let summary = phone.summary {
                            SummaryCard(summary: summary)
                                .id("summary")
                        }
                    }
                    .padding(28)
                }
                .onChange(of: phone.transcript.count) { _, _ in
                    if let id = phone.transcript.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
                .onChange(of: phone.summary) { _, summary in
                    if summary != nil { withAnimation { proxy.scrollTo("summary", anchor: .bottom) } }
                }
            }
            Divider()
            HStack {
                Label(phone.intelligenceStatus, systemImage: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear", action: phone.clearConversation)
                    .disabled(phone.transcript.isEmpty && phone.summary == nil)
                Button("Copy", action: phone.copyConversation)
                    .disabled(phone.transcript.isEmpty && phone.summary == nil)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            .padding(14)
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 460, idealHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var conversationHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: phone.state.isInCall ? "waveform.circle.fill" : "text.bubble.fill")
                .font(.system(size: 28))
                .foregroundStyle(phone.state.isInCall ? .green : .blue)
                .symbolEffect(.variableColor.iterative, isActive: phone.state.isInCall)
            VStack(alignment: .leading, spacing: 2) {
                Text(phone.state.isInCall ? "Live call" : "Last call")
                    .font(.title3.weight(.semibold))
                Text(phone.displayName(for: phone.state.peer) ?? phone.state.peer ?? "Local transcript")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if phone.state.isInCall {
                CallDuration(startedAt: phone.callStartedAt)
                Button(action: phone.hangup) {
                    Image(systemName: "phone.down.fill")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .tint(.red)
                .controlSize(.large)
            }
        }
        .padding(18)
    }
}

private struct TranscriptRow: View {
    let entry: TranscriptEntry

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill((entry.speaker == .me ? Color.blue : Color.purple).opacity(0.14))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: entry.speaker == .me ? "person.fill" : "phone.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(entry.speaker == .me ? .blue : .purple)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.speaker.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(entry.text)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .foregroundStyle(entry.isFinal ? .primary : .secondary)
            }
            Spacer(minLength: 20)
        }
    }
}

private struct SummaryCard: View {
    let summary: CallSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Summary", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(.blue)
            Text(summary.text)
                .font(.system(size: 14))
                .lineSpacing(3)
                .textSelection(.enabled)
        }
        .padding(18)
        .background(.blue.opacity(0.075), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.blue.opacity(0.12), lineWidth: 1)
        }
        .padding(.top, 8)
    }
}

private struct CallDuration: View {
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(duration(at: context.date))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func duration(at date: Date) -> String {
        guard let startedAt else { return "" }
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct PhoneSettingsView: View {
    @ObservedObject var phone: PhoneController
    @AppStorage("transcriptionEnabled") private var transcriptionEnabled = true
    @AppStorage("retainTranscript") private var retainTranscript = true
    @AppStorage("geminiLiveModel") private var geminiLiveModel = defaultGeminiLiveModel
    @State private var geminiAPIKey = ""
    @State private var geminiSettingsMessage: String?
    @State private var selectedAccountAddress: String?
    @State private var accountToRemove: ManagedSIPAccount?
    @State private var accountError: String?

    var body: some View {
        TabView {
            intelligenceSettings
                .tabItem { Label("Transcript", systemImage: "text.bubble") }

            assistantSettings
                .tabItem { Label("Assistant", systemImage: "sparkles") }

            phoneSettings
                .tabItem { Label("Phone", systemImage: "phone") }
        }
        .frame(width: 520, height: 360)
    }

    private var intelligenceSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Transcribe calls live", isOn: $transcriptionEnabled)
            Toggle("Keep the last transcript after hanging up", isOn: $retainTranscript)
                .disabled(!transcriptionEnabled)

            Divider()

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Processing on this Mac")
                        .fontWeight(.medium)
                    Text("Transcription and summaries stay on this Mac. The optional Gemini Live bridge has separate controls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(24)
    }

    private var assistantSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Gemini Live call bridge")
                        .font(.headline)
                    Text("BETA")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.purple.opacity(0.12), in: Capsule())
                }
                Text("When you turn it on during a call, caller audio is streamed to Google and Gemini's audio is sent back into the call.")
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
                TextField(defaultGeminiLiveModel, text: $geminiLiveModel)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
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
                Text("The bridge is off by default and never starts automatically. Local transcription remains independent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.purple)
            }
            Spacer()
        }
        .padding(24)
    }

    private var phoneSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SIP accounts")
                        .font(.headline)
                    Text(phone.accountDisplay ?? "No account configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Text("baresip")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
                .frame(minHeight: 150)
            }

            HStack(spacing: 8) {
                Button {
                    phone.requestAccountSetup()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add account")

                Button {
                    accountToRemove = selectedAccount
                } label: {
                    Image(systemName: "minus")
                }
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
        }
        .padding(20)
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
        .confirmationDialog(
            accountToRemove.map { "Remove \($0.displayName)?" } ?? "Remove account?",
            isPresented: isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Account", role: .destructive, action: removeSelectedAccount)
            Button("Cancel", role: .cancel) { accountToRemove = nil }
        } message: {
            Text("Its password will also be removed from Keychain.")
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

    private func accountRow(_ account: ManagedSIPAccount) -> some View {
        HStack(spacing: 10) {
            Button {
                selectAccount(account)
            } label: {
                Image(systemName: phone.activeManagedSIPAddress == account.sipAddress ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(phone.activeManagedSIPAddress == account.sipAddress ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(phone.activeManagedSIPAddress == account.sipAddress ? "Active account" : "Make active")

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .fontWeight(.medium)
                Text(account.sipAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Text(account.provider.shortName)
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private func selectAccount(_ account: ManagedSIPAccount) {
        selectedAccountAddress = account.sipAddress
        accountError = nil
        do {
            try phone.selectManagedAccount(account)
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
