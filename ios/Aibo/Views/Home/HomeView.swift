import SwiftUI

/// The one conversation, on sticker-book paper: her avatar beside her bubbles, yours on the right,
/// a "today" card when you come back, idea stickers above the composer.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var sheet: Sheet?
    @State private var hideIdeas = false
    @FocusState private var focused: Bool

    enum Sheet: String, Identifiable {
        case about, today, you
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            conversation
                .paper()
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 4) {
                        if showIdeas, let brief = model.today, !brief.suggestions.isEmpty {
                            IdeaRow(suggestions: brief.suggestions, onPick: { s in
                                Task { await model.send(s.prompt) }
                            }, onClose: { withAnimation(.snappy) { hideIdeas = true } })
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        Composer(placeholder: "Message \(model.characterName)", text: $draft, focused: $focused, disabled: model.sending, onSend: send)
                    }
                    .animation(.snappy, value: showIdeas)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { sheet = .about } label: {
                            HStack(spacing: 10) {
                                Avatar(size: 34)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(model.characterName).font(.aiboHeadline).foregroundStyle(Color.ink)
                                    Text(statusText ?? "here with you")
                                        .font(AiboFont.rounded(12, .medium))
                                        .foregroundStyle(statusText == nil ? Color.inkSoft : Color.sea)
                                        .contentTransition(.opacity)
                                }
                            }
                            .animation(.snappy, value: statusText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("header")
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { sheet = .today } label: { Image(systemName: "sun.horizon.fill") }
                            .accessibilityLabel("Today")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { sheet = .you } label: { Image(systemName: "person.crop.circle") }
                            .accessibilityLabel("You")
                    }
                }
                .toolbarTitleDisplayMode(.inline)
                .sheet(item: $sheet) { s in
                    Group {
                        switch s {
                        case .about: AboutHerView()
                        case .today: TodayView()
                        case .you: YouView()
                        }
                    }
                    .presentationCornerRadius(32)
                }
                .onChange(of: focused) { _, f in model.composerFocused = f }
        }
    }

    private var showIdeas: Bool { !hideIdeas && model.showTodayCard && !model.sending }

    private var statusText: String? {
        switch model.stage {
        case .reading: return "thinking…"
        case .writing: return "writing it down…"
        case .searching: return "looking it up…"
        default: return model.streamingText != nil ? "typing…" : nil
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) { i, msg in
                        let prev = i > 0 ? model.messages[i - 1] : nil
                        if prev == nil || prev!.segment != msg.segment {
                            Timestamp(date: msg.date)
                        }
                        MessageView(message: msg, showsAvatar: prev?.isUser != false || prev?.segment != msg.segment)
                            .padding(.top, prev != nil && prev!.isUser != msg.isUser ? 10 : 0)
                            .transition(.asymmetric(insertion: .scale(scale: 0.9, anchor: msg.isUser ? .bottomTrailing : .bottomLeading).combined(with: .opacity), removal: .opacity))
                    }
                    if let text = model.streamingText {
                        Group {
                            if ReplyParts(text).bubbles.isEmpty {
                                HStack(alignment: .top, spacing: 8) {
                                    Avatar(size: 30)
                                    TypingBubble(label: statusText == "typing…" ? nil : statusText)
                                }
                            } else {
                                MessageView(message: ChatMessage(id: 0, role: "assistant", content: text, mood: nil, kind: "chat", segment: 0, createdAt: 0), showsAvatar: true)
                            }
                        }
                        .padding(.top, 10)
                    }
                    if let err = model.lastError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.aiboCallout)
                            .foregroundStyle(Color.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .sticker(Color.blush.opacity(0.5), in: .rect(cornerRadius: 18, style: .continuous), edge: 2.5, lift: 0.4)
                            .padding(.top, 10)
                    }
                    if model.showTodayCard {
                        TodayBriefView().padding(.top, 16)
                    }
                    Color.clear.frame(height: 6).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .animation(.snappy, value: model.messages.count)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onTapGesture { focused = false }
            .onChange(of: model.messages.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.streamingText) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.today) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: focused) {
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await model.send(text) }
    }
}

