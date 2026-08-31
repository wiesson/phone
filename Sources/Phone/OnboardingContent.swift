import AppKit
import SwiftUI

/// One line of the setup checklist: what it is, where it got to, and whether
/// it is still moving.
struct OnboardingStep: Equatable {
    var title: String
    var detail: String
    var isDone: Bool
    var isWorking: Bool

    static func waiting(_ title: String) -> OnboardingStep {
        OnboardingStep(title: title, detail: "waiting", isDone: false, isWorking: false)
    }
}

/// The empty state's appearance, with no controller behind it.
///
/// Split out from `OnboardingView` so the screen can be rendered from plain
/// values — in a preview, or offscreen into an image — without starting a
/// phone. It is the only part with any layout in it.
struct OnboardingContent: View {
    let command: String
    let line: OnboardingStep
    let assistant: OnboardingStep
    var didCopy: Bool = false
    var onCopy: () -> Void = {}
    var onManualSetup: () -> Void = {}

    var body: some View {
        // The minHeight is the container's own height, so the column sits in
        // the middle of a roomy window but still scrolls rather than clips
        // when the window is short or the text is large. A Spacer would not
        // do this: inside a ScrollView it has nothing to expand into.
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    header
                        .padding(.bottom, 30)
                    // Once there is a line, the invitation has been accepted:
                    // the command and the manual route both drop away and
                    // leave the result standing on its own.
                    if !line.isDone {
                        commandCard
                            .padding(.bottom, 26)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                    checklist
                    if !line.isDone {
                        manualRoute
                            .padding(.top, 22)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: line.isDone)
                .frame(maxWidth: 460)
                .padding(.horizontal, 32)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "phone.badge.waveform.fill")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.accentColor)
                .padding(22)
                .background(Color.accentColor.opacity(0.10), in: Circle())
                .accessibilityHidden(true)

            Text(title)
                .font(.title2.weight(.semibold))

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.easeInOut(duration: 0.25), value: title)
    }

    /// The heading has to keep up with the checklist under it. The screen
    /// stays on for a moment after the last piece lands, and a line that is
    /// online underneath the words "No lines yet" reads as a bug.
    private var title: String {
        guard line.isDone else { return "No lines yet" }
        if line.isWorking { return "Connecting the line" }
        return assistant.isDone ? "Ready to take calls" : "The line is up"
    }

    private var subtitle: String {
        guard line.isDone else {
            return "Give this to a coding agent. It sets up a line at your provider and an assistant to answer it."
        }
        return line.isWorking
            ? "Registering with your provider."
            : "Phone is set up. This window will show your calls."
    }

    /// The command is the invitation, so it is the one thing on the screen
    /// that looks like it can be picked up and taken somewhere.
    private var commandCard: some View {
        HStack(spacing: 10) {
            Text("$")
                .foregroundStyle(.tertiary)
            Text(command)
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            Button(action: onCopy) {
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
    private var checklist: some View {
        VStack(spacing: 0) {
            row(line)
            Divider().padding(.leading, 40)
            row(assistant)
        }
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(.easeInOut(duration: 0.25), value: line)
        .animation(.easeInOut(duration: 0.25), value: assistant)
    }

    private func row(_ step: OnboardingStep) -> some View {
        HStack(spacing: 10) {
            Group {
                // Working outranks done: a line exists the moment it is
                // created, but it is not a tick until it has registered, and
                // a green check next to the word "registering" reads as a
                // contradiction.
                if step.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else if step.isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "circle.dotted")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 16, height: 16)

            Text(step.title)
                .font(.callout)
                .foregroundStyle(step.isDone ? .primary : .secondary)

            Spacer(minLength: 8)

            Text(step.detail)
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
        Button("Set up a line by hand", action: onManualSetup)
            .buttonStyle(.link)
            .font(.callout)
    }
}
