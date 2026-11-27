import Foundation

/// What the widget shows: her latest line, her mood and one thing about the day.
/// Written by the app into the shared App Group, read by the widget extension.
struct CompanionSnapshot: Codable, Equatable {
    var line: String
    var mood: String
    var nextEvent: String?
    var weather: String?
    var updatedAt: Date

    static let appGroup = "group.dev.aibo.ios"
    private static let key = "companion.snapshot"

    static let placeholder = CompanionSnapshot(
        line: "I'm right here.",
        mood: "neutral",
        nextEvent: nil,
        weather: nil,
        updatedAt: .now
    )

    static func load() -> CompanionSnapshot {
        guard
            let data = UserDefaults(suiteName: appGroup)?.data(forKey: key),
            let snap = try? JSONDecoder().decode(CompanionSnapshot.self, from: data)
        else { return .placeholder }
        return snap
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: Self.appGroup)?.set(data, forKey: Self.key)
    }
}

/// Chibi pet frames bundled in Shared/Pet (cut from the desktop pet atlas).
enum PetPose: String, CaseIterable {
    case idle, waving, jumping, failed, waiting, running, review

    var frameCount: Int {
        switch self {
        case .idle, .waiting, .running, .review: 6
        case .waving: 4
        case .jumping: 5
        case .failed: 8
        }
    }

    func frameName(_ i: Int) -> String { "\(rawValue)_\(i % frameCount)" }

    /// Pose that fits a reply mood, for the widget and the peek animation.
    static func forMood(_ mood: String) -> PetPose {
        switch mood {
        case "excited": .jumping
        case "happy": .review
        case "sad": .waiting
        case "surprised": .failed
        default: .idle
        }
    }
}

/// Strips the opening stage direction so a line reads as speech on its own.
func spokenPart(of text: String) -> String {
    var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    while let first = s.first, first == "（" || first == "(" {
        let close: Character = first == "（" ? "）" : ")"
        guard let end = s.firstIndex(of: close) else { break }
        s = String(s[s.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return s
}
