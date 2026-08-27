import Foundation

enum CallState: Equatable {
    case stopped
    case starting
    case ready
    case ringing(String?)
    case dialing(String)
    case answering(String?)
    case connected(String?)
    case error(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isRinging: Bool {
        if case .ringing = self { return true }
        return false
    }

    var isInCall: Bool {
        switch self {
        case .dialing, .answering, .connected: true
        default: false
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var peer: String? {
        switch self {
        case .ringing(let peer), .answering(let peer), .connected(let peer): peer
        case .dialing(let peer): peer
        default: nil
        }
    }

    var label: String {
        switch self {
        case .stopped: "Phone is off"
        case .starting: "Registering SIP …"
        case .ready: "Ready"
        case .ringing(let peer): peer.map { "Call from \($0)" } ?? "Incoming call"
        case .dialing(let peer): "Calling \(peer)"
        case .answering: "Connecting …"
        case .connected(let peer): peer.map { "Connected to \($0)" } ?? "Connected"
        case .error(let message): message
        }
    }

    var symbol: String {
        switch self {
        case .stopped: "phone"
        case .starting: "phone.badge.clock"
        case .ready: "phone.fill"
        case .ringing: "phone.arrow.down.left.fill"
        case .dialing: "phone.arrow.up.right.fill"
        case .answering, .connected: "phone.connection.fill"
        case .error: "phone.badge.exclamationmark"
        }
    }
}

enum Speaker: UInt8, Codable, Sendable {
    case me = 1
    case caller = 2

    var title: String { self == .me ? "Me" : "Caller" }
}

struct TranscriptEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let speaker: Speaker
    var text: String
    var isFinal: Bool
    let createdAt: Date
}

struct CallSummary: Equatable, Sendable {
    let text: String
    let createdAt: Date
}
