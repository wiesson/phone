import SwiftUI

struct PhoneAccountPicker: View {
    enum Presentation {
        case compact
        case labeled
    }

    @ObservedObject var phone: PhoneController
    var presentation: Presentation = .compact

    var body: some View {
        if phone.managedAccounts.count > 1 && !phone.state.isInCall && !phone.state.isRinging {
            Menu {
                ForEach(phone.managedAccounts) { account in
                    Menu {
                        Section("Assistant profile") {
                            ForEach(AssistantProfile.allCases) { profile in
                                Button {
                                    var updated = account
                                    updated.assistantProfile = profile
                                    updated.assistantInstructionsOverride = nil
                                    updated.assistantContextData = nil
                                    try? phone.updateManagedAccountMetadata(updated)
                                } label: {
                                    if account.assistantProfile == profile {
                                        Label(profile.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(profile.displayName)
                                    }
                                }
                            }
                        }
                    } label: {
                        if phone.activeManagedSIPAddress == account.sipAddress {
                            Label(accountLabel(account), systemImage: "checkmark")
                        } else {
                            Text(accountLabel(account))
                        }
                    } primaryAction: {
                        try? phone.selectManagedAccount(account)
                    }
                }
            } label: {
                switch presentation {
                case .compact:
                    HStack(spacing: 3) {
                        Text(activeAccountText)
                            .font(.system(size: 11))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                case .labeled:
                    Label(activeAccountText, systemImage: "simcard")
                }
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Outgoing calls use this number")
        } else if let display = callOrAccountDisplay {
            switch presentation {
            case .compact:
                Text(display)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            case .labeled:
                Label(display, systemImage: "simcard")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var callOrAccountDisplay: String? {
        if phone.state.isInCall || phone.state.isRinging {
            return phone.currentCallAccountDisplay.map { "for \($0)" }
        }
        return phone.accountDisplay
    }

    private var activeAccountText: String {
        guard let display = phone.accountDisplay else { return "Choose number" }
        guard let active = phone.managedAccounts.first(where: {
            $0.sipAddress == phone.activeManagedSIPAddress
        }) else { return display }
        return "\(display) · \(active.assistantProfile.displayName)"
    }

    private func accountLabel(_ account: ManagedSIPAccount) -> String {
        "\(account.displayName) — \(account.assistantProfile.displayName)"
    }
}

struct AssistantDialButton: View {
    enum Presentation {
        case icon
        case labeled
    }

    @ObservedObject var phone: PhoneController
    var presentation: Presentation = .icon

    @State private var isPresented = false
    @AppStorage("assistantCallTask") private var assistantCallTask = ""

    var body: some View {
        Button {
            isPresented = true
        } label: {
            switch presentation {
            case .icon:
                ZStack {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "sparkles")
                        .font(.system(size: 8, weight: .bold))
                        .offset(x: 8, y: -8)
                }
                .frame(width: 28, height: 28)
            case .labeled:
                Label("Call with Assistant", systemImage: "sparkles")
                    .frame(minHeight: 24)
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(presentation == .icon ? .circle : .roundedRectangle)
        .tint(.purple)
        .disabled(
            phone.number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !phone.isGeminiConfigured
        )
        .help(phone.isGeminiConfigured ? "Call with Assistant" : "Configure the Assistant in Settings")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Task for the assistant")
                    .font(.headline)
                TextEditor(text: $assistantCallTask)
                    .font(.system(size: 12))
                    .frame(width: 290, height: 100)
                    .padding(5)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                HStack {
                    Button("Cancel") { isPresented = false }
                    Spacer()
                    Button("Call with Assistant") {
                        phone.dialWithAssistant(task: assistantCallTask)
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(assistantCallTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
        }
    }
}

struct DTMFKeypad: View {
    @ObservedObject var phone: PhoneController

    var body: some View {
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
}

struct ConversationTimeline: View {
    @ObservedObject var phone: PhoneController
    var minimumEmptyHeight: CGFloat = 300
    var contentPadding: CGFloat = 28

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if phone.transcript.isEmpty && phone.summary == nil {
                        ContentUnavailableView(
                            "No transcript yet",
                            systemImage: "waveform",
                            description: Text("Once the call is connected, both sides of the conversation appear here live.")
                        )
                        .frame(maxWidth: .infinity, minHeight: minimumEmptyHeight)
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
                .padding(contentPadding)
            }
            .onChange(of: phone.transcript.count) { _, _ in
                if let id = phone.transcript.last?.id {
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .onChange(of: phone.summary) { _, summary in
                if summary != nil {
                    withAnimation { proxy.scrollTo("summary", anchor: .bottom) }
                }
            }
        }
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

struct CallDuration: View {
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

func phoneStatusColor(for state: CallState) -> Color {
    switch state {
    case .error: .orange
    case .starting: .yellow
    case .ringing: .green
    case .dialing, .answering, .connected: .blue
    case .ready: .green
    case .stopped: .secondary
    }
}
