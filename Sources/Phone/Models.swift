import Combine
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

enum RegistrationStatus: Equatable {
    case idle
    case registering
    case registered
    case failed(String)
}

/// Tiny observable model for the menu bar label, so the label only re-renders
/// on call state changes and not on every transcript update.
@MainActor
final class MenuBarModel: ObservableObject {
    @Published var state: CallState = .stopped
    @Published var callStartedAt: Date?
    @Published var setupRequest = 0
}

enum Speaker: UInt8, Codable, Sendable {
    case me = 1
    case caller = 2

    var title: String { self == .me ? "Me" : "Caller" }
}

struct TranscriptEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let speaker: Speaker
    var text: String
    var isFinal: Bool
    var isAssistant: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        speaker: Speaker,
        text: String,
        isFinal: Bool,
        isAssistant: Bool = false,
        createdAt: Date
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.isFinal = isFinal
        self.isAssistant = isAssistant
        self.createdAt = createdAt
    }

    var speakerTitle: String { isAssistant ? "Assistant" : speaker.title }
}

struct CallSummary: Equatable, Sendable {
    let text: String
    let createdAt: Date
}

enum CallDirection: String, Codable, Sendable {
    case incoming
    case outgoing
}

struct CallRecord: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    let direction: CallDirection
    let peer: String?
    let date: Date
    let duration: TimeInterval
    let missed: Bool
}

enum AssistantAnswerMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case never
    case always
    case outsideBusinessHours

    var id: Self { self }
}

struct BusinessHoursSchedule: Codable, Equatable, Sendable {
    struct DayGroup: Codable, Equatable, Sendable {
        var open: Bool
        var start: Int
        var end: Int
    }

    var weekdays: DayGroup
    var weekend: DayGroup

    init(
        weekdays: DayGroup = DayGroup(open: true, start: 9 * 60, end: 17 * 60),
        weekend: DayGroup = DayGroup(open: false, start: 9 * 60, end: 17 * 60)
    ) {
        self.weekdays = weekdays
        self.weekend = weekend
    }
}

let assistantAnswerModeDefaultsKey = "assistantAnswerMode"
let assistantAnswerModeMigrationDefaultsKey = "didMigrateAssistantAnswersIncomingCalls"
let businessHoursDefaultsKey = "businessHours"

@discardableResult
func migrateAssistantAnswerMode(defaults: UserDefaults) -> AssistantAnswerMode {
    if defaults.bool(forKey: assistantAnswerModeMigrationDefaultsKey) {
        return defaults.string(forKey: assistantAnswerModeDefaultsKey)
            .flatMap(AssistantAnswerMode.init(rawValue:)) ?? .never
    }

    let mode: AssistantAnswerMode
    if let stored = defaults.string(forKey: assistantAnswerModeDefaultsKey),
       let existingMode = AssistantAnswerMode(rawValue: stored) {
        mode = existingMode
    } else if let legacyValue = defaults.object(forKey: "assistantAnswersIncomingCalls") as? Bool {
        mode = legacyValue ? .always : .never
    } else {
        mode = .never
    }

    defaults.set(mode.rawValue, forKey: assistantAnswerModeDefaultsKey)
    defaults.set(true, forKey: assistantAnswerModeMigrationDefaultsKey)
    return mode
}

func storedAssistantAnswerMode(defaults: UserDefaults) -> AssistantAnswerMode {
    migrateAssistantAnswerMode(defaults: defaults)
}

func storedBusinessHoursSchedule(defaults: UserDefaults) -> BusinessHoursSchedule {
    guard let data = defaults.data(forKey: businessHoursDefaultsKey),
          let schedule = try? JSONDecoder().decode(BusinessHoursSchedule.self, from: data) else {
        return BusinessHoursSchedule()
    }
    return schedule
}

func isWithinBusinessHours(
    date: Date,
    calendar: Calendar,
    schedule: BusinessHoursSchedule
) -> Bool {
    let weekday = calendar.component(.weekday, from: date)
    let group = weekday == 1 || weekday == 7 ? schedule.weekend : schedule.weekdays
    guard group.open else { return false }

    let components = calendar.dateComponents([.hour, .minute], from: date)
    let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
    if group.end > group.start {
        return minute >= group.start && minute < group.end
    }
    return minute >= group.start || minute < group.end
}
