import Foundation

struct ChatMessage: Codable, Identifiable, Equatable {
    var id: Int
    var role: String // "user" | "assistant"
    var content: String
    var mood: String?
    var kind: String
    var segment: Int
    var createdAt: Double // epoch ms

    var isUser: Bool { role == "user" }
    var date: Date { Date(timeIntervalSince1970: createdAt / 1000) }
}

struct Memory: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var origin: String
    var createdAt: Double
}

struct ListItem: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var done: Bool
}

struct CompanionList: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var createdAt: Double
    var items: [ListItem]
}

struct SourceState: Codable, Identifiable, Equatable {
    var id: String
    var label: String
    var summary: String
    var shared: Bool
    var updatedAt: Double
}

struct CharacterInfo: Codable, Equatable {
    var name: String
    var greeting: [String: String]
}

struct AppState: Codable {
    var profile: [String: String]
    var character: CharacterInfo
    var memories: [Memory]
    var lists: [CompanionList]
    var sources: [SourceState]
}

struct TodayBrief: Codable, Equatable {
    struct Item: Codable, Equatable, Hashable {
        var kind: String
        var text: String
    }
    struct Weather: Codable, Equatable {
        var temp: Int
        var condition: String
        var place: String
    }
    struct Suggestion: Codable, Equatable, Hashable {
        var kind: String
        var title: String
        var detail: String
        var prompt: String
    }
    var day: String
    var greeting: String
    var items: [Item]
    var suggestions: [Suggestion]
    var weather: Weather?
}

struct Insights: Codable {
    struct Insight: Codable, Identifiable, Equatable {
        var text: String
        var memory: String
        var id: String { text }
    }
    var intro: String?
    var insights: [Insight]
}

/// One event from the chat stream.
enum ChatEvent {
    case ack(userMessageId: Int)
    case stage(String)
    case text(String)
    case tool(String)
    case memory(Memory)
    case memoryRemoved(String)
    case list(String)
    case done(ChatMessage)
    case error(String)
}

/// Stage states the server streams; each has a looping clip in Resources/Stage.
enum StageState: String, CaseIterable {
    case idle, listening, reading, writing, searching, running, speaking, waiting, done, failed, excited, sad

    static func forMood(_ mood: String?) -> StageState {
        switch mood {
        case "excited": .excited
        case "sad": .sad
        case "surprised": .failed
        case "happy": .done
        default: .idle
        }
    }
}

struct Account: Codable, Equatable {
    var id: String
    var email: String?
    var name: String?
    var appleLinked: Bool
    var createdAt: Double

    /// Apple's private relay addresses aren't worth showing.
    var displayEmail: String? {
        guard let email, !email.hasSuffix("privaterelay.appleid.com") else { return nil }
        return email
    }
}

struct AuthResult: Codable {
    var token: String
    var user: Account
    var isNew: Bool
}
