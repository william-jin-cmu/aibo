import CoreLocation
import EventKit
import Foundation
import HealthKit

/// A phone-native data source. Each one asks for its own permission, reads a
/// compact snapshot on the device and pushes it to the companion.
enum ConnectorID: String, CaseIterable, Identifiable {
    case health, calendar, location
    var id: String { rawValue }

    var title: String {
        switch self {
        case .health: "Apple Health"
        case .calendar: "Calendar & Reminders"
        case .location: "Location"
        }
    }

    var symbol: String {
        switch self {
        case .health: "heart.fill"
        case .calendar: "calendar"
        case .location: "location.fill"
        }
    }

    var emoji: String {
        switch self {
        case .health: "❤️"
        case .calendar: "🗓️"
        case .location: "📍"
        }
    }

    var pitch: String {
        switch self {
        case .health: "Sleep, steps, heart rate and workouts, so she notices how you're really doing."
        case .calendar: "What's coming up and what's overdue, so nothing sneaks up on you."
        case .location: "Your city, for weather and the time of day where you are."
        }
    }
}

// MARK: - Snapshots (mirror server/src/sources.ts)

struct HealthDay: Codable {
    var date: String
    var steps: Int?
    var sleepHours: Double?
    var bedtime: String?
    var wakeTime: String?
    var restingHR: Int?
    var activeEnergy: Int?
}

struct HealthSnapshot: Codable {
    var days: [HealthDay]
    var workouts: [Workout]
    struct Workout: Codable { var date: String; var type: String; var minutes: Int }
}

struct CalendarSnapshot: Codable {
    struct Event: Codable { var title: String; var start: String; var end: String?; var allDay: Bool; var location: String?; var calendar: String? }
    struct Reminder: Codable { var title: String; var due: String?; var list: String?; var overdue: Bool }
    var events: [Event]
    var reminders: [Reminder]
}

struct LocationSnapshot: Codable {
    var lat: Double
    var lon: Double
    var place: String?
    var timezone: String?
}

// MARK: - Formatting helpers

private let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private let localStamp: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm"
    return f
}()

private let clock: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm"
    return f
}()

// MARK: - Health

final class HealthConnector {
    private let store = HKHealthStore()

    private var readTypes: Set<HKObjectType> {
        [
            HKQuantityType(.stepCount),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.activeEnergyBurned),
            HKCategoryType(.sleepAnalysis),
            HKObjectType.workoutType(),
        ]
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAccess() async throws {
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    func snapshot(days: Int = 14) async throws -> HealthSnapshot {
        let cal = Calendar.current
        let end = Date()
        let start = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: end))!

        async let steps = dailySum(.stepCount, unit: .count(), from: start, to: end)
        async let energy = dailySum(.activeEnergyBurned, unit: .kilocalorie(), from: start, to: end)
        async let hr = dailyAverage(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: start, to: end)
        async let sleep = sleepByDay(from: start, to: end)
        async let workouts = recentWorkouts(from: start)

        let (s, e, h, sl, w) = try await (steps, energy, hr, sleep, workouts)
        var out: [HealthDay] = []
        var d = start
        while d <= end {
            let key = dayFormatter.string(from: d)
            let night = sl[key]
            let day = HealthDay(
                date: key,
                steps: s[key].map { Int($0) },
                sleepHours: night.map { ($0.asleep / 3600 * 10).rounded() / 10 },
                bedtime: night.map { clock.string(from: $0.bed) },
                wakeTime: night.map { clock.string(from: $0.wake) },
                restingHR: h[key].map { Int($0.rounded()) },
                activeEnergy: e[key].map { Int($0) }
            )
            if day.steps != nil || day.sleepHours != nil || day.restingHR != nil { out.append(day) }
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        return HealthSnapshot(days: out, workouts: w)
    }

