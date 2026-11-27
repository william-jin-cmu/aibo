import SwiftUI

/// Your day at a glance, as stickers: what she noticed, the schedule, your body, open lists.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var events: [DemoData.Event] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    noticed
                    schedule
                    bodyTiles
                    openLists
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .paper()
            .refreshable {
                await model.syncConnectors(force: true)
                await model.loadToday(refresh: true)
                events = model.todayEvents()
            }
            .task {
                events = model.todayEvents()
                if model.today == nil { await model.loadToday() }
            }
            .navigationTitle("Today")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: String.self) { ListDetailView(listId: $0) }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            StickerEmoji(emoji: weatherEmoji, size: 40, tilt: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.aiboTitle)
                    .foregroundStyle(Color.ink)
                if let w = model.today?.weather {
                    Text("\(w.temp)°C · \(w.condition) · \(w.place)")
                        .font(.aiboCallout)
                        .foregroundStyle(Color.inkSoft)
                }
            }
        }
    }

    private var weatherEmoji: String {
        let c = model.today?.weather?.condition.lowercased() ?? ""
        if c.contains("rain") || c.contains("shower") || c.contains("drizzle") { return "🌧️" }
        if c.contains("snow") { return "❄️" }
        if c.contains("cloud") || c.contains("overcast") { return "⛅️" }
        return "☀️"
    }

    @ViewBuilder private var noticed: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Avatar(size: 24)
                Text("\(model.characterName) noticed").font(.aiboTitle).foregroundStyle(Color.ink)
            }
            Group {
                if let brief = model.today, !brief.items.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(brief.items, id: \.self) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(Color.sea).frame(width: 6, height: 6).padding(.top, 7)
                                Text(item.text).font(.aiboBody).foregroundStyle(Color.ink)
                            }
                        }
                    }
                } else if model.loadingToday {
                    ProgressView().tint(Color.sea)
                } else {
                    Text("Nothing yet. Share a source under You so she can follow your day.")
                        .font(.aiboCallout).foregroundStyle(Color.inkSoft)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    @ViewBuilder private var schedule: some View {
        if model.isConnected(.calendar) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Schedule", trailing: events.isEmpty ? nil : "\(events.count) today")
                if events.isEmpty {
                    Text("A clear day.").font(.aiboCallout).foregroundStyle(Color.inkSoft)
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading).card()
                } else {
                    VStack(spacing: 10) {
                        ForEach(Array(events.enumerated()), id: \.offset) { i, e in
                            HStack(spacing: 14) {
                                Text(e.allDay ? "All day" : e.start.formatted(date: .omitted, time: .shortened))
                                    .font(AiboFont.rounded(13, .bold).monospacedDigit())
                                    .foregroundStyle(Color.ink)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .sticker(IdeaRow.tints[i % IdeaRow.tints.count], in: .capsule, edge: 2, lift: 0.3, tag: true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.title).font(.aiboHeadline).foregroundStyle(Color.ink)
                                    if let loc = e.location, !loc.isEmpty {
                                        Text(loc).font(.aiboCaption).foregroundStyle(Color.inkSoft)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(14)
                            .card(radius: 20)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var bodyTiles: some View {
        if let days = model.lastHealth?.days, let last = days.last {
            let week = days.suffix(7)
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Body")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                    if let h = last.sleepHours {
                        Tile(emoji: "😴", value: String(format: "%.1f h", h), caption: last.bedtime.map { "In bed at \($0)" } ?? "Last night", tint: .lilac)
                    }
                    if let s = last.steps {
                        let counts = week.compactMap(\.steps)
                        Tile(emoji: "👟", value: s.formatted(), caption: "Week avg \((counts.reduce(0, +) / max(1, counts.count)).formatted())", tint: .mint)
                    }
                    if let hr = days.last(where: { $0.restingHR != nil })?.restingHR {
                        Tile(emoji: "💓", value: "\(hr) bpm", caption: "Resting heart rate", tint: .blush)
                    }
                    if let kcal = last.activeEnergy {
                        Tile(emoji: "🔥", value: "\(kcal) kcal", caption: "Active energy", tint: .butter)
                    }
                }
            }
        }
    }

    @ViewBuilder private var openLists: some View {
        let open = model.lists.filter { $0.items.contains { !$0.done } }
        if !open.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Lists")
                ForEach(open) { list in
                    NavigationLink(value: list.id) { ListRow(list: list) }.buttonStyle(.plain)
                }
            }
        }
    }
}

private struct Tile: View {
    var emoji: String
    var value: String
    var caption: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            StickerEmoji(emoji: emoji, size: 24, tilt: 8)
            Text(value).font(AiboFont.rounded(22, .bold)).foregroundStyle(Color.ink)
            Text(caption).font(.aiboCaption).foregroundStyle(Color.ink.opacity(0.7)).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint.opacity(0.55), radius: 22)
    }
}

/// A list as a sticker row: emoji, title, how many are left.
struct ListRow: View {
    var list: CompanionList

    var body: some View {
        HStack(spacing: 12) {
            StickerEmoji(emoji: "📝", size: 22, tilt: 6)
            Text(list.title).font(.aiboHeadline).foregroundStyle(Color.ink)
            Spacer()
            Text("\(list.items.filter { !$0.done }.count) open").font(.aiboCallout).foregroundStyle(Color.inkSoft)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.inkSoft)
        }
        .padding(14)
        .card(radius: 20)
    }
}