/// One message. Hers: avatar, a caption for what she's doing, then one bubble per paragraph.
struct MessageView: View {
    var message: ChatMessage
    var showsAvatar = true

    var body: some View {
        if message.isUser {
            Bubble(text: message.content, mine: true)
        } else {
            let parts = ReplyParts(message.content)
            HStack(alignment: .top, spacing: 8) {
                Avatar(size: 30).opacity(showsAvatar ? 1 : 0)
                VStack(alignment: .leading, spacing: 5) {
                    if let d = parts.direction { DirectionCaption(text: d) }
                    ForEach(Array(parts.bubbles.enumerated()), id: \.offset) { _, b in
                        Bubble(text: b)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(message.id == 0 ? "streaming" : message.id == -99 ? "brief" : "assistantMessage")
        }
    }
}

struct Timestamp: View {
    var date: Date
    var body: some View {
        Text(label)
            .font(.aiboCaption)
            .foregroundStyle(Color.inkSoft)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.paperBase.opacity(0.9), in: .capsule)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
    }

    private var label: String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInYesterday(date) { return "Yesterday \(time)" }
        return "\(date.formatted(.dateTime.weekday(.wide))) \(time)"
    }
}

/// The composer capsule, as in Bower: rounded field and a glass send button that appears with text.
struct Composer: View {
    var placeholder: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    var disabled: Bool
    var onSend: () -> Void

    private var canSend: Bool { !disabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.inkSoft), axis: .vertical)
                .font(.aiboBody)
                .foregroundStyle(Color.ink)
                .lineLimit(1...5)
                .focused(focused)
                .accessibilityIdentifier("composer")
                .submitLabel(.send)
                .onSubmit { if canSend { onSend() } }
                .padding(.vertical, 10)
                .padding(.leading, 12)
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .foregroundStyle(canSend ? Color.sea : Color.inkSoft.opacity(0.5))
                    .glassIcon(compact: true)
                    .scaleEffect(canSend ? 1 : 0.9)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .animation(.bouncy, value: canSend)
            .padding(.bottom, 4)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("sendButton")
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.surface)
                .shadow(color: Color.shadow.opacity(0.25), radius: 10, y: 3)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

/// Things she could help with next, as pastel stickers with a die-cut emoji (Bower's idea cards).
struct IdeaRow: View {
    var suggestions: [TodayBrief.Suggestion]
    var onPick: (TodayBrief.Suggestion) -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Ideas").font(.aiboCaption).foregroundStyle(Color.inkSoft).textCase(.uppercase)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                    .foregroundStyle(Color.inkSoft)
                    .accessibilityLabel("Hide ideas")
            }
            .padding(.horizontal, 22)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(suggestions.enumerated()), id: \.element) { i, s in
                        Button { onPick(s) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                StickerEmoji(emoji: Self.emoji(s.kind), size: 26, tilt: 8)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(s.title).font(AiboFont.rounded(15, .bold)).foregroundStyle(Color.ink)
                                    Text(s.detail).font(AiboFont.rounded(13, .medium)).foregroundStyle(Color.ink.opacity(0.75))
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .frame(width: 236, height: 78, alignment: .topLeading)
                            .sticker(Self.tints[i % Self.tints.count].opacity(0.55), in: .rect(cornerRadius: 20, style: .continuous), edge: 3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("suggestion")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
    }

    static let tints: [Color] = [.sky, .mint, .lilac, .butter, .blush]

    static func emoji(_ kind: String) -> String {
        switch kind {
        case "weather": "🌤️"
        case "calendar": "🗓️"
        case "health": "💤"
        case "list": "📝"
        case "food": "🍜"
        default: "🐋"
        }
    }
}

/// The card she leaves in the conversation when you come back: her greeting plus today at a glance.
struct TodayBriefView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let brief = model.today {
                MessageView(message: ChatMessage(id: -99, role: "assistant", content: brief.greeting, mood: nil, kind: "brief", segment: 0, createdAt: 0))
                if !brief.items.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(Date.now.formatted(.dateTime.weekday(.wide).month().day()))
                                .font(.aiboHeadline)
                            Spacer()
                            if let w = brief.weather {
                                Pill(text: "\(w.temp)°", symbol: WeatherIcon.symbol(for: w.condition), tint: .sky)
                            }
                        }
                        .padding(.bottom, 8)
                        ForEach(Array(brief.items.enumerated()), id: \.offset) { i, item in
                            if i > 0 { Rectangle().fill(Color.line).frame(height: 1) }
                            HStack(spacing: 12) {
                                Text(emoji(item.kind)).font(.system(size: 18))
                                Text(item.text).font(.aiboCallout)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 10)
                        }
                    }
                    .foregroundStyle(Color.ink)
                    .padding(16)
                    .frame(maxWidth: 330, alignment: .leading)
                    .card()
                    .padding(.leading, 38)
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Avatar(size: 30)
                    TypingBubble(label: "looking over your day…")
                }
            }
        }
        .task { if model.today == nil { await model.loadToday() } }
    }

    private func emoji(_ kind: String) -> String {
        switch kind {
        case "weather": "🌤️"
        case "calendar": "🗓️"
        case "health": "💙"
        case "reminder": "📌"
        default: "✨"
        }
    }
}

