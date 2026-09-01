import Darwin
import Foundation
import PhoneAutomation

enum PhoneControlClient {
    static var socketPath: String {
        PhoneControlSocket.url().path
    }

    static func call(tool: String, arguments: [String: JSONValue]) -> ControlResponse {
        guard let request = MCPProtocol.controlRequest(tool: tool, arguments: arguments) else {
            return .failure(ControlError(code: "invalid_request", message: "The control request could not be encoded."))
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return .failure(ControlError(code: "unavailable", message: "Phone is not running."))
        }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            return .failure(ControlError(code: "unavailable", message: "Phone control socket path is too long."))
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            return .failure(ControlError(code: "unavailable", message: "Phone is not running."))
        }
        var output = request
        output.append(0x0A)
        let wroteAll = output.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.send(fd, base.advanced(by: sent), bytes.count - sent, MSG_NOSIGNAL)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
        guard wroteAll else {
            return .failure(ControlError(code: "unavailable", message: "Phone control request failed."))
        }
        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while responseData.count <= 65_536 {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            responseData.append(contentsOf: buffer.prefix(count))
            if let newline = responseData.firstIndex(of: 0x0A) {
                responseData = responseData.prefix(upTo: newline)
                break
            }
        }
        guard let response = try? JSONDecoder().decode(ControlResponse.self, from: responseData) else {
            return .failure(ControlError(code: "invalid_response", message: "Phone returned an invalid control response."))
        }
        return response
    }
}

@main
struct PhoneMCPServer {
    static func main() {
        while let line = readLine() {
            guard let request = line.data(using: .utf8),
                  let response = MCPProtocol.response(for: request, callTool: PhoneControlClient.call) else { continue }
            var output = response
            output.append(0x0A)
            try? FileHandle.standardOutput.write(contentsOf: output)
        }
    }
}
