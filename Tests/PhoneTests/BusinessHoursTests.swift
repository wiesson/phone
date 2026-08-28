import Foundation
import Testing
@testable import Phone

private let businessHoursTestCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

private func businessHoursTestDate(
    year: Int = 2026,
    month: Int = 1,
    day: Int,
    hour: Int,
    minute: Int = 0
) -> Date {
    businessHoursTestCalendar.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    )!
}

@Test func businessHoursUseWeekdayAndWeekendGroups() {
    let schedule = BusinessHoursSchedule(
        weekdays: .init(open: true, start: 9 * 60, end: 17 * 60),
        weekend: .init(open: true, start: 11 * 60, end: 13 * 60)
    )

    #expect(isWithinBusinessHours(
        date: businessHoursTestDate(day: 9, hour: 10),
        calendar: businessHoursTestCalendar,
        schedule: schedule
    ))
    #expect(!isWithinBusinessHours(
        date: businessHoursTestDate(day: 10, hour: 10),
        calendar: businessHoursTestCalendar,
        schedule: schedule
    ))
    #expect(isWithinBusinessHours(
        date: businessHoursTestDate(day: 10, hour: 11),
        calendar: businessHoursTestCalendar,
        schedule: schedule
    ))
    #expect(isWithinBusinessHours(
        date: businessHoursTestDate(day: 11, hour: 12),
        calendar: businessHoursTestCalendar,
        schedule: schedule
    ))
}

@Test func businessHoursUseStartInclusiveAndEndExclusiveBoundaries() {
    let schedule = BusinessHoursSchedule()

    #expect(!isWithinBusinessHours(
        date: businessHoursTestDate(day: 5, hour: 8, minute: 59),
        calendar: businessHoursTestCalendar,
        schedule: schedule
    ))
    #expect(isWithinBusinessHours(
        date: businessHoursTestDate(day: 5, hour: 9),
        calendar: businessHoursTestCalendar,
        schedule: schedule
    ))
    #expect(isWithinBusinessHours(
        date: businessHoursTestDate(day: 5, hour: 16, minute: 59),
        calendar: businessHoursTestCalendar,
        schedule: schedule
    ))
    #expect(!isWithinBusinessHours(
        date: businessHoursTestDate(day: 5, hour: 17),
        calendar: businessHoursTestCalendar,
        schedule: schedule
    ))
}

@Test func closedBusinessHoursGroupsAreNeverAttended() {
    let schedule = BusinessHoursSchedule(
        weekdays: .init(open: false, start: 0, end: 0),
        weekend: .init(open: false, start: 0, end: 0)
    )

    #expect(!isWithinBusinessHours(
        date: businessHoursTestDate(day: 5, hour: 12),
        calendar: businessHoursTestCalendar,
        schedule: schedule
    ))
    #expect(!isWithinBusinessHours(
        date: businessHoursTestDate(day: 10, hour: 12),
        calendar: businessHoursTestCalendar,
        schedule: schedule
    ))
}

@Test func businessHoursCanCrossMidnight() {
    let schedule = BusinessHoursSchedule(
        weekdays: .init(open: true, start: 22 * 60, end: 6 * 60),
        weekend: .init(open: false, start: 9 * 60, end: 17 * 60)
    )

    #expect(isWithinBusinessHours(
        date: businessHoursTestDate(day: 5, hour: 22),
        calendar: businessHoursTestCalendar,
        schedule: schedule
    ))
    #expect(isWithinBusinessHours(
        date: businessHoursTestDate(day: 6, hour: 5, minute: 59),
        calendar: businessHoursTestCalendar,
        schedule: schedule
    ))
    #expect(!isWithinBusinessHours(
        date: businessHoursTestDate(day: 6, hour: 6),
        calendar: businessHoursTestCalendar,
        schedule: schedule
    ))
    #expect(!isWithinBusinessHours(
        date: businessHoursTestDate(day: 10, hour: 2),
        calendar: businessHoursTestCalendar,
        schedule: schedule
    ))
}

@Test func businessHoursScheduleRoundTripsThroughJSON() throws {
    let schedule = BusinessHoursSchedule(
        weekdays: .init(open: true, start: 8 * 60 + 30, end: 16 * 60 + 45),
        weekend: .init(open: false, start: 10 * 60, end: 14 * 60)
    )

    let data = try JSONEncoder().encode(schedule)
    #expect(try JSONDecoder().decode(BusinessHoursSchedule.self, from: data) == schedule)
}

@Test func migratesLegacyAssistantAnswerBooleanToModeExactlyOnce() throws {
    for legacyValue in [false, true] {
        let suiteName = "BusinessHoursTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(legacyValue, forKey: "assistantAnswersIncomingCalls")

        let expectedMode: AssistantAnswerMode = legacyValue ? .always : .never
        #expect(migrateAssistantAnswerMode(defaults: defaults) == expectedMode)
        #expect(defaults.string(forKey: assistantAnswerModeDefaultsKey) == expectedMode.rawValue)
        #expect(defaults.bool(forKey: assistantAnswerModeMigrationDefaultsKey))

        defaults.set(!legacyValue, forKey: "assistantAnswersIncomingCalls")
        defaults.set(AssistantAnswerMode.outsideBusinessHours.rawValue, forKey: assistantAnswerModeDefaultsKey)
        #expect(migrateAssistantAnswerMode(defaults: defaults) == .outsideBusinessHours)
    }
}
