import SwiftUI

struct PhonePanel: View {
    @ObservedObject var phone: PhoneController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @FocusState private var numberFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            callControls
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
                Text(phone.intelligenceStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
                Button(action: phone.hangup) {
                    Label("Hang up", systemImage: "phone.down.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
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
                openSettings()
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
                Text(phone.state.peer ?? "Local transcript")
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
    @AppStorage("transcriptionEnabled") private var transcriptionEnabled = true
    @AppStorage("retainTranscript") private var retainTranscript = true

    var body: some View {
        TabView {
            intelligenceSettings
                .tabItem { Label("Transcript", systemImage: "text.bubble") }

            phoneSettings
                .tabItem { Label("Phone", systemImage: "phone") }
        }
        .frame(width: 460, height: 220)
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
                    Text("Call audio is neither persistently recorded nor sent to any cloud service.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(24)
    }

    private var phoneSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsRow("Provider", value: "Telekom")
            settingsRow("Telephony", value: "baresip")

            Divider()

            Text("Provider account configuration will move directly into this panel in a future step.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
    }

    private func settingsRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