    private func dailyStats(_ id: HKQuantityTypeIdentifier, options: HKStatisticsOptions, from: Date, to: Date) async throws -> HKStatisticsCollection {
        let type = HKQuantityType(id)
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to)
        return try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsCollectionQuery(
                quantityType: type, quantitySamplePredicate: predicate, options: options,
                anchorDate: Calendar.current.startOfDay(for: from), intervalComponents: DateComponents(day: 1)
            )
            q.initialResultsHandler = { _, result, error in
                if let result { cont.resume(returning: result) } else { cont.resume(throwing: error ?? CancellationError()) }
            }
            store.execute(q)
        }
    }

    private func dailySum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, to: Date) async throws -> [String: Double] {
        let c = try await dailyStats(id, options: .cumulativeSum, from: from, to: to)
        var out: [String: Double] = [:]
        c.enumerateStatistics(from: from, to: to) { s, _ in
            if let v = s.sumQuantity()?.doubleValue(for: unit) { out[dayFormatter.string(from: s.startDate)] = v }
        }
        return out
    }

    private func dailyAverage(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from: Date, to: Date) async throws -> [String: Double] {
        let c = try await dailyStats(id, options: .discreteAverage, from: from, to: to)
        var out: [String: Double] = [:]
        c.enumerateStatistics(from: from, to: to) { s, _ in
            if let v = s.averageQuantity()?.doubleValue(for: unit) { out[dayFormatter.string(from: s.startDate)] = v }
        }
        return out
    }

    /// Groups asleep samples into nights, keyed by the day the user woke up.
    private func sleepByDay(from: Date, to: Date) async throws -> [String: (asleep: TimeInterval, bed: Date, wake: Date)] {
        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: HKCategoryType(.sleepAnalysis),
                predicate: HKQuery.predicateForSamples(withStart: from, end: to),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: results as? [HKCategorySample] ?? []) }
            }
            store.execute(q)
        }
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        var out: [String: (asleep: TimeInterval, bed: Date, wake: Date)] = [:]
        for s in samples where asleepValues.contains(s.value) {
            // A night belongs to the morning after: shifting the start by 12h puts 23:00 and 01:00 starts on the same day.
            let key = dayFormatter.string(from: s.startDate.addingTimeInterval(12 * 3600))
            let dur = s.endDate.timeIntervalSince(s.startDate)
            if var cur = out[key] {
                cur.asleep += dur
                cur.bed = min(cur.bed, s.startDate)
                cur.wake = max(cur.wake, s.endDate)
                out[key] = cur
            } else {
                out[key] = (dur, s.startDate, s.endDate)
            }
        }
        return out
    }

    private func recentWorkouts(from: Date) async throws -> [HealthSnapshot.Workout] {
        let samples: [HKWorkout] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: HKQuery.predicateForSamples(withStart: from, end: Date()),
                limit: 20,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: results as? [HKWorkout] ?? []) }
            }
            store.execute(q)
        }
        return samples.map {
            .init(date: dayFormatter.string(from: $0.startDate), type: $0.workoutActivityType.name, minutes: Int($0.duration / 60))
        }
    }
}

private extension HKWorkoutActivityType {
    var name: String {
        switch self {
        case .running: "Running"
        case .walking: "Walking"
        case .cycling: "Cycling"
        case .swimming: "Swimming"
        case .yoga: "Yoga"
        case .traditionalStrengthTraining, .functionalStrengthTraining: "Strength"
        case .hiking: "Hiking"
        case .highIntensityIntervalTraining: "HIIT"
        default: "Workout"
        }
    }
}

// MARK: - Calendar & Reminders

final class CalendarConnector {
    private let store = EKEventStore()

    var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func requestAccess() async throws {
        _ = try await store.requestFullAccessToEvents()
        _ = try? await store.requestFullAccessToReminders()
    }

    func snapshot(daysAhead: Int = 7) async -> CalendarSnapshot {
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: daysAhead, to: now)!
        var events: [CalendarSnapshot.Event] = []
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            let pred = store.predicateForEvents(withStart: Calendar.current.startOfDay(for: now), end: end, calendars: nil)
            events = store.events(matching: pred).prefix(40).map {
                .init(
                    title: $0.title ?? "Untitled", start: localStamp.string(from: $0.startDate),
                    end: localStamp.string(from: $0.endDate), allDay: $0.isAllDay,
                    location: $0.location?.isEmpty == false ? $0.location : nil, calendar: $0.calendar?.title
                )
            }
        }
        var reminders: [CalendarSnapshot.Reminder] = []
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
            let items: [EKReminder] = await withCheckedContinuation { cont in
                store.fetchReminders(matching: pred) { cont.resume(returning: $0 ?? []) }
            }
            reminders = items.prefix(20).map { r in
                let due = r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                return .init(
                    title: r.title ?? "Untitled", due: due.map { localStamp.string(from: $0) },
                    list: r.calendar?.title, overdue: due.map { $0 < now } ?? false
                )
            }
        }
        return CalendarSnapshot(events: events, reminders: reminders)
    }

    /// Today's events straight from the device, for the Today tab.
    func todayEvents() -> [EKEvent] {
        guard isAuthorized else { return [] }
        let start = Calendar.current.startOfDay(for: .now)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
    }
}

// MARK: - Location

final class LocationConnector: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authContinuation: CheckedContinuation<Void, Never>?
    private var fixContinuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var isAuthorized: Bool {
        [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus)
    }

    @MainActor
    func requestAccess() async {
        guard manager.authorizationStatus == .notDetermined else { return }
        await withCheckedContinuation { cont in
            authContinuation = cont
            manager.requestWhenInUseAuthorization()
        }
    }

    @MainActor
    func snapshot() async -> LocationSnapshot? {
        guard isAuthorized else { return nil }
        let loc: CLLocation? = await withCheckedContinuation { cont in
            fixContinuation = cont
            manager.requestLocation()
        }
        guard let loc else { return nil }
        let mark = try? await CLGeocoder().reverseGeocodeLocation(loc).first
        let place = [mark?.subLocality ?? mark?.locality, mark?.locality == mark?.subLocality ? nil : mark?.locality]
            .compactMap { $0 }.joined(separator: ", ")
        return LocationSnapshot(
            lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
            place: place.isEmpty ? nil : place, timezone: TimeZone.current.identifier
        )
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        authContinuation?.resume()
        authContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        fixContinuation?.resume(returning: locations.last)
        fixContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        fixContinuation?.resume(returning: nil)
        fixContinuation = nil
    }
}
