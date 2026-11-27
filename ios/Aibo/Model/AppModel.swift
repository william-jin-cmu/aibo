import Foundation
import Observation
import SwiftUI
import WidgetKit

@Observable
@MainActor
final class AppModel {
    enum Phase: Equatable { case launching, signedOut, onboarding, ready, failed(String) }

    var phase: Phase = .launching
    var characterName = "小黑鱼"
    var userName: String?
    /// The signed-in account; its cloud agent is the one we talk to.
    var account: Account?
    var memories: [Memory] = []
    var lists: [CompanionList] = []
    var sources: [SourceState] = []

    var messages: [ChatMessage] = []
    var streamingText: String?
    var sending = false
    var stage: StageState = .idle
    var composerFocused = false { didSet { updateIdleStage() } }
    var lastError: String?

    var today: TodayBrief?
    /// Last health snapshot read on this device (for the Today tab's tiles).
    var lastHealth: HealthSnapshot?
    var loadingToday = false
    /// The "today" card sits under the conversation when the user comes back after a while.
    var showTodayCard = false

    let health = HealthConnector()
    let calendar = CalendarConnector()
    let location = LocationConnector()

    private let api = API.shared
    private var didReset = false
    private var settleTask: Task<Void, Never>?
    private static let segmentGap: TimeInterval = 4 * 3600

    // MARK: lifecycle

