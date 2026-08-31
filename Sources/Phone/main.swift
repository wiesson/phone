import AppKit
import SwiftUI

@MainActor
final class PhoneAppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: PhoneController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Applied once at launch only: toggling the activation policy at
        // runtime can permanently break the menu bar item.
        if UserDefaults.standard.bool(forKey: "showDockIcon") {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        controller?.handleDialURL(url)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .phoneOpenLibrary, object: nil)
        return true
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

        Window("Phone", id: "library") {
            LibraryView(phone: phone, store: phone.store)
        }
        .defaultSize(width: 1_100, height: 700)
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

    var body: some View {
        // Fixed-size, icon-only label: a menu bar item whose size or image
        // changes while a call ticks can trip AppKit into an endless
        // setImage/_adjustLength layout loop that saturates the main thread.
        Image(systemName: model.state.symbol)
            .frame(width: 24, height: 17)
            .accessibilityLabel(model.state.label)
            .task {
                if model.setupRequest > 0 { openSetup() }
                if model.libraryRequest > 0 { openLibrary(clearingRequest: true) }
            }
            .onChange(of: model.setupRequest) { _, request in
                if request > 0 { openSetup() }
            }
            .onChange(of: model.libraryRequest) { _, request in
                if request > 0 { openLibrary(clearingRequest: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .phoneOpenLibrary)) { _ in
                openLibrary()
            }
            .onChange(of: model.state.isConnected) { wasConnected, isConnected in
                // One window for everything: a connected call brings the call
                // list forward, where the live call owns the detail pane.
                if !wasConnected && isConnected { openLibrary() }
            }
    }

    private func openLibrary(clearingRequest: Bool = false) {
        openWindow(id: "library")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.windows.first { $0.identifier?.rawValue.contains("library") == true }?
                .orderFrontRegardless()
        }
        if clearingRequest {
            Task { @MainActor in model.libraryRequest = 0 }
        }
    }

    private func openSetup() {
        openWindow(id: "setup")
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in model.setupRequest = 0 }
    }
}
