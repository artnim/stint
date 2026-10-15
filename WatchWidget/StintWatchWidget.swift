import SwiftUI
import WidgetKit

struct RunningEntry: TimelineEntry {
    let date: Date
    let description: String?
    let start: Date?
}

struct RunningProvider: TimelineProvider {
    func placeholder(in context: Context) -> RunningEntry { RunningEntry(date: Date(), description: "#1403: Login", start: Date().addingTimeInterval(-1500)) }
    func getSnapshot(in context: Context, completion: @escaping (RunningEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RunningEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))   // the app reloads the timeline on every change
    }
    private func current() -> RunningEntry {
        let s = ComplicationStore.load()
        return RunningEntry(date: Date(), description: s.description, start: s.start)
    }
}

struct RunningView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RunningEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) { ring; Text("Stint").font(.caption2).foregroundStyle(.secondary) }
                if let start = entry.start {
                    Text(entry.description.flatMap { $0.isEmpty ? nil : $0 } ?? "—").font(.headline).lineLimit(1)
                    Text(start, style: .timer).font(.title3).monospacedDigit()
                } else {
                    Text("—").font(.title3)
                }
            }
        case .accessoryInline:
            if let start = entry.start { Text("Stint · \(start, style: .timer)") } else { Text("Stint · —") }
        default:   // .accessoryCircular
            VStack(spacing: 0) {
                ring
                if let start = entry.start { Text(start, style: .timer).font(.caption2).monospacedDigit().minimumScaleFactor(0.6) }
                else { Text("—").font(.caption2) }
            }
        }
    }

    private var ring: some View {
        Image("MenuBarIcon").renderingMode(.template).resizable().scaledToFit().frame(width: 14, height: 14)
    }
}

@main
struct StintWatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "io.artnim.stint.running", provider: RunningProvider()) { entry in
            RunningView(entry: entry).containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Running stint")
        .description("What is running and for how long.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}
