import SwiftUI
import TimeCore

struct ProjectsSettingsTab: View {
    @Environment(AppState.self) private var state
    @State private var newClient = ""
    @State private var newProject = ""
    @State private var newProjectClient: Int64?
    @State private var newRepo = ""
    @State private var clientToDelete: Client?
    @State private var projectToDelete: Project?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading) {
                Text("Clients").font(.headline)
                List(state.clients) { c in
                    HStack {
                        Text(c.name)
                        Spacer()
                        Button(role: .destructive) { clientToDelete = c } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("New client", text: $newClient)
                    Button("Add") { state.createClient(named: newClient); newClient = "" }.disabled(newClient.isEmpty)
                }
            }
            VStack(alignment: .leading) {
                Text("Projects").font(.headline)
                List(state.projects) { p in
                    HStack {
                        Text(p.name)
                        Picker("", selection: Binding(get: { p.clientId }, set: { var q = p; q.clientId = $0; state.updateProject(q) })) {
                            Text("No client").tag(Int64?.none)
                            ForEach(state.clients) { c in Text(c.name).tag(Int64?.some(c.id!)) }
                        }
                        .labelsHidden().frame(width: 140)
                        Button(role: .destructive) { projectToDelete = p } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("New project", text: $newProject)
                    Picker("", selection: $newProjectClient) {
                        Text("No client").tag(Int64?.none)
                        ForEach(state.clients) { c in Text(c.name).tag(Int64?.some(c.id!)) }
                    }
                    .labelsHidden().frame(width: 140)
                    Button("Add") { state.createProject(named: newProject, clientId: newProjectClient); newProject = "" }
                        .disabled(newProject.isEmpty)
                }
                Text("Repositories").font(.headline).padding(.top, 8)
                List(state.repos) { r in
                    HStack {
                        Text(r.fullName)
                        Spacer()
                        Picker("", selection: Binding(get: { r.projectId }, set: { state.assignRepo(r.id!, to: $0) })) {
                            Text("Unmapped").tag(Int64?.none)
                            ForEach(state.projects) { p in Text(p.name).tag(Int64?.some(p.id!)) }
                        }
                        .labelsHidden().frame(width: 160)
                    }
                }
                HStack {
                    TextField("owner/name", text: $newRepo)
                    Button("Add") { state.addRepo(fullName: newRepo); if state.lastError == nil { newRepo = "" } }
                        .disabled(!newRepo.contains("/"))
                }
                Text("Repositories appear here after the first GitHub sync; add one by hand to search its issues before anything is assigned to you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .confirmationDialog("Delete client \"\(clientToDelete?.name ?? "")\"?", isPresented: Binding(get: { clientToDelete != nil }, set: { if !$0 { clientToDelete = nil } })) {
            Button("Delete", role: .destructive) { if let c = clientToDelete { state.deleteClient(c) }; clientToDelete = nil }
        } message: {
            Text("Its projects are kept and become unassigned.")
        }
        .confirmationDialog("Delete project \"\(projectToDelete?.name ?? "")\"?", isPresented: Binding(get: { projectToDelete != nil }, set: { if !$0 { projectToDelete = nil } })) {
            Button("Delete", role: .destructive) { if let p = projectToDelete { state.deleteProject(p) }; projectToDelete = nil }
        } message: {
            Text("All entries and repositories of this project are kept but lose their project assignment.")
        }
    }
}
