import Foundation

/// Debug-only stand-ins for connectors, so the simulator (which has no Health data
/// or calendar) can run the full flow end to end. Enabled with `-AiboDemoData`.
enum DemoData {
    #if DEBUG
    static let enabled = ProcessInfo.processInfo.arguments.contains("-AiboDemoData")
    /// Wipes the token and local flags so onboarding starts fresh (`-AiboReset`).
    static let reset = ProcessInfo.processInfo.arguments.contains("-AiboReset")
    #else
    static let enabled = false
    static let reset = false
    #endif

    private static func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: .now))!
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.string(from: d)
    }

    static var health: HealthSnapshot {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let rows: [(Int, Double, String, String, Int)] = [
            (8900, 6.8, "00:50", "08:00", 62), (12100, 7.5, "23:55", "08:30", 61), (3100, 5.4, "02:10", "08:05", 64),
            (5600, 6.3, "01:15", "08:10", 63), (6100, 6.0, "01:40", "08:15", 63), (4800, 5.9, "01:50", "08:20", 64),
            (7200, 6.6, "01:05", "08:05", 62),
        ]
        let days = rows.enumerated().map { i, r in
            HealthDay(date: f.string(from: day(i - rows.count + 1)), steps: r.0, sleepHours: r.1, bedtime: r.2, wakeTime: r.3, restingHR: r.4, activeEnergy: r.0 / 25)
        }
        return HealthSnapshot(days: days, workouts: [.init(date: f.string(from: day(-5)), type: "Running", minutes: 32)])
    }

    struct Event { var title: String; var start: Date; var allDay: Bool; var location: String? }

    static var todayEvents: [Event] {
        let t = day(0)
        return [
            Event(title: "Design review", start: t.addingTimeInterval(11 * 3600), allDay: false, location: "Zoom"),
            Event(title: "Lunch with Mia", start: t.addingTimeInterval(12.5 * 3600), allDay: false, location: "Wulumuqi Rd"),
            Event(title: "Yoga", start: t.addingTimeInterval(19 * 3600), allDay: false, location: nil),
        ]
    }

    static var calendar: CalendarSnapshot {
        var events = todayEvents.map {
            CalendarSnapshot.Event(title: $0.title, start: stamp($0.start), end: nil, allDay: $0.allDay, location: $0.location, calendar: "Personal")
        }
        events.append(.init(title: "Dentist", start: stamp(day(2).addingTimeInterval(10.5 * 3600)), end: nil, allDay: false, location: "Xuhui", calendar: "Personal"))
        events.append(.init(title: "Mom's birthday", start: stamp(day(4)), end: nil, allDay: true, location: nil, calendar: "Family"))
        return CalendarSnapshot(
            events: events,
            reminders: [.init(title: "Pay the electricity bill", due: stamp(day(-1).addingTimeInterval(20 * 3600)), list: "Home", overdue: true)]
        )
    }

    static let location = LocationSnapshot(lat: 31.19, lon: 121.44, place: "Xuhui, Shanghai", timezone: "Asia/Shanghai")
}
