import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    var date: Date
    var snapshot: CompanionSnapshot
    var frame: Int
}

/// She breathes a little on the home screen: a few idle frames spread across the next hour.
struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, snapshot: .placeholder, frame: 0) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snapshot: CompanionSnapshot.load(), frame: 0))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let snap = CompanionSnapshot.load()
        let entries = (0..<6).map { i in
            Entry(date: Date.now.addingTimeInterval(Double(i) * 10 * 60), snapshot: snap, frame: i)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct CompanionWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: Entry

    private var pose: PetPose {
        // Asleep-ish after midnight: stay on the calm idle loop.
        PetPose.forMood(entry.snapshot.mood)
    }

    private var pet: some View {
        Image(uiImage: UIImage(named: pose.frameName(entry.frame)) ?? UIImage())
            .resizable()
            .interpolation(.high)
            .scaledToFit()
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            pet.widgetAccentable()
        case .accessoryRectangular:
            HStack(spacing: 6) {
                pet.frame(width: 44)
                Text(entry.snapshot.line).font(.caption).lineLimit(3)
            }
        case .systemMedium:
            HStack(spacing: 12) {
                pet.frame(width: 120)
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.snapshot.line)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .lineLimit(4)
                    Spacer(minLength: 0)
                    if let next = entry.snapshot.nextEvent {
                        Label(next, systemImage: "calendar").font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    if let w = entry.snapshot.weather {
                        Label(w, systemImage: "cloud.sun").font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        default:
            VStack(spacing: 4) {
                pet.frame(maxHeight: 90)
                Text(entry.snapshot.line)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

struct AiboCompanionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AiboCompanion", provider: Provider()) { entry in
            CompanionWidgetView(entry: entry)
                .containerBackground(Color(white: 0.086), for: .widget)
        }
        .configurationDisplayName("Xiaoheiyu")
        .description("She keeps you company on your Home and Lock Screen.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

@main
struct AiboWidgets: WidgetBundle {
    var body: some Widget { AiboCompanionWidget() }
}
