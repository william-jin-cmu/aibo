import SwiftUI

/// What she knows about you, what you let her see, and your account. Everything here is
/// readable, editable and removable — trust through transparency.
struct YouView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var newMemory = ""
    @State private var editing: Memory?
    @State private var editText = ""
    @State private var confirm: Confirm?

    enum Confirm: String, Identifiable {
        case startOver, delete
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    accountCard
                    memoriesSection
                    listsSection
                    connectorsSection
                    dangerZone
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .paper()
            .navigationTitle("You")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: String.self) { ListDetailView(listId: $0) }
            .refreshable { try? await model.refreshState() }
            .alert("Something she should remember", isPresented: $adding) {
                TextField("e.g. Allergic to peanuts", text: $newMemory)
                Button("Save") {
                    let t = newMemory
                    newMemory = ""
                    Task { await model.addMemory(t) }
                }
                Button("Cancel", role: .cancel) { newMemory = "" }
            }
            .alert("Edit memory", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("Memory", text: $editText)
                Button("Save") {
                    if let m = editing { Task { await model.editMemory(m, text: editText) } }
                    editing = nil
                }
                Button("Forget", role: .destructive) {
                    if let m = editing { Task { await model.deleteMemory(m) } }
                    editing = nil
                }
                Button("Cancel", role: .cancel) { editing = nil }
            }
            .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
                if confirm == .startOver {
                    Button("Start over", role: .destructive) {
                        dismiss()
                        Task { await model.resetEverything() }
                    }
                } else {
                    Button("Delete account", role: .destructive) {
                        dismiss()
                        Task { await model.deleteAccount() }
                    }
                }
            } message: {
                Text(confirm == .startOver
                     ? "She'll forget your conversation, memories, lists and shared data. Your account stays."
                     : "Deletes your account and your agent with everything she knows. This can't be undone.")
            }
        }
    }

    private var confirmTitle: String {
        confirm == .startOver ? "Start over with \(model.characterName)?" : "Delete your account?"
    }

    // MARK: account

    private var accountCard: some View {
        HStack(spacing: 14) {
            Text(initial)
                .font(AiboFont.rounded(24, .bold))
                .foregroundStyle(Color.ink)
                .frame(width: 56, height: 56)
                .sticker(Color.butter, in: .circle, edge: 3, lift: 0.5, tag: true)
                .tilt(initial, by: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.userName ?? model.account?.name ?? "You").font(.aiboTitle).foregroundStyle(Color.ink)
                Text(accountLine).font(.aiboCallout).foregroundStyle(Color.inkSoft)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .card()
    }

    private var initial: String {
        String((model.userName ?? model.account?.name ?? model.account?.email ?? "Y").prefix(1)).uppercased()
    }

    private var accountLine: String {
        if let email = model.account?.displayEmail { return email }
        return model.account?.appleLinked == true ? "Signed in with Apple" : "Signed in"
    }

    // MARK: memories

    private var memoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "What she remembers", trailing: model.memories.isEmpty ? nil : "\(model.memories.count)")
            if model.memories.isEmpty {
                Text("Nothing yet. Tell her about yourself and she'll keep what matters.")
                    .font(.aiboCallout).foregroundStyle(Color.inkSoft)
            }
            ForEach(Array(model.memories.reversed().enumerated()), id: \.element.id) { i, m in
                Button {
                    editText = m.text
                    editing = m
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(m.text).font(.aiboBody).foregroundStyle(Color.ink).multilineTextAlignment(.leading)
                        Text(originLabel(m)).font(.aiboCaption).foregroundStyle(Color.ink.opacity(0.6))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(IdeaRow.tints[i % IdeaRow.tints.count].opacity(0.35), radius: 20)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Forget", systemImage: "trash", role: .destructive) { Task { await model.deleteMemory(m) } }
                }
            }
            Button { adding = true } label: {
                Label("Add a memory", systemImage: "plus")
                    .font(AiboFont.rounded(15, .semibold))
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassButton(in: .capsule)
            }
            .buttonStyle(.plain)
        }
    }

    private func originLabel(_ m: Memory) -> String {
        let date = Date(timeIntervalSince1970: m.createdAt / 1000).formatted(date: .abbreviated, time: .omitted)
        switch m.origin {
        case "chat": return "From a conversation · \(date)"
        case "onboarding": return "Noticed when you first met · \(date)"
        default: return "Added by you · \(date)"
        }
    }

    // MARK: lists

    @ViewBuilder private var listsSection: some View {
        if !model.lists.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Lists")
                ForEach(model.lists) { list in
                    NavigationLink(value: list.id) { ListRow(list: list) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete list", systemImage: "trash", role: .destructive) { Task { await model.deleteList(list) } }
                        }
                }
            }
        }
    }

    // MARK: connectors

    private var connectorsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "What she can see")
            ForEach(ConnectorID.allCases) { id in ConnectorCard(id: id) }
            Text("Read on this iPhone and shared with her as a summary. Turn off “Visible to her” to hide a source without disconnecting it.")
                .font(.aiboCaption)
                .foregroundStyle(Color.inkSoft)
        }
    }

    // MARK: account actions

    private var dangerZone: some View {
        VStack(spacing: 10) {
            WideButton(title: "Sign out", symbol: "rectangle.portrait.and.arrow.right", primary: false) {
                dismiss()
                Task { await model.signOut() }
            }
            HStack(spacing: 18) {
                Button("Start over") { confirm = .startOver }
                Button("Delete account") { confirm = .delete }
            }
            .font(AiboFont.rounded(14, .semibold))
            .foregroundStyle(Color.coral)
            .padding(.top, 6)
        }
    }
}

