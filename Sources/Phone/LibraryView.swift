import SwiftUI

struct LibraryView: View {
    @ObservedObject var phone: PhoneController
    let store: PhoneStore

    @State private var calls: [ArchivedCall] = []
    @State private var selection: UUID?
    @State private var utterances: [TranscriptEntry] = []
    @State private var query = ""
    @State private var loadError: String?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
        } detail: {
            detail
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search calls")
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            await refreshCalls()
        }
        .onChange(of: selection) { _, id in
            Task { await loadUtterances(for: id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .phoneArchiveChanged)) { _ in
            Task {
                await refreshCalls()
                await loadUtterances(for: selection)
            }
        }
        .frame(minWidth: 760, idealWidth: 980, minHeight: 520, idealHeight: 680)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(dayGroups) { group in
                Section(group.title) {
                    ForEach(group.calls) { call in
                        CallLibraryRow(call: call, displayName: displayName(for: call))
                            .tag(call.id)
                            .contextMenu {
                                Button("Delete Call", role: .destructive) {
                                    Task { await delete(call) }
                                }
                            }
                    }
                }
            }
        }
        .overlay {
            if calls.isEmpty, loadError == nil {
                ContentUnavailableView(
                    query.isEmpty ? "No archived calls" : "No results",
                    systemImage: query.isEmpty ? "rectangle.stack" : "magnifyingglass",
                    description: Text(query.isEmpty
                        ? "Completed calls will appear here."
                        : "Try a different name, number, summary, or phrase.")
                )
            } else if let loadError {
                ContentUnavailableView(
                    "Archive unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            }
        }
        .navigationTitle("Calls")
    }

    @ViewBuilder
    private var detail: some View {
        if let call = selectedCall {
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
                    ToolbarItem {
                        Button {
                            phone.number = peer
                            phone.dial()
                        } label: {
                            Label("Call again", systemImage: "phone.fill")
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView(
                calls.isEmpty ? "No archived calls" : "No call selected",
                systemImage: calls.isEmpty ? "rectangle.stack" : "phone",
                description: Text(calls.isEmpty
                    ? "Completed calls will appear in the library."
                    : "Select a call in the sidebar to see its details.")
            )
        }
    }

    private var selectedCall: ArchivedCall? {
        guard let selection else { return nil }
        return calls.first { $0.id == selection }
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
                Label(call.direction == .incoming ? "Incoming" : "Outgoing", systemImage: call.direction == .incoming ? "arrow.down.left" : "arrow.up.right")
                if call.missed { Label("Missed", systemImage: "exclamationmark.circle.fill") }
            }
            .font(.subheadline)
            .foregroundStyle(call.missed ? Color.red : Color.secondary)
        }
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
            if let selection, !fetched.contains(where: { $0.id == selection }) {
                self.selection = nil
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
            guard selection == id else { return }
            utterances = fetched
        } catch {
            guard selection == id else { return }
            utterances = []
        }
    }

    private func delete(_ call: ArchivedCall) async {
        do {
            try await store.deleteCall(call.id)
            if selection == call.id {
                selection = nil
                utterances = []
            }
            await refreshCalls()
            NotificationCenter.default.post(name: .phoneArchiveChanged, object: nil)
        } catch {
            loadError = error.localizedDescription
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
