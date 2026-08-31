import AppKit
import SwiftUI

/// What a fresh Phone shows before it has a line.
///
/// The screen offers one thing: a command to hand to a coding agent. The
/// agent reads the skill behind that URL, registers the MCP server, and
/// provisions a line — and because the two rows at the bottom read the same
/// published state the rest of the app does, they fill in while it works.
/// That live change is the point: this is the screen a demo is recorded on.
struct OnboardingView: View {
    @ObservedObject var phone: PhoneController
    var openSetupWizard: () -> Void

    /// Where the agent-readable instructions live. Kept in one place because
    /// it is spoken aloud in the demo and printed on the screen.
    static let setupCommand = "set up https://nordwerk.studio/phone/SKILL.md"

    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 40)
                header
                    .padding(.bottom, 30)
                commandCard
                    .padding(.bottom, 26)
                progress
                    .padding(.bottom, 22)
                manualRoute
                Spacer(minLength: 40)
            }
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { copyResetTask?.cancel() }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "phone.badge.waveform.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.accentColor)
                .padding(22)
                .background(Color.accentColor.opacity(0.10), in: Circle())
                .accessibilityHidden(true)

            Text("No lines yet")
                .font(.title2.weight(.semibold))

            Text("Give this to a coding agent. It sets up a line at your provider and an assistant to answer it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The command is the invitation, so it is the one thing on the screen
    /// that looks like it can be picked up and taken somewhere.
    private var commandCard: some View {
        HStack(spacing: 10) {
            Text("$")
                .foregroundStyle(.tertiary)
            Text(Self.setupCommand)
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 8)
            Button(action: copyCommand) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(didCopy ? Color.green : Color.accentColor)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(didCopy ? "Copied" : "Copy the command")
            .accessibilityLabel(didCopy ? "Command copied" : "Copy the command")
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.30), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.15), value: didCopy)
    }

    /// Two rows, because two things have to exist before the phone can take a
    /// call: something to ring, and something to say. They are what visibly
    /// changes while the agent works.
    private var progress: some View {
        VStack(spacing: 0) {
            progressRow(
                title: "Line",
                detail: lineDetail,
                isDone: !phone.managedAccounts.isEmpty,
                isWorking: lineIsRegistering
            )
            Divider().padding(.leading, 30)
            progressRow(
                title: "Assistant",
                detail: assistantDetail,
                isDone: !phone.savedAssistantProfiles.isEmpty,
                isWorking: false
            )
        }
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(.easeInOut(duration: 0.25), value: phone.managedAccounts)
        .animation(.easeInOut(duration: 0.25), value: phone.savedAssistantProfiles)
    }

    private func progressRow(title: String, detail: String, isDone: Bool, isWorking: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "circle.dotted")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 16, height: 16)

            Text(title)
                .font(.callout)
                .foregroundStyle(isDone ? .primary : .secondary)

            Spacer(minLength: 8)

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private var manualRoute: some View {
        Button("Set up a line by hand", action: openSetupWizard)
            .buttonStyle(.link)
            .font(.callout)
    }

    private var lineIsRegistering: Bool {
        guard let account = phone.managedAccounts.first else { return false }
        return phone.registrationStatus(for: account) == .registering
    }

    private var lineDetail: String {
        guard let account = phone.managedAccounts.first else { return "waiting" }
        let extra = phone.managedAccounts.count - 1
        let name = account.displayName + (extra > 0 ? " +\(extra)" : "")
        switch phone.registrationStatus(for: account) {
        case .registered: return name + " · online"
        case .registering: return name + " · registering"
        case .failed: return name + " · not registered"
        case .idle: return name
        }
    }

    private var assistantDetail: String {
        let profiles = phone.savedAssistantProfiles
        guard let first = profiles.first else { return "waiting" }
        return profiles.count > 1 ? "\(first.name) +\(profiles.count - 1)" : first.name
    }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.setupCommand, forType: .string)
        didCopy = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}
