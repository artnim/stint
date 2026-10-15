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
    /// Idle: one entry, never refreshed (the app reloads on every change). Running: one entry per elapsed
    /// minute for the next three hours, so the circular gauge and its h:mm label advance on their own.
    func getTimeline(in context: Context, completion: @escaping (Timeline<RunningEntry>) -> Void) {
        let now = current()
        guard let start = now.start else { completion(Timeline(entries: [now], policy: .never)); return }
        let elapsedMinutes = max(0, floor(now.date.timeIntervalSince(start) / 60))
        let following = (1...180).map { i in
            RunningEntry(date: start.addingTimeInterval((elapsedMinutes + Double(i)) * 60), description: now.description, start: start)
        }
        completion(Timeline(entries: [now] + following, policy: .atEnd))
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
        default:   // .accessoryCircular: the ring fills over each hour, the total runs inside as h:mm
            if let start = entry.start {
                let minutes = Int(max(0, entry.date.timeIntervalSince(start)) / 60)
                Gauge(value: Double(minutes % 60), in: 0...60) {
                    Text("Stint")
                } currentValueLabel: {
                    Text(verbatim: String(format: "%d:%02d", minutes / 60, minutes % 60))
                        .font(.system(.title3, design: .rounded)).monospacedDigit().minimumScaleFactor(0.5)
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    Image("MenuBarIcon").renderingMode(.template).resizable().scaledToFit().padding(10)
                }
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