    init() {
        NotificationCenter.default.addObserver(forName: API.sessionEnded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearLocal() }
        }
    }

    func boot() async {
        if DemoData.reset, !didReset {
            // UI tests start signed out with no connectors.
            didReset = true
            api.forget()
            clearConnectors()
        }
        guard api.isSignedIn else {
            phase = .signedOut
            return
        }
        do {
            account = try await api.me()
            try await refreshState()
            if !isOnboarded {
                phase = .onboarding
                return
            }
            phase = .ready
            await loadMessages()
            await syncConnectors()
            await loadToday()
        } catch let e as APIError where e.status == 401 {
            phase = .signedOut
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: account

    func sendCode(to email: String) async throws {
        try await api.sendCode(to: email)
    }

    func verify(email: String, code: String) async throws {
        await signedIn(try await api.verify(email: email, code: code))
    }

    func signInWithApple(identityToken: String, name: String?) async throws {
        await signedIn(try await api.signInWithApple(identityToken: identityToken, name: name))
    }

    private func signedIn(_ result: AuthResult) async {
        account = result.user
        if DemoData.reset {
            // UI tests reuse one test account: give it a fresh agent each run.
            try? await api.call("/v1/agent", method: "DELETE")
        }
        phase = .launching
        await boot()
    }

    func signOut() async {
        await api.signOut()
        clearLocal()
    }

    func deleteAccount() async {
        do {
            try await api.deleteAccount()
            clearLocal()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func clearConnectors() {
        for id in ConnectorID.allCases {
            UserDefaults.standard.removeObject(forKey: "connector.\(id.rawValue)")
            UserDefaults.standard.removeObject(forKey: "connector.\(id.rawValue).syncedAt")
        }
        connected = []
    }

    /// Back to the sign-in screen with nothing of the last account left in memory.
    private func clearLocal() {
        clearConnectors()
        account = nil
        messages = []
        memories = []
        lists = []
        sources = []
        today = nil
        lastHealth = nil
        userName = nil
        onboardedAt = nil
        streamingText = nil
        showTodayCard = false
        CompanionSnapshot.placeholder.save()
        WidgetCenter.shared.reloadAllTimelines()
        phase = .signedOut
    }

    /// Called when the app returns to the foreground.
    func resume() async {
        guard phase == .ready else { return }
        await syncConnectors()
        if let last = messages.last, Date().timeIntervalSince(last.date) > Self.segmentGap { showTodayCard = true }
        if showTodayCard { await loadToday() }
    }

    var isOnboarded: Bool { onboardedAt != nil }
    private var onboardedAt: String?

    func refreshState() async throws {
        let s = try await api.state()
        characterName = s.character.name
        userName = s.profile["userName"]
        onboardedAt = s.profile["onboardedAt"]
        memories = s.memories
        lists = s.lists
        sources = s.sources
    }

    func loadMessages() async {
        do {
            messages = try await api.messages()
            let gap = messages.last.map { Date().timeIntervalSince($0.date) } ?? .infinity
            showTodayCard = gap > Self.segmentGap
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadToday(refresh: Bool = false) async {
        guard !loadingToday else { return }
        loadingToday = true
        defer { loadingToday = false }
        do {
            let brief = try await api.today(refresh: refresh)
            today = brief
            publishWidget(line: brief.greeting, mood: "happy")
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: onboarding

    func setName(_ name: String) async {
        userName = name
        try? await api.updateProfile(["userName": name])
    }

    func finishOnboarding() async {
        let stamp = ISO8601DateFormatter().string(from: .now)
        try? await api.updateProfile(["onboardedAt": stamp])
        onboardedAt = stamp
        phase = .ready
        showTodayCard = true
        await loadMessages()
        showTodayCard = true
        await loadToday(refresh: true)
    }

    func insights() async throws -> Insights { try await api.insights() }

    func keepMemory(_ text: String) async {
        if let m = try? await api.addMemory(text, origin: "onboarding") { memories.append(m) }
    }

    // MARK: chat

    func send(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        showTodayCard = false
        lastError = nil
        settleTask?.cancel()
        let tempId = -(messages.count + 1)
        let segment = messages.last?.segment ?? 1
        messages.append(ChatMessage(id: tempId, role: "user", content: text, mood: nil, kind: "chat", segment: segment, createdAt: Date().timeIntervalSince1970 * 1000))
        streamingText = ""
        stage = .reading

        do {
            for try await event in api.chat(text) {
                switch event {
                case .ack(let id):
                    if let i = messages.firstIndex(where: { $0.id == tempId }) { messages[i].id = id }
                case .stage(let s):
                    if let st = StageState(rawValue: s) { withAnimation(.easeInOut(duration: 0.35)) { stage = st } }
                case .text(let delta):
                    streamingText = (streamingText ?? "") + delta
                case .tool:
                    break
                case .memory(let m):
                    memories.append(m)
                case .memoryRemoved(let id):
                    memories.removeAll { $0.id == id }
                case .list:
                    Task { try? await self.refreshState() }
                case .done(let msg):
                    messages.append(msg)
                    streamingText = nil
                    publishWidget(line: msg.content, mood: msg.mood ?? "neutral")
                    settle(to: StageState.forMood(msg.mood))
                case .error(let message):
                    lastError = message
                    streamingText = nil
                    settle(to: .failed)
                }
            }
        } catch {
            lastError = error.localizedDescription
            streamingText = nil
            settle(to: .failed)
        }
        sending = false
    }

    /// Holds the reply's mood for a beat, then drifts back to idle.
    private func settle(to state: StageState) {
        withAnimation(.easeInOut(duration: 0.35)) { stage = state }
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.updateIdleStage(force: true)
        }
    }

    private func updateIdleStage(force: Bool = false) {
        guard !sending else { return }
        if !force, settleTask != nil, stage != .idle, stage != .listening { return }
        withAnimation(.easeInOut(duration: 0.35)) { stage = composerFocused ? .listening : .idle }
    }

    // MARK: memories & lists

    func deleteMemory(_ m: Memory) async {
        memories.removeAll { $0.id == m.id }
        try? await api.call("/v1/memories/\(m.id)", method: "DELETE")
    }

    func editMemory(_ m: Memory, text: String) async {
        if let i = memories.firstIndex(of: m) { memories[i].text = text }
        try? await api.call("/v1/memories/\(m.id)", method: "PATCH", body: ["text": text])
    }

    func addMemory(_ text: String) async {
        if let m = try? await api.addMemory(text, origin: "user") { memories.append(m) }
    }

    func toggle(_ item: ListItem, in list: CompanionList) async {
        guard let li = lists.firstIndex(of: list), let ii = lists[li].items.firstIndex(of: item) else { return }
        lists[li].items[ii].done.toggle()
        try? await api.call("/v1/lists/\(list.id)/items/\(item.id)", method: "PATCH", body: ["done": !item.done])
    }

    func deleteList(_ list: CompanionList) async {
        lists.removeAll { $0.id == list.id }
        try? await api.call("/v1/lists/\(list.id)", method: "DELETE")
    }

    // MARK: connectors

    /// Mirrors the per-connector UserDefaults flags so views redraw when one changes.
    private(set) var connected: Set<ConnectorID> = Set(ConnectorID.allCases.filter { UserDefaults.standard.bool(forKey: "connector.\($0.rawValue)") })

    func isConnected(_ id: ConnectorID) -> Bool { connected.contains(id) }

    private func setConnected(_ id: ConnectorID, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "connector.\(id.rawValue)")
        if on { connected.insert(id) } else { connected.remove(id) }
    }

    func isShared(_ id: ConnectorID) -> Bool {
        sources.first { $0.id == id.rawValue }?.shared ?? true
    }

    func source(_ id: ConnectorID) -> SourceState? { sources.first { $0.id == id.rawValue } }

    /// Asks for the permission and pushes a first snapshot. Returns whether data was shared.
    @discardableResult
    func connect(_ id: ConnectorID) async -> Bool {
        do {
            if DemoData.enabled {
                // Simulator demo: no permission sheets, canned data.
            } else {
            switch id {
            case .health: try await health.requestAccess()
            case .calendar: try await calendar.requestAccess()
            case .location: await location.requestAccess()
            }
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }
        setConnected(id, true)
        let ok = await push(id)
        try? await refreshState()
        return ok
    }

    func disconnect(_ id: ConnectorID) async {
        setConnected(id, false)
        sources.removeAll { $0.id == id.rawValue }
        try? await api.call("/v1/sources/\(id.rawValue)", method: "DELETE")
    }

    func setShared(_ id: ConnectorID, _ shared: Bool) async {
        if let i = sources.firstIndex(where: { $0.id == id.rawValue }) { sources[i].shared = shared }
        try? await api.call("/v1/sources/\(id.rawValue)", method: "PATCH", body: ["shared": shared])
    }

    /// Re-reads connected sources at most every 30 minutes.
    func syncConnectors(force: Bool = false) async {
        var changed = false
        for id in ConnectorID.allCases where isConnected(id) {
            let key = "connector.\(id.rawValue).syncedAt"
            let last = UserDefaults.standard.double(forKey: key)
            if !force, Date().timeIntervalSince1970 - last < 30 * 60 { continue }
            if await push(id) { changed = true }
        }
        if changed { try? await refreshState() }
    }

    @discardableResult
    private func push(_ id: ConnectorID) async -> Bool {
        do {
            switch id {
            case .health:
                let snap = DemoData.enabled ? DemoData.health : try await health.snapshot()
                lastHealth = snap
                try await api.pushSource("health", snapshot: snap)
            case .calendar:
                let snap = DemoData.enabled ? DemoData.calendar : await calendar.snapshot()
                try await api.pushSource("calendar", snapshot: snap)
                if let next = snap.events.first(where: { !$0.allDay }) {
                    var s = CompanionSnapshot.load()
                    s.nextEvent = "\(next.start.suffix(5)) \(next.title)"
                    s.save()
                }
            case .location:
                guard let snap = DemoData.enabled ? DemoData.location : await location.snapshot() else { return false }
                try await api.pushSource("location", snapshot: snap)
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "connector.\(id.rawValue).syncedAt")
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Today's events for the Today tab (device calendar, or demo data in the simulator).
    func todayEvents() -> [DemoData.Event] {
        if DemoData.enabled { return DemoData.todayEvents }
        return calendar.todayEvents().map { .init(title: $0.title ?? "Untitled", start: $0.startDate, allDay: $0.isAllDay, location: $0.location) }
    }

    // MARK: widget

    private func publishWidget(line: String, mood: String) {
        var s = CompanionSnapshot.load()
        s.line = spokenPart(of: line)
        s.mood = mood
        if let w = today?.weather { s.weather = "\(w.temp)° \(w.condition)" }
        s.updatedAt = .now
        s.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// "Start over": wipes her memory of you (conversation, memories, lists, shared data) but keeps the account.
    func resetEverything() async {
        try? await api.call("/v1/agent", method: "DELETE")
        clearConnectors()
        messages = []
        memories = []
        lists = []
        sources = []
        today = nil
        userName = nil
        onboardedAt = nil
        phase = .launching
        await boot()
    }
}
