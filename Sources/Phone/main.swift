import AppKit
import SwiftUI

@MainActor
final class PhoneAppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: PhoneController?

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}

@main
@MainActor
struct PhoneApp: App {
    @NSApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    @StateObject private var phone: PhoneController

    init() {
        let controller = PhoneController()
        _phone = StateObject(wrappedValue: controller)
        appDelegate.controller = controller
        controller.start()
    }

    var body: some Scene {
        MenuBarExtra {
            PhonePanel(phone: phone)
        } label: {
            MenuBarPhoneLabel(
                state: phone.state,
                callStartedAt: phone.callStartedAt
            )
        }
        .menuBarExtraStyle(.window)

        Window("Conversation", id: "conversation") {
            ConversationView(phone: phone)
        }
        .defaultSize(width: 680, height: 620)
        .windowResizability(.contentMinSize)

        Settings {
            PhoneSettingsView()
        }
    }
}

private struct MenuBarPhoneLabel: View {
    let state: CallState
    let callStartedAt: Date?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: state.symbol)
            if state.isConnected, let callStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(duration(from: callStartedAt, to: context.date))
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
        .accessibilityLabel(state.label)
        // The menu bar label is the only view that exists for the whole app
        // lifetime, so the conversation window must be opened from here.
        .onChange(of: state.isConnected) { wasConnected, isConnected in
            if !wasConnected && isConnected {
                openWindow(id: "conversation")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
