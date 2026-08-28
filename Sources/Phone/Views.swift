import AppKit
import SwiftUI

struct PhonePanel: View {
    @ObservedObject var phone: PhoneController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @FocusState private var numberFieldFocused: Bool
    @State private var showKeypad = false
    @State private var showAssistantCall = false
    @AppStorage("assistantCallTask") private var assistantCallTask = ""

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
                if (phone.state.isRinging || phone.state.isInCall), let account = phone.currentCallAccountDisplay {
                    Text("for \(account)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if phone.managedAccounts.count > 1 && !phone.state.isInCall {
                    Menu {
                        ForEach(phone.managedAccounts) { account in
                            Button {
                                try? phone.selectManagedAccount(account)
                            } label: {
                                if phone.activeManagedSIPAddress == account.sipAddress {
                                    Label("\(account.displayName) — \(account.assistantProfile.displayName)", systemImage: "checkmark")
                                } else {
                                    Text("\(account.displayName) — \(account.assistantProfile.displayName)")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(headerAccountText)
                                .font(.system(size: 11))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Outgoing calls use this number")
                } else if let accountDisplay = phone.accountDisplay {
                    Text(accountDisplay)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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

                    Button {
                        showAssistantCall = true
                    } label: {
                        ZStack {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 13, weight: .semibold))
                            Image(systemName: "sparkles")
                                .font(.system(size: 8, weight: .bold))
                                .offset(x: 8, y: -8)
                        }
                        .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .tint(.purple)
                    .disabled(
                        phone.number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        !phone.isGeminiConfigured
                    )
                    .help(phone.isGeminiConfigured ? "Call with Assistant" : "Configure a Gemini API key in Settings")
                    .popover(isPresented: $showAssistantCall, arrowEdge: .bottom) {
                        assistantCallPopover
                    }
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

    private var assistantCallPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Task for the assistant")
                .font(.headline)
            TextEditor(text: $assistantCallTask)
                .font(.system(size: 12))
                .frame(width: 290, height: 100)
                .padding(5)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            HStack {
                Button("Cancel") { showAssistantCall = false }
                Spacer()
                Button("Call with Assistant") {
                    phone.dialWithAssistant(task: assistantCallTask)
                    showAssistantCall = false
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(assistantCallTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    private var headerAccountText: String {
        guard let display = phone.accountDisplay else { return "Choose number" }
        if let active = phone.managedAccounts.first(where: { $0.sipAddress == phone.activeManagedSIPAddress }) {
            return "\(display) · \(active.assistantProfile.displayName)"
        }
        return display
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

struct TranscriptRow: View {
    let entry: TranscriptEntry

    private var tint: Color {
        entry.isAssistant ? .orange : (entry.speaker == .me ? .blue : .purple)
    }

    private var symbol: String {
        entry.isAssistant ? "sparkles" : (entry.speaker == .me ? "person.fill" : "phone.fill")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill(tint.opacity(0.14))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.speakerTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(entry.isAssistant ? tint : .secondary)
                Text(entry.text)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .foregroundStyle(entry.isFinal ? .primary : .secondary)
            }
            Spacer(minLength: 20)
        }
    }
}

struct SummaryCard: View {
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
    @AppStorage("archiveConversations") private var archiveConversations = true
    @AppStorage("transcriptionLocale") private var transcriptionLocale = ""
    @AppStorage("showDockIcon") private var showDockIcon = false
    @AppStorage("geminiLiveModel") private var geminiLiveModel = defaultGeminiLiveModel
    @AppStorage(assistantAnswerModeDefaultsKey) private var assistantAnswerMode: AssistantAnswerMode = .never
    @AppStorage(businessHoursDefaultsKey) private var businessHoursData = (try? JSONEncoder().encode(BusinessHoursSchedule())) ?? Data()
    @AppStorage("assistantAnswerDelay") private var assistantAnswerDelay = 5
    @AppStorage("assistantInstructions") private var assistantInstructions = defaultAssistantInstructions
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
    @State private var isConfirmingArchiveDeletion = false

    var body: some View {
        TabView {
            intelligenceSettings
                .tabItem { Label("Transcript", systemImage: "text.bubble") }

            assistantSettings
                .tabItem { Label("Assistant", systemImage: "sparkles") }

            automationSettings
                .tabItem { Label("Automation", systemImage: "bolt.horizontal") }

            phoneSettings
                .tabItem { Label("Phone", systemImage: "phone") }
        }
        .frame(width: 520, height: 580)
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
        .sheet(item: $accountToEdit) { account in
            SetupWizard(phone: phone, editing: account)
        }
    }

    private var intelligenceSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Transcribe calls live", isOn: $transcriptionEnabled)
            Toggle("Keep the last transcript after hanging up", isOn: $retainTranscript)
                .disabled(!transcriptionEnabled)
            Toggle("Archive conversations on this Mac", isOn: $archiveConversations)
            Text("When enabled, final transcripts and summaries are stored locally on this Mac. Call metadata is always kept in the library.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Delete all archived conversations", role: .destructive) {
                isConfirmingArchiveDeletion = true
            }

            Divider()

            Picker("Language", selection: $transcriptionLocale) {
                Text("System (\(Locale.current.identifier))").tag("")
                Text("Deutsch").tag("de-DE")
                Text("English (US)").tag("en-US")
                Text("English (UK)").tag("en-GB")
                Text("Français").tag("fr-FR")
                Text("Español").tag("es-ES")
                Text("Italiano").tag("it-IT")
            }
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

    private var assistantSettings: some View {
        ScrollView {
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
                    Text("When active, caller audio is streamed to Google and Gemini audio is sent back into the call.")
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

                Picker("Answer incoming calls", selection: $assistantAnswerMode) {
                    Text("Never").tag(AssistantAnswerMode.never)
                    Text("Always").tag(AssistantAnswerMode.always)
                    Text("Outside business hours").tag(AssistantAnswerMode.outsideBusinessHours)
                }

                if assistantAnswerMode == .outsideBusinessHours {
                    VStack(alignment: .leading, spacing: 10) {
                        BusinessHoursRow(
                            title: "Weekdays",
                            group: businessHoursGroupBinding(\.weekdays)
                        )
                        BusinessHoursRow(
                            title: "Weekend",
                            group: businessHoursGroupBinding(\.weekend)
                        )
                        Text("The assistant answers when you are not attending.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Stepper(
                    "Answer after \(assistantAnswerDelay) seconds",
                    value: $assistantAnswerDelay,
                    in: 0...30
                )
                .disabled(assistantAnswerMode == .never)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Assistant instructions")
                        .fontWeight(.medium)
                    TextEditor(text: $assistantInstructions)
                        .font(.system(size: 12))
                        .frame(minHeight: 100)
                        .padding(5)
                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    Text("Add useful business context such as opening hours, services, or preferred callback details.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Label {
                    Text("Manual bridge controls remain available during calls. Local transcription stays independent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(.purple)
                }
            }
            .padding(24)
        }
    }

    private var phoneSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Show the app in the Dock and app switcher", isOn: $showDockIcon)
                if showDockIcon != (NSApp.activationPolicy() == .regular) {
                    Text("Takes effect after restarting Phone.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Divider()

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
            registrationIndicator(for: account)
            Text(account.assistantProfile.displayName)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.purple.opacity(0.12), in: Capsule())
                .foregroundStyle(.purple)
            Text(account.provider.shortName)
                .font(.caption)
                .foregroundStyle(.secondary)
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
        .onTapGesture(count: 2) {
            selectedAccountAddress = account.sipAddress
            accountToEdit = account
        }
        .contextMenu {
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
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func accountProfileEditor(_ account: ManagedSIPAccount) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Assistant profile", selection: profileBinding(for: account)) {
                    ForEach(AssistantProfile.allCases) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }

                DisclosureGroup("Edit instructions…", isExpanded: $showsAccountInstructions) {
                    VStack(alignment: .trailing, spacing: 6) {
                        TextEditor(text: instructionsBinding(for: account))
                            .font(.system(size: 12))
                            .frame(minHeight: 95)
                            .padding(5)
                            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                        Button("Reset to preset") {
                            updateAccount(account) { $0.assistantInstructionsOverride = nil }
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
                            updateAccount(account) { $0.assistantContextData = nil }
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 6)
                }
            }
        } label: {
            Text("Assistant for \(account.displayName)")
        }
    }

    private func profileBinding(for account: ManagedSIPAccount) -> Binding<AssistantProfile> {
        Binding(
            get: { selectedAccount?.assistantProfile ?? account.assistantProfile },
            set: { profile in
                updateAccount(account) {
                    $0.assistantProfile = profile
                    $0.assistantInstructionsOverride = nil
                    $0.assistantContextData = nil
                }
            }
        )
    }

    private func instructionsBinding(for account: ManagedSIPAccount) -> Binding<String> {
        Binding(
            get: {
                let current = selectedAccount ?? account
                return current.assistantInstructionsOverride
                    ?? current.assistantProfile.presetInstructions(globalFallback: assistantInstructions)
            },
            set: { value in updateAccount(account) { $0.assistantInstructionsOverride = value } }
        )
    }

    private func contextDataBinding(for account: ManagedSIPAccount) -> Binding<String> {
        Binding(
            get: {
                let current = selectedAccount ?? account
                return current.assistantContextData
                    ?? current.assistantProfile.presetContextData(startingAt: Date())
                    ?? ""
            },
            set: { value in updateAccount(account) { $0.assistantContextData = value } }
        )
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

    private func businessHoursGroupBinding(
        _ keyPath: WritableKeyPath<BusinessHoursSchedule, BusinessHoursSchedule.DayGroup>
    ) -> Binding<BusinessHoursSchedule.DayGroup> {
        Binding(
            get: {
                (try? JSONDecoder().decode(BusinessHoursSchedule.self, from: businessHoursData))?[keyPath: keyPath]
                    ?? BusinessHoursSchedule()[keyPath: keyPath]
            },
            set: { group in
                var schedule = (try? JSONDecoder().decode(BusinessHoursSchedule.self, from: businessHoursData))
                    ?? BusinessHoursSchedule()
                schedule[keyPath: keyPath] = group
                if let data = try? JSONEncoder().encode(schedule) {
                    businessHoursData = data
                }
            }
        )
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
