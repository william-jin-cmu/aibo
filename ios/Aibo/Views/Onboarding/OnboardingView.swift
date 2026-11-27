import UIKit
import SwiftUI
import UserNotifications

/// First meeting, held inside the conversation (as Cue does): she introduces herself,
/// asks your name, asks to see a little of your day, shows what she noticed, and only
/// then asks whether she may say good morning.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var feed: [Line] = []
    @State private var step: Step = .intro
    @State private var typing = false
    @State private var draft = ""
    @State private var insights: Insights?
    @State private var kept: Set<String> = []
    @State private var busy: ConnectorID?
    @FocusState private var focused: Bool

    enum Step { case intro, askName, connect, reading, insights, notify, finishing }

    struct Line: Identifiable, Equatable {
        enum Kind: Equatable { case her(direction: String?), mine, connectors, insights }
        let id = UUID()
        var kind: Kind
        var text: String = ""
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        Timestamp(date: .now)
                        ForEach(Array(feed.enumerated()), id: \.element.id) { i, line in
                            row(line, showsAvatar: i == 0 || !isHer(feed[i - 1]))
                                .id(line.id)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if typing {
                            HStack(alignment: .top, spacing: 8) {
                                Avatar(size: 30)
                                TypingBubble()
                            }
                            .padding(.top, 6)
                        }
                        Color.clear.frame(height: 4).id("bottom")
                    }
                    .padding(.horizontal, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onChange(of: feed.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: typing) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .paper()
            .safeAreaInset(edge: .bottom) { bottomBar.padding(.bottom, 6) }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Avatar(size: 30)
                        Text(model.characterName).font(.aiboHeadline).foregroundStyle(Color.ink)
                    }
                }
            }
            .toolbarTitleDisplayMode(.inline)
        }
        .task { await intro() }
    }

    private func isHer(_ line: Line) -> Bool {
        if case .her = line.kind { return true }
        return false
    }

    // MARK: rows

    @ViewBuilder private func row(_ line: Line, showsAvatar: Bool) -> some View {
        switch line.kind {
        case .her(let direction):
            HStack(alignment: .top, spacing: 8) {
                Avatar(size: 30).opacity(showsAvatar ? 1 : 0)
                VStack(alignment: .leading, spacing: 5) {
                    if let direction { DirectionCaption(text: direction) }
                    Bubble(text: line.text)
                }
            }
            .padding(.top, showsAvatar ? 8 : 0)
        case .mine:
            Bubble(text: line.text, mine: true).padding(.top, 10)
        case .connectors:
            connectorCards.padding(.top, 10).padding(.leading, 38)
        case .insights:
            insightCards.padding(.top, 10).padding(.leading, 38)
        }
    }

    private var connectorCards: some View {
        VStack(spacing: 10) {
            ForEach(ConnectorID.allCases) { id in
                ConnectorCard(id: id, compact: true).disabled(step != .connect)
            }
        }
    }

    private var insightCards: some View {
        VStack(spacing: 10) {
            ForEach(Array((insights?.insights ?? []).enumerated()), id: \.element.id) { i, insight in
                let on = kept.contains(insight.id)
                Button {
                    guard step == .insights else { return }
                    if on { kept.remove(insight.id) } else { kept.insert(insight.id) }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(on ? Color.ink : Color.inkSoft)
                        Text(insight.text)
                            .font(.aiboBody)
                            .foregroundStyle(on ? Color.ink : Color.inkSoft)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .card(on ? IdeaRow.tints[i % IdeaRow.tints.count].opacity(0.45) : Color.surface, radius: 20)
                    .tilt(insight.text, by: 1.2)
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.selection, trigger: on)
                .accessibilityLabel("\(insight.text). \(on ? "Kept" : "Skipped")")
            }
        }
    }

    // MARK: bottom bar

    @ViewBuilder private var bottomBar: some View {
        switch step {
        case .askName:
            Composer(placeholder: "Your name", text: $draft, focused: $focused, disabled: false, onSend: submitName)
                .onAppear { focused = true }
        case .connect:
            let any = ConnectorID.allCases.contains { model.isConnected($0) }
            HStack(spacing: 10) {
                QuickReply(title: "Maybe later") { Task { await skipConnect() } }
                QuickReply(title: "Continue", primary: true) { Task { await readMyWeek() } }
                    .disabled(!any || busy != nil)
                    .opacity(any ? 1 : 0.4)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 16)
        case .insights:
            QuickReply(title: "Keep these", primary: true) { Task { await keepInsights() } }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 16)
        case .notify:
            HStack(spacing: 10) {
                QuickReply(title: "Not now") { Task { await finish(morning: false) } }
                QuickReply(title: "Yes, say good morning", primary: true) { Task { await finish(morning: true) } }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 16)
        default:
            EmptyView()
        }
    }

    // MARK: script

    private func say(_ text: String, direction: String? = nil, pause: Double = 0.9) async {
        typing = true
        try? await Task.sleep(for: .seconds(pause))
        typing = false
        withAnimation(.smooth(duration: 0.25)) { feed.append(Line(kind: .her(direction: direction), text: text)) }
    }

    private func mine(_ text: String) {
        withAnimation(.smooth(duration: 0.25)) { feed.append(Line(kind: .mine, text: text)) }
    }

    private func intro() async {
        guard feed.isEmpty else { return }
        let name = model.characterName
        await say("Hi, I'm \(name). I'll be living in your phone from now on, if that's alright.", direction: "peeks up from just below the surface, ears twitching", pause: 0.6)
        await say("What should I call you?")
        step = .askName
    }

    private func submitName() {
        let n = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        draft = ""
        focused = false
        // Resign before the field leaves the hierarchy, or the caret's blink animation can outlive it.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        mine(n)
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            step = .intro
            await model.setName(n)
            await say("Nice to meet you, \(n).", direction: "repeats it quietly, as if putting it somewhere safe")
            await say("To look after you properly, I'd like to see a little of your day. Only what you're comfortable with — you can hide any of it later.")
            withAnimation { feed.append(Line(kind: .connectors)) }
            step = .connect
        }
    }

    private func skipConnect() async {
        mine("Maybe later")
        step = .intro
        await say("That's fine. Tell me about yourself whenever you like, and I'll keep what matters.")
        await askMorning()
    }

    private func readMyWeek() async {
        mine("Done")
        step = .reading
        typing = true
        do {
            let r = try await model.insights()
            typing = false
            insights = r
            kept = Set(r.insights.map(\.id))
            if let intro = r.intro {
                let parts = ReplyParts(intro)
                for (i, b) in parts.bubbles.enumerated() {
                    await say(b, direction: i == 0 ? parts.direction : nil, pause: i == 0 ? 0.1 : 0.6)
                }
            }
            withAnimation { feed.append(Line(kind: .insights)) }
            await say("Did I get these right? Untick anything that's off.", pause: 0.6)
            step = .insights
        } catch {
            typing = false
            await say("The currents are rough right now — I'll read it properly later.", direction: "frowns at the page, then lets it go")
            await askMorning()
        }
    }

    private func keepInsights() async {
        step = .intro
        let memories = (insights?.insights ?? []).filter { kept.contains($0.id) && !$0.memory.isEmpty }.map(\.memory)
        mine(kept.isEmpty ? "None of these" : "Keep these")
        for m in memories { await model.keepMemory(m) }
        await say(memories.isEmpty ? "Noted. I'll learn as we go." : "Kept. You can see and edit everything I remember under You.")
        await askMorning()
    }

    private func askMorning() async {
        await say("One more thing. May I say good morning tomorrow? Once a day — I won't pester you.", direction: "smooths her apron, a little shy")
        step = .notify
    }

    private func finish(morning: Bool) async {
        step = .finishing
        mine(morning ? "Yes, say good morning" : "Not now")
        if morning { await MorningGreeting.enable(name: model.characterName) }
        await say(morning ? "Then I'll see you in the morning." : "Alright. I'm here whenever you want me.", pause: 0.7)
        try? await Task.sleep(for: .seconds(0.8))
        await model.finishOnboarding()
    }
}

// MARK: - Morning greeting

enum MorningGreeting {
    static func enable(name: String) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = "Good morning. I've looked over your day — come say hi."
        content.sound = .default
        var at = DateComponents()
        at.hour = 8
        at.minute = 30
        let req = UNNotificationRequest(identifier: "morning", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: at, repeats: true))
        try? await center.add(req)
    }
}
