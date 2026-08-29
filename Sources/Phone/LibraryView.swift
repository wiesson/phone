import SwiftUI

struct LibraryView: View {
    @ObservedObject var phone: PhoneController
    let store: PhoneStore

    @State private var calls: [ArchivedCall] = []
    @State private var selection: LibrarySelection? = .phone
    @State private var utterances: [TranscriptEntry] = []
    @State private var query = ""
    @State private var loadError: String?
    @State private var isAssistantInspectorPresented = false
    @FocusState private var numberFieldFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
        } detail: {
            HStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isAssistantInspectorPresented {
                    Divider()
                    AssistantCallInspector(phone: phone)
                        .frame(width: 320)
                        .background(.background.secondary)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isAssistantInspectorPresented)
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search calls")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: toggleAssistantInspector) {
                    Label(
                        isAssistantInspectorPresented ? "Hide Assistant Call" : "Show Assistant Call",
                        systemImage: "sparkles.rectangle.stack"
                    )
                }
                .help(isAssistantInspectorPresented ? "Hide Assistant Call" : "Show Assistant Call")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: showPhoneAndFocus) {
                    Label("New call", systemImage: "phone.badge.plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New call (⌘N)")
            }
        }
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            await refreshCalls()
        }
        .onChange(of: selection) { _, selection in
            Task { await loadUtterances(for: selection?.callID) }
        }
        .onChange(of: phone.state) { _, state in
            if state.isRinging || state.isInCall {
                selection = .phone
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .phoneArchiveChanged)) { _ in
            Task {
                await refreshCalls()
                await loadUtterances(for: selection?.callID)
            }
        }
        .frame(minWidth: 720, idealWidth: 1_100, minHeight: 560, idealHeight: 700)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("Phone", systemImage: phone.state.isReady ? "phone.fill" : phone.state.symbol)
                    .tag(LibrarySelection.phone)
            }

            if calls.isEmpty {
                Section("Library") {
                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    } else if query.isEmpty {
                        Text("Completed calls will appear here.")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("No results", systemImage: "magnifyingglass")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(dayGroups) { group in
                Section(group.title) {
                    ForEach(group.calls) { call in
                        CallLibraryRow(call: call, displayName: displayName(for: call))
                            .tag(LibrarySelection.call(call.id))
                            .contextMenu {
                                Button("Delete Call", role: .destructive) {
                                    Task { await delete(call) }
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Calls")
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .phone:
            DesktopPhoneView(phone: phone, numberFieldFocused: $numberFieldFocused)
                .navigationTitle("Phone")
        case .call(let id):
            if let call = calls.first(where: { $0.id == id }) {
                archivedCallDetail(call)
            } else {
                noSelectionDetail
            }
        case nil:
            noSelectionDetail
        }
    }

    private func archivedCallDetail(_ call: ArchivedCall) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                callHeader(call)
                if let summary = call.summary {
                    SummaryCard(summary: CallSummary(text: summary, createdAt: call.startedAt))
                }
                if utterances.isEmpty {
                    ContentUnavailableView(
                        "No archived transcript",
                        systemImage: "text.bubble",
                        description: Text("This call has metadata only.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Conversation")
                            .font(.headline)
                        ForEach(utterances) { entry in
                            TranscriptRow(entry: entry)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(displayName(for: call))
        .toolbar {
            if phone.state.isReady, let peer = call.peer {
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        phone.number = peer
                        selection = .phone
                        phone.dial()
                    } label: {
                        Label("Call again", systemImage: "phone.fill")
                    }
                }
            }
        }
    }

    private var noSelectionDetail: some View {
        ContentUnavailableView(
            calls.isEmpty ? "No archived calls" : "No call selected",
            systemImage: calls.isEmpty ? "rectangle.stack" : "phone",
            description: Text(calls.isEmpty
                ? "Completed calls will appear in the library."
                : "Select a call in the sidebar to see its details.")
        )
    }

    private var dayGroups: [CallDayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: calls) { calendar.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { day in
            CallDayGroup(
                day: day,
                title: dayTitle(day, calendar: calendar),
                calls: grouped[day] ?? []
            )
        }
    }

    private func callHeader(_ call: ArchivedCall) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: call.missed
                    ? "phone.down.circle.fill"
                    : (call.direction == .incoming ? "phone.arrow.down.left.fill" : "phone.arrow.up.right.fill"))
                    .font(.system(size: 30))
                    .foregroundStyle(call.missed ? .red : .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(for: call))
                        .font(.title2.weight(.semibold))
                    if let peer = call.peer, peer != displayName(for: call) {
                        Text(peer)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            HStack(spacing: 14) {
                Label(call.startedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                Label(formatDuration(call.duration), systemImage: "clock")
                Label(
                    call.direction == .incoming ? "Incoming" : "Outgoing",
                    systemImage: call.direction == .incoming ? "arrow.down.left" : "arrow.up.right"
                )
                if call.missed { Label("Missed", systemImage: "exclamationmark.circle.fill") }
            }
            .font(.subheadline)
            .foregroundStyle(call.missed ? Color.red : Color.secondary)
        }
    }

    private func toggleAssistantInspector() {
        isAssistantInspectorPresented.toggle()
        if isAssistantInspectorPresented { selection = .phone }
    }

    private func showPhoneAndFocus() {
        selection = .phone
        guard phone.state.isReady else { return }
        DispatchQueue.main.async { numberFieldFocused = true }
    }

    private func displayName(for call: ArchivedCall) -> String {
        phone.displayName(for: call.peer) ?? call.displayName ?? call.peer ?? "Unknown"
    }

    private func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func refreshCalls() async {
        do {
            let fetched = try await store.fetchCalls(query: query, limit: 500, offset: 0)
            guard !Task.isCancelled else { return }
            calls = fetched
            loadError = nil
            if case .call(let id) = selection, !fetched.contains(where: { $0.id == id }) {
                selection = .phone
                utterances = []
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadUtterances(for id: UUID?) async {
        guard let id else {
            utterances = []
            return
        }
        do {
            let fetched = try await store.fetchUtterances(callId: id)
            guard selection?.callID == id else { return }
            utterances = fetched
        } catch {
            guard selection?.callID == id else { return }
            utterances = []
        }
    }

    private func delete(_ call: ArchivedCall) async {
        do {
            try await store.deleteCall(call.id)
            if selection?.callID == call.id {
                selection = .phone
                utterances = []
            }
            await refreshCalls()
            NotificationCenter.default.post(name: .phoneArchiveChanged, object: nil)
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private enum LibrarySelection: Hashable {
    case phone
    case call(UUID)

    var callID: UUID? {
        if case .call(let id) = self { return id }
        return nil
    }
}

private struct DesktopPhoneView: View {
    @ObservedObject var phone: PhoneController
    @FocusState.Binding var numberFieldFocused: Bool

    @State private var showKeypad = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                statusHeader
                callControls
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)

            Divider()

            conversationHeader
            Divider()
            ConversationTimeline(phone: phone, minimumEmptyHeight: 220, contentPadding: 24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: phone.state.isConnected) { _, connected in
            if !connected { showKeypad = false }
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(phoneStatusColor(for: phone.state).opacity(0.13))
                    .frame(width: 54, height: 54)
                Image(systemName: phone.state.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(phoneStatusColor(for: phone.state))
                    .symbolEffect(.pulse, isActive: phone.state.isRinging)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Text(phone.callStateLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 7) {
                if phone.callStartedAt != nil {
                    CallDuration(startedAt: phone.callStartedAt)
                        .font(.title3)
                }
                Text(phone.state.isInCall || phone.state.isRinging ? "Line" : "Call from")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PhoneAccountPicker(phone: phone, presentation: .labeled)
            }
        }
    }

    @ViewBuilder
    private var callControls: some View {
        if phone.state.isReady {
            dialer
        } else if phone.state.isRinging {
            HStack(spacing: 12) {
                callActionButton(
                    "Decline",
                    symbol: "phone.down.fill",
                    color: .red,
                    action: phone.reject
                )
                callActionButton(
                    "Answer",
                    symbol: "phone.fill",
                    color: .green,
                    action: phone.answer
                )
            }
            .frame(maxWidth: 520)
        } else if phone.state.isInCall {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    roundControl(
                        phone.isMuted ? "Unmute" : "Mute",
                        symbol: phone.isMuted ? "mic.slash.fill" : "mic.fill",
                        tint: phone.isMuted ? .orange : .secondary,
                        disabled: !phone.state.isConnected,
                        action: phone.toggleMute
                    )
                    roundControl(
                        phone.isGeminiLiveActive ? "Stop Assistant" : "Assistant",
                        symbol: "sparkles",
                        tint: phone.isGeminiLiveActive ? .purple : .secondary,
                        disabled: !phone.state.isConnected || !phone.isGeminiConfigured,
                        action: phone.toggleGeminiLive
                    )

                    Button(action: phone.hangup) {
                        Label("Hang up", systemImage: "phone.down.fill")
                            .fontWeight(.semibold)
                            .frame(minWidth: 150, minHeight: 38)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)

                    roundControl(
                        "Keypad",
                        symbol: "circle.grid.3x3.fill",
                        tint: showKeypad ? .accentColor : .secondary,
                        disabled: !phone.state.isConnected
                    ) {
                        showKeypad.toggle()
                    }
                }

                if showKeypad && phone.state.isConnected {
                    DTMFKeypad(phone: phone)
                        .frame(maxWidth: 300)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        } else if case .error = phone.state {
            Button("Back to dialing", action: phone.recoverFromError)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        } else if phone.state == .stopped {
            Button("Start phone", action: phone.toggleBaresip)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        } else {
            ProgressView("Registering with the provider …")
                .controlSize(.large)
        }
    }

    private var dialer: some View {
        let suggestions = phone.contactSuggestions(matching: phone.number, limit: 8)
        return VStack(alignment: .leading, spacing: 12) {
            Text("New call")
                .font(.headline)
            HStack(spacing: 10) {
                TextField("Phone number, contact, or SIP address", text: $phone.number)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($numberFieldFocused)
                    .font(.system(size: 17, design: .rounded))
                    .onSubmit {
                        if !dialInputRequestsContactSearch(phone.number) { phone.dial() }
                    }

                Button(action: phone.dial) {
                    Label("Call", systemImage: "phone.fill")
                        .frame(minHeight: 24)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .disabled(
                    phone.number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    dialInputRequestsContactSearch(phone.number)
                )
            }

            if !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(suggestions) { entry in
                        Button {
                            phone.number = entry.number
                            numberFieldFocused = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.displayName)
                                        .font(.body.weight(.medium))
                                    Text("\(entry.label) · \(entry.number)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        if entry.id != suggestions.last?.id { Divider() }
                    }
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1))
                }
            }
        }
        .padding(18)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    numberFieldFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1),
                    lineWidth: 1
                )
        }
    }

    private var conversationHeader: some View {
        HStack(spacing: 10) {
            Label(
                phone.state.isInCall ? "Live conversation" : "Conversation",
                systemImage: phone.state.isInCall ? "waveform" : "text.bubble"
            )
            .font(.headline)
            if phone.state.isInCall {
                Text("Live")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            Spacer()
            Label(phone.intelligenceStatus, systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Clear", action: phone.clearConversation)
                .disabled(phone.transcript.isEmpty && phone.summary == nil)
            Button("Copy", action: phone.copyConversation)
                .disabled(phone.transcript.isEmpty && phone.summary == nil)
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var headerTitle: String {
        if let peer = phone.state.peer {
            return phone.displayName(for: peer) ?? peer
        }
        return phone.state.isReady ? "Ready to call" : phone.callStateLabel
    }

    private func callActionButton(
        _ title: String,
        symbol: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .controlSize(.large)
    }

    private func roundControl(
        _ title: String,
        symbol: String,
        tint: Color,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 28, height: 24)
                Text(title)
                    .font(.caption)
            }
            .frame(minWidth: 82)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .disabled(disabled)
        .help(title)
    }
}

private struct AssistantCallInspector: View {
    @ObservedObject var phone: PhoneController

    @State private var rawIntent = ""
    @State private var taskBrief = ""
    @State private var isGenerating = false
    @State private var generationError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Assistant Call", systemImage: "sparkles")
                        .font(.headline)
                        .foregroundStyle(.purple)
                    Text("Describe the outcome, then review the brief before calling.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("What should the assistant do?")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $rawIntent)
                        .font(.body)
                        .frame(minHeight: 88)
                        .padding(6)
                        .scrollContentBackground(.hidden)
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.primary.opacity(0.12))
                        }
                }

                Button(action: generateCallPlan) {
                    HStack(spacing: 8) {
                        if isGenerating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "wand.and.sparkles")
                        }
                        Text(isGenerating ? "Generating call plan …" : "Generate call plan")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isGenerating || trimmedIntent.isEmpty || !phone.isGeminiConfigured)

                if let generationError {
                    Label(generationError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !phone.isGeminiConfigured {
                    Label("Configure Gemini in Settings to generate a plan or place an assistant call.", systemImage: "key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Generated task brief")
                        .font(.subheadline.weight(.semibold))
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $taskBrief)
                            .font(.body)
                            .frame(minHeight: 140)
                            .padding(6)
                            .scrollContentBackground(.hidden)
                        if taskBrief.isEmpty {
                            Text("The generated brief appears here and remains editable.")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(.primary.opacity(0.12))
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Number to call")
                        .font(.subheadline.weight(.semibold))
                    TextField("Phone number or SIP address", text: $phone.number)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.primary.opacity(0.12))
                        }
                    PhoneAccountPicker(phone: phone, presentation: .labeled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    phone.dialWithAssistant(task: effectiveTask)
                } label: {
                    Label("Call with assistant", systemImage: "phone.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.large)
                .disabled(
                    !phone.state.isReady ||
                    !phone.isGeminiConfigured ||
                    phone.number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    effectiveTask.isEmpty
                )
            }
            .padding(20)
        }
    }

    private var trimmedIntent: String {
        rawIntent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectiveTask: String {
        let generated = taskBrief.trimmingCharacters(in: .whitespacesAndNewlines)
        return generated.isEmpty ? trimmedIntent : generated
    }

    private func generateCallPlan() {
        guard !trimmedIntent.isEmpty, !isGenerating else { return }
        guard let apiKey = GeminiAPIKeyStore.apiKey() else {
            generationError = "Configure a Gemini API key in Settings."
            return
        }
        isGenerating = true
        generationError = nil
        let prompt = assistantCallPlanPrompt(intent: trimmedIntent)
        let model = UserDefaults.standard.string(forKey: "geminiSummaryModel") ?? GeminiTextClient.defaultModel
        Task {
            defer { isGenerating = false }
            do {
                taskBrief = try await GeminiTextClient.generate(
                    prompt: prompt,
                    systemInstruction: assistantCallPlanSystemInstruction,
                    model: model,
                    apiKey: apiKey
                )
            } catch {
                generationError = redactSensitiveValues(in: error.localizedDescription)
            }
        }
    }
}

private struct CallDayGroup: Identifiable {
    let day: Date
    let title: String
    let calls: [ArchivedCall]

    var id: Date { day }
}

private struct CallLibraryRow: View {
    let call: ArchivedCall
    let displayName: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: call.missed ? "phone.down.fill" : (call.direction == .incoming ? "arrow.down.left" : "arrow.up.right"))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(call.missed ? .red : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.body.weight(call.missed ? .semibold : .regular))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(call.startedAt, format: .dateTime.hour().minute())
                    Text("·")
                    Text(formatDuration(call.duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
