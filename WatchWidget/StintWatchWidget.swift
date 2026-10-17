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
    /// Checks CloudKit first: watchOS ignores the app's background reloads, so a stint started or stopped
    /// elsewhere reaches the face through this check, about every 15 minutes as the reload budget allows.
    /// The timers run on their own; running adds an entry at each full hour so the ring starts over.
    func getTimeline(in context: Context, completion: @escaping (Timeline<RunningEntry>) -> Void) {
        Task {
            let (s, note) = await CloudCheck.refreshed()
            ComplicationStore.noteTimeline(s, check: note)
            let now = RunningEntry(date: Date(), description: s.description, start: s.start)
            let recheck = TimelineReloadPolicy.after(now.date.addingTimeInterval(15 * 60))
            guard let start = s.start else { completion(Timeline(entries: [now], policy: recheck)); return }
            let hours = floor(max(0, now.date.timeIntervalSince(start)) / 3600)
            let following = (1...24).map { i in
                RunningEntry(date: start.addingTimeInterval((hours + Double(i)) * 3600), description: s.description, start: start)
            }
            completion(Timeline(entries: [now] + following, policy: recheck))
        }
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
        default:   // .accessoryCircular: the ring fills over each hour, the total runs inside; both advance on their own
            if let start = entry.start {
                // +1 s: an entry dated exactly on the hour must count that hour as begun
                let hourStart = start.addingTimeInterval(floor((max(0, entry.date.timeIntervalSince(start)) + 1) / 3600) * 3600)
                ProgressView(timerInterval: hourStart...hourStart.addingTimeInterval(3600), countsDown: false) {
                    Text("Stint")
                } currentValueLabel: {
                    Text(start, style: .timer)
                        .font(.system(.title3, design: .rounded)).monospacedDigit().minimumScaleFactor(0.4)
                }
                .progressViewStyle(.circular)
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

private extension RunningEntry {
    static let hourPlus = RunningEntry(date: .now, description: "#1427: Favorites & Images", start: .now.addingTimeInterval(-(83 * 60 + 45)))
    static let minutes = RunningEntry(date: .now, description: "Pull request maintenance", start: .now.addingTimeInterval(-25 * 60))
    static let idle = RunningEntry(date: .now, description: nil, start: nil)
}

#Preview("Circular", as: .accessoryCircular) { StintWatchWidget() } timeline: { RunningEntry.hourPlus; RunningEntry.minutes; RunningEntry.idle }
#Preview("Rectangular", as: .accessoryRectangular) { StintWatchWidget() } timeline: { RunningEntry.hourPlus; RunningEntry.minutes; RunningEntry.idle }
#Preview("Inline", as: .accessoryInline) { StintWatchWidget() } timeline: { RunningEntry.hourPlus; RunningEntry.minutes; RunningEntry.idle }