enum WeatherIcon {
    static func symbol(for condition: String) -> String {
        let c = condition.lowercased()
        if c.contains("thunder") { return "cloud.bolt.rain.fill" }
        if c.contains("snow") { return "cloud.snow.fill" }
        if c.contains("rain") || c.contains("drizzle") || c.contains("shower") { return "cloud.rain.fill" }
        if c.contains("fog") { return "cloud.fog.fill" }
        if c.contains("overcast") { return "cloud.fill" }
        if c.contains("cloud") { return "cloud.sun.fill" }
        return "sun.max.fill"
    }
}

/// Who she is: her face, her name and what she does. Identity lives in the avatar.
struct AboutHerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image("Avatar")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 150, height: 150)
                    .clipShape(.rect(cornerRadius: 44, style: .continuous))
                    .sticker(Color.surface, in: .rect(cornerRadius: 44, style: .continuous), edge: 5, lift: 1.2, tag: true)
                    .tilt("about-her", by: 5)
                    .padding(.top, 36)
                VStack(spacing: 6) {
                    Text(model.characterName).font(.aiboDisplay).foregroundStyle(Color.ink)
                    Text("An orca maid who keeps house in a sunlit sea.\nCalm, warm, a little dry.")
                        .font(.aiboBody)
                        .foregroundStyle(Color.inkSoft)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 8) {
                    Pill(text: plural(model.memories.count, "memory", "memories"), symbol: "sparkles", tint: .lilac)
                    Pill(text: plural(model.lists.count, "list", "lists"), symbol: "checklist", tint: .mint)
                    Pill(text: plural(model.sources.filter(\.shared).count, "source", "sources"), symbol: "eye", tint: .sky)
                }
                VStack(alignment: .leading, spacing: 14) {
                    row("💬", "Talk to her about anything", "She mirrors your language and keeps it short.")
                    row("🧠", "She remembers", "Tell her what matters; edit or remove it any time under You.")
                    row("🗓️", "She knows your day", "From what you've shared: Health, Calendar, Location.")
                    row("📝", "She keeps lists", "Shows to watch, things to buy, places to try.")
                }
                .padding(18)
                .card()
                .padding(.horizontal, 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 30)
        }
        .paper()
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: { Image(systemName: "xmark").foregroundStyle(Color.ink).glassIcon() }
                .buttonStyle(.plain)
                .padding(16)
                .accessibilityLabel("Close")
        }
        .presentationDragIndicator(.visible)
    }

    private func row(_ emoji: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            StickerEmoji(emoji: emoji, size: 24, tilt: 6).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.aiboHeadline).foregroundStyle(Color.ink)
                Text(detail).font(.aiboCallout).foregroundStyle(Color.inkSoft)
            }
        }
    }
}

private func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
