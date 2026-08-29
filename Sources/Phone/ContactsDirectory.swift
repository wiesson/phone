import Combine
import Contacts
import Foundation

let useSystemContactsDefaultsKey = "useSystemContacts"

func useSystemContacts(defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: useSystemContactsDefaultsKey) as? Bool ?? true
}

struct ContactsDirectoryEntry: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let number: String
    let label: String

    fileprivate var indexedName: String {
        displayName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

@MainActor
final class ContactsDirectory: ObservableObject {
    @Published private(set) var entries: [ContactsDirectoryEntry] = []

    private let store: CNContactStore
    private let defaults: UserDefaults
    private var exactIndex: [String: String] = [:]
    private var suffixIndex: [String: String] = [:]
    private var accessStarted = false
    private var loggedDenial = false
    private var changeCancellable: AnyCancellable?

    init(store: CNContactStore = CNContactStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        changeCancellable = NotificationCenter.default.publisher(for: .CNContactStoreDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshAfterStoreChange() }
            }
    }

    func displayName(for phoneNumber: String, requestsAccess: Bool = true) -> String? {
        guard useSystemContacts(defaults: defaults) else { return nil }
        if requestsAccess { startAccessIfNeeded() }
        let normalized = normalizedPhoneNumber(phoneNumber)
        guard !normalized.isEmpty else { return nil }
        if let exact = exactIndex[normalized] { return exact }
        let digits = normalized.filter(\.isNumber)
        guard digits.count >= 9 else { return nil }
        return suffixIndex[String(digits.suffix(9))]
    }

    func search(matching query: String, limit: Int = 8) -> [ContactsDirectoryEntry] {
        guard useSystemContacts(defaults: defaults), dialInputRequestsContactSearch(query) else { return [] }
        startAccessIfNeeded()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return entries
            .filter { $0.indexedName.contains(needle) }
            .sorted { left, right in
                let leftPrefix = left.indexedName.hasPrefix(needle)
                let rightPrefix = right.indexedName.hasPrefix(needle)
                if leftPrefix != rightPrefix { return leftPrefix }
                if left.displayName != right.displayName {
                    return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
                }
                return left.number < right.number
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    func settingsDidChange() {
        guard !useSystemContacts(defaults: defaults) else {
            objectWillChange.send()
            return
        }
        entries = []
        accessStarted = false
        exactIndex = [:]
        suffixIndex = [:]
    }

    private func startAccessIfNeeded() {
        guard !accessStarted else { return }
        accessStarted = true
        Task { await requestAccessAndRefresh() }
    }

    private func requestAccessAndRefresh() async {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            refreshIndex()
        case .notDetermined:
            do {
                if try await store.requestAccess(for: .contacts) {
                    refreshIndex()
                } else {
                    logDenialOnce()
                }
            } catch {
                logDenialOnce()
            }
        case .denied, .restricted:
            logDenialOnce()
        @unknown default:
            logDenialOnce()
        }
    }

    private func refreshAfterStoreChange() {
        guard accessStarted, useSystemContacts(defaults: defaults),
              CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
        refreshIndex()
    }

    private func refreshIndex() {
        guard useSystemContacts(defaults: defaults) else { return }
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var fetched: [ContactsDirectoryEntry] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let personName = [contact.givenName, contact.familyName]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let organization = contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = personName.isEmpty ? organization : personName
                guard !displayName.isEmpty else { return }
                for (index, labeledNumber) in contact.phoneNumbers.enumerated() {
                    let number = labeledNumber.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalizedPhoneNumber(number).isEmpty else { continue }
                    let label = labeledNumber.label.map(CNLabeledValue<NSString>.localizedString(forLabel:)) ?? "Phone"
                    fetched.append(ContactsDirectoryEntry(
                        id: "\(contact.identifier)-\(index)",
                        displayName: displayName,
                        number: number,
                        label: label
                    ))
                }
            }
        } catch {
            phoneDiagnosticLog("phone-app: macOS Contacts refresh failed\n")
            return
        }

        var exact: [String: String] = [:]
        var suffixNames: [String: Set<String>] = [:]
        for entry in fetched {
            let normalized = normalizedPhoneNumber(entry.number)
            exact[normalized, default: entry.displayName] = entry.displayName
            let digits = normalized.filter(\.isNumber)
            if digits.count >= 9 {
                suffixNames[String(digits.suffix(9)), default: []].insert(entry.displayName)
            }
        }
        exactIndex = exact
        suffixIndex = suffixNames.reduce(into: [:]) { result, item in
            if item.value.count == 1 { result[item.key] = item.value.first }
        }
        entries = fetched
    }

    private func logDenialOnce() {
        guard !loggedDenial else { return }
        loggedDenial = true
        phoneDiagnosticLog("phone-app: macOS Contacts access denied; contact lookup disabled\n")
    }
}
