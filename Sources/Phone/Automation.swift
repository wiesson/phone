import Darwin
import Foundation
import PhoneAutomation
import Security

enum WebhookSettingsError: LocalizedError {
    case emptySecret
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptySecret: "Enter a shared secret."
        case .keychain(let status):
            SecCopyErrorMessageString(status, nil).map { ($0 as NSString) as String } ?? "The webhook secret could not be saved in Keychain."
        }
    }
}

enum PhoneWebhookSecretStore {
    static let service = "Phone Webhook"
    static let account = "shared-secret"

    static func save(_ secret: String) throws {
        guard !secret.isEmpty else { throw WebhookSettingsError.emptySecret }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw WebhookSettingsError.keychain(updateStatus) }
        var item = query
        item[kSecValueData as String] = Data(secret.utf8)
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw WebhookSettingsError.keychain(addStatus) }
    }

    static func secret() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let secret = String(data: data, encoding: .utf8),
              !secret.isEmpty else { return nil }
        return secret
    }
}

@MainActor
final class PhoneWebhookTransport {
    var onFailure: ((String) -> Void)?

    func deliver(_ event: PhoneEvent) {
        let defaults = UserDefaults.standard
        let configuredURL = (defaults.string(forKey: "webhookURL") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredURL.isEmpty,
              let url = URL(string: configuredURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let secret = PhoneWebhookSecretStore.secret() else { return }
        let enabled: Bool
        if event.kind.isConversationContent {
            enabled = defaults.object(forKey: "webhookContentEvents") as? Bool ?? false
        } else {
            enabled = defaults.object(forKey: "webhookCallEvents") as? Bool ?? true
        }
        guard enabled, let body = try? event.jsonData() else { return }
        let signature = WebhookSignature.hexDigest(body: body, secret: secret)
        Task { [weak self] in
            let failure = await Self.post(body: body, signature: signature, to: url)
            guard let failure else { return }
            phoneDiagnosticLog("phone-app: webhook event \(event.id) \(event.kind.type) failed: \(failure)\n")
            self?.onFailure?("Webhook delivery failed")
        }
    }

    private static func post(body: Data, signature: String, to url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(signature, forHTTPHeaderField: "X-Phone-Signature")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            }
            return nil
        } catch {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return "delivery cancelled"
            }
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    return "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) after retry"
                }
                return nil
            } catch {
                return "network error after retry"
            }
        }
    }
}

final class PhoneControlServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "phone.control-server", qos: .userInitiated)
    private var descriptor: Int32 = -1
    private var running = false
    private var socketPath = ""
    var onCommand: (@Sendable (ControlCommand) async -> ControlResponse)?

    func start(at path: String) throws {
        guard !running else { return }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOTSOCK) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, mode_t(0o600)) == 0, listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
        socketPath = path
        running = true
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        running = false
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        if !socketPath.isEmpty { unlink(socketPath) }
    }

    private func acceptLoop() {
        while running {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if running { usleep(10_000) }
                continue
            }
            Task.detached { [weak self] in await self?.handle(client) }
        }
    }

    private func handle(_ client: Int32) async {
        defer { close(client) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= 65_536 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            data.append(contentsOf: buffer.prefix(count))
            if let newline = data.firstIndex(of: 0x0A) {
                data = data.prefix(upTo: newline)
                break
            }
        }
        let response: ControlResponse
        if data.count > 65_536 {
            response = .failure(ControlError(code: "request_too_large", message: "Control request exceeds 64 KiB."))
        } else {
            switch ControlRequestParser.parse(data) {
            case .success(let command):
                if let onCommand { response = await onCommand(command) }
                else { response = .failure(ControlError(code: "unavailable", message: "Phone control is unavailable.")) }
            case .failure(let error):
                response = .failure(error)
            }
        }
        guard var output = try? response.jsonData() else { return }
        output.append(0x0A)
        output.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(client, base.advanced(by: sent), bytes.count - sent, MSG_NOSIGNAL)
                guard count > 0 else { return }
                sent += count
            }
        }
    }

    deinit { stop() }
}
