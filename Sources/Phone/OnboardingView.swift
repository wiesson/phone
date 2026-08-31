import AppKit
import SwiftUI

/// What a fresh Phone shows before it has a line.
///
/// The screen offers one thing: a command to hand to a coding agent. The
/// agent reads the skill behind that URL, registers the MCP server, and
/// provisions a line — and because the two checklist rows read the same
/// published state the rest of the app does, they fill in while it works.
/// That live change is the point: this is the screen a demo is recorded on.
struct OnboardingView: View {
    @ObservedObject var phone: PhoneController
    var openSetupWizard: () -> Void

    /// Where the agent-readable instructions live. Overridable without a
    /// rebuild, because the address is a publishing decision rather than a
    /// code one, and a demo may want to point at a draft:
    ///
    ///     defaults write local.phone.mini setupSkillURL https://example.com/SKILL.md
    static let defaultSkillURL = "https://nordwerk.studio/phone/SKILL.md"
    @AppStorage("setupSkillURL") private var skillURL = OnboardingView.defaultSkillURL

    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        OnboardingContent(
            command: setupCommand,
            line: lineStep,
            assistant: assistantStep,
            didCopy: didCopy,
            onCopy: copyCommand,
            onManualSetup: openSetupWizard
        )
        .onDisappear { copyResetTask?.cancel() }
    }

    private var setupCommand: String {
        let url = skillURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return "set up \(url.isEmpty ? Self.defaultSkillURL : url)"
    }

    private var lineStep: OnboardingStep {
        guard let account = phone.managedAccounts.first else { return .waiting("Line") }
        let extra = phone.managedAccounts.count - 1
        let name = account.displayName + (extra > 0 ? " +\(extra)" : "")
        let status = phone.registrationStatus(for: account)
        let detail: String
        switch status {
        case .registered: detail = name + " · online"
        case .registering: detail = name + " · registering"
        case .failed: detail = name + " · not registered"
        case .idle: detail = name
        }
        return OnboardingStep(
            title: "Line",
            detail: detail,
            isDone: true,
            isWorking: status == .registering
        )
    }

    private var assistantStep: OnboardingStep {
        let profiles = phone.savedAssistantProfiles
        guard let first = profiles.first else { return .waiting("Assistant") }
        let detail = profiles.count > 1 ? "\(first.name) +\(profiles.count - 1)" : first.name
        return OnboardingStep(title: "Assistant", detail: detail, isDone: true, isWorking: false)
    }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(setupCommand, forType: .string)
        didCopy = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}
