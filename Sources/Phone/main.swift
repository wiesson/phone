import AppKit
import SwiftUI

@MainActor
final class PhoneAppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: PhoneController?

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        controller?.handleDialURL(url)
    }
}

@main
@MainActor
struct PhoneApp: App {
    @NSApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    // Deliberately not @StateObject: the app body must not re-evaluate on
    // every controller publish, or each transcript update forces an expensive
    // menu bar item relayout. Views observe the controller individually.
    private let phone: PhoneController

    init() {
        let controller = PhoneController()
        phone = controller
        appDelegate.controller = controller
        controller.start()
    }

    var body: some Scene {
        MenuBarExtra {
            PhonePanel(phone: phone)
        } label: {
            MenuBarPhoneLabel(model: phone.menuBar)
        }
        .menuBarExtraStyle(.window)

        Window("Conversation", id: "conversation") {
            ConversationView(phone: phone)
        }
        .defaultSize(width: 680, height: 620)
        .windowResizability(.contentMinSize)

        Window("Set Up Phone", id: "setup") {
            SetupWizard(phone: phone)
        }
        .defaultSize(width: 620, height: 520)
        .windowResizability(.contentSize)

        Settings {
            PhoneSettingsView(phone: phone)
        }
    }
}

private struct MenuBarPhoneLabel: View {
    @ObservedObject var model: MenuBarModel
    @Environment(\.openWindow) private var openWindow

    private var state: CallState { model.state }
    private var callStartedAt: Date? { model.callStartedAt }

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
        .onAppear {
            if model.setupRequest > 0 { openSetup() }
        }
        .onChange(of: model.setupRequest) { _, request in
            if request > 0 { openSetup() }
        }
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

    private func openSetup() {
        openWindow(id: "setup")
        NSApp.activate(ignoringOtherApps: true)
        model.setupRequest = 0
    }
}
