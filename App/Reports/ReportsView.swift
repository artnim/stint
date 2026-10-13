import PDFKit
import SwiftUI
import TimeCore
import UniformTypeIdentifiers

/// Everything that influences the generated report; `.task(id:)` regenerates when it changes.
private struct ReportRequest: Equatable {
    var year: Int
    var month: Int
    var useRange: Bool
    var from: Date
    var to: Date
    var clientId: Int64?
    var projectId: Int64?
    var options: ReportOptions
    var dataVersion: Int
}

struct ReportsView: View {
    @Environment(AppState.self) private var state
    @State private var presets: [ReportPreset] = []
    @State private var presetName = ReportPreset.monthly.name
    @State private var newPresetName = ""
    @State private var req = ReportRequest(
        year: Calendar.current.component(.year, from: Date()),
        month: Calendar.current.component(.month, from: Date()),
        useRange: false, from: Date(), to: Date(),
        clientId: nil, projectId: nil, options: ReportPreset.monthly.options, dataVersion: 0)
    @State private var report: Report?
    @State private var pdfData: Data?
    @State private var document: PDFDocument?
    @State private var message = ""

    var body: some View {
        HSplitView {
            controls.frame(minWidth: 340, maxWidth: 380)
            VStack(spacing: 0) {
                PDFPreview(document: document)
                if let r = report, !r.warnings.isEmpty {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(r.warnings.count) thing(s) worth a look in the raw data").font(.caption.bold())
                            ForEach(r.warnings, id: \.self) { Text("! " + $0).font(.caption).monospaced() }
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }
        }
        .onAppear {
            req.dataVersion = state.dataVersion
            presets = PresetStore.load(state.db)
            applyPreset(presetName)
        }
        .onChange(of: state.dataVersion) { req.dataVersion = state.dataVersion }
        .task(id: req) { generate() }
    }

    private var controls: some View {
        Form {
            Section("Preset") {
                Picker("Preset", selection: $presetName) {
                    ForEach(presets) { Text($0.name).tag($0.name) }
                }
                .onChange(of: presetName) { applyPreset(presetName) }
                HStack {
                    TextField("Save as…", text: $newPresetName)
                    Button("Save") {
                        presets.removeAll { $0.name == newPresetName }
                        presets.append(ReportPreset(name: newPresetName, options: req.options))
                        PresetStore.save(presets, to: state.db)
                        presetName = newPresetName
                        newPresetName = ""
                    }
                    .disabled(newPresetName.isEmpty)
                    Button("Delete") {
                        presets.removeAll { $0.name == presetName }
                        if presets.isEmpty { presets = [.monthly] }
                        PresetStore.save(presets, to: state.db)
                        presetName = presets[0].name
                    }
                    .disabled(presets.count <= 1)
                }
            }
            Section("Period") {
                Toggle("Date range", isOn: $req.useRange)
                if req.useRange {
                    DatePicker("From", selection: $req.from, displayedComponents: .date)
                    DatePicker("To (inclusive)", selection: $req.to, displayedComponents: .date)
                } else {
                    Stepper("Year \(String(req.year))", value: $req.year, in: 2000...2100)
                    Picker("Month", selection: $req.month) {
                        ForEach(1...12, id: \.self) { Text(Strings.of(req.options.language).months[$0]).tag($0) }
                    }
                }
            }
            Section("Filter") {
                Picker("Client", selection: $req.clientId) {
                    Text("All").tag(Int64?.none)
                    ForEach(state.clients) { Text($0.name).tag(Int64?.some($0.id!)) }
                }
                Picker("Project", selection: $req.projectId) {
                    Text("All").tag(Int64?.none)
                    ForEach(state.projects) { Text($0.name).tag(Int64?.some($0.id!)) }
                }
            }
            Section("Layout") {
                Picker("Language", selection: $req.options.language) {
                    ForEach(Language.allCases) { Text($0.rawValue.uppercased()).tag($0) }
                }
                TextField("Title ({Month} {Year} / {Monat} {Jahr})",
                          text: Binding(get: { req.options.title ?? "" },
                                        set: { req.options.title = $0.isEmpty ? nil : $0 }))
                Stepper("Grid \(req.options.gridMinutes) min", value: $req.options.gridMinutes, in: 0...60, step: 5)
                Picker("Duration rounding", selection: $req.options.durationRounding) {
                    ForEach(DurationRounding.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Start snapping", selection: $req.options.startSnap) {
                    ForEach(SnapMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Times column", isOn: $req.options.showTimes)
                tri("Issue column", $req.options.showIssue)
                tri("Tags column", $req.options.showTags)
                Toggle("Tag breakdown", isOn: $req.options.summary)
                Toggle("Newest day first", isOn: $req.options.newestFirst)
            }
            Section {
                HStack {
                    Button("Export PDF…") { export() }.disabled(pdfData == nil).keyboardShortcut("e")
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func tri(_ label: String, _ binding: Binding<Bool?>) -> some View {
        Picker(label, selection: binding) {
            Text("auto").tag(Bool?.none)
            Text("on").tag(Bool?.some(true))
            Text("off").tag(Bool?.some(false))
        }
        .pickerStyle(.segmented)
    }

    private func applyPreset(_ name: String) {
        if let p = presets.first(where: { $0.name == name }) { req.options = p.options }
    }

    private var period: (start: Date, end: Date, month: Int, year: Int) {
        let cal = Calendar.current
        if req.useRange {
            let s = cal.startOfDay(for: req.from)
            let e = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: req.to))!
            return (s, e, cal.component(.month, from: s), cal.component(.year, from: s))
        }
        let (s, e) = monthRange(year: req.year, month: req.month, calendar: cal)
        return (s, e, req.month, req.year)
    }

    private func generate() {
        let p = period
        var o = req.options
        o.title = expandTitle(o.title ?? Strings.of(o.language).title, month: p.month, year: p.year, lang: o.language)
        do {
            let lines = try state.db.reportEntries(from: p.start, to: p.end,
                                                   filter: ReportFilter(clientId: req.clientId, projectId: req.projectId),
                                                   userName: state.userName)
            guard let r = buildReport(lines, options: o, calendar: .current) else {
                report = nil; pdfData = nil; document = nil
                message = "No entries in this period."
                return
            }
            report = r
            let data = PDFRenderer.render(r)
            pdfData = data
            document = PDFDocument(data: data)
            message = "\(r.entryCount) entries, \(fmtHours(r.totalHours, r.options.language))"
        } catch {
            report = nil; pdfData = nil; document = nil
            message = "\(error)"
        }
    }

    private func export() {
        generate()
        guard let data = pdfData else { return }
        let p = period
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let stem = req.options.language == .de ? "Leistungsnachweis" : "Timesheet"
        panel.nameFieldStringValue = String(format: "%@_%04d-%02d.pdf", stem, p.year, p.month)
        if panel.runModal() == .OK, let url = panel.url {
            do { try data.write(to: url); message = "Saved \(url.lastPathComponent)" }
            catch { message = "Could not save: \(error.localizedDescription)" }
        }
    }
}