/// A connector as a sticker: emoji, what it is, connect or sync, and whether she may see it.
struct ConnectorCard: View {
    @Environment(AppModel.self) private var model
    var id: ConnectorID
    var compact = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                StickerEmoji(emoji: id.emoji, size: 26, tilt: 8).frame(width: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(id.title).font(.aiboHeadline).foregroundStyle(Color.ink)
                    Text(status).font(.aiboCaption).foregroundStyle(Color.inkSoft).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if busy {
                    ProgressView().tint(Color.sea)
                } else if model.isConnected(id) {
                    if compact {
                        Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Color.sea)
                    } else {
                        Menu {
                            Button("Sync now", systemImage: "arrow.clockwise") { run { await model.syncConnectors(force: true) } }
                            Button("Disconnect", systemImage: "xmark", role: .destructive) { run { await model.disconnect(id) } }
                        } label: {
                            Image(systemName: "ellipsis").foregroundStyle(Color.ink).glassIcon(compact: true)
                        }
                    }
                } else {
                    Button { run { await model.connect(id) } } label: {
                        Text("Connect")
                            .font(AiboFont.rounded(14, .bold))
                            .foregroundStyle(Color.paperBase)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .glassButton(Color.sea, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            if !compact, model.isConnected(id), model.source(id) != nil {
                Toggle("Visible to her", isOn: Binding(get: { model.isShared(id) }, set: { v in Task { await model.setShared(id, v) } }))
                    .font(AiboFont.rounded(15, .medium))
                    .foregroundStyle(Color.ink)
                    .tint(Color.sea)
            }
        }
        .padding(14)
        .card(radius: 22)
    }

    private var status: String {
        guard model.isConnected(id) else { return id.pitch }
        guard let s = model.source(id) else { return "Connected · waiting for data" }
        return "Synced \(Date(timeIntervalSince1970: s.updatedAt / 1000).formatted(.relative(presentation: .named)))"
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task {
            await work()
            busy = false
        }
    }
}

struct ListDetailView: View {
    @Environment(AppModel.self) private var model
    var listId: String

    var body: some View {
        let list = model.lists.first { $0.id == listId }
        ScrollView {
            VStack(spacing: 10) {
                ForEach(list?.items ?? []) { item in
                    Button {
                        if let list { Task { await model.toggle(item, in: list) } }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(item.done ? Color.sea : Color.inkSoft)
                            Text(item.text)
                                .font(.aiboBody)
                                .strikethrough(item.done)
                                .foregroundStyle(item.done ? Color.inkSoft : Color.ink)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .card(radius: 20)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .paper()
        .navigationTitle(list?.title ?? "List")
    }
}
