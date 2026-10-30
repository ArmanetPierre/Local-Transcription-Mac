import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Bindable var viewModel: TranscriptionListVM
    @Binding var selection: TranscriptionProject?
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TranscriptionProject.createdAt, order: .reverse) private var projects: [TranscriptionProject]

    var filteredProjects: [TranscriptionProject] {
        if viewModel.searchText.isEmpty {
            return projects
        }
        let query = viewModel.searchText.lowercased()
        return projects.filter { project in
            project.title.lowercased().contains(query)
                || project.segments.contains { $0.text.lowercased().contains(query) }
        }
    }

    var body: some View {
        List(selection: $selection) {
            // Zone d'import
            ImportDropZone { urls in
                viewModel.importFiles(urls, modelContext: modelContext)
                if selection == nil, let first = projects.first {
                    selection = first
                }
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))

            // Liste des transcriptions
            Section("Transcriptions") {
                ForEach(filteredProjects) { project in
                    TranscriptionRow(
                        project: project,
                        estimationService: viewModel.currentProject?.id == project.id ? viewModel.estimationService : nil
                    )
                        .tag(project)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                if selection == project { selection = nil }
                                viewModel.delete(project, modelContext: modelContext)
                            }
                            // La transcription en cours ecrit dans ce projet : l'annuler d'abord
                            .disabled(viewModel.currentProject?.id == project.id)
                        }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let project = filteredProjects[index]
                        guard viewModel.currentProject?.id != project.id else { continue }
                        if selection == project { selection = nil }
                        viewModel.delete(project, modelContext: modelContext)
                    }
                }
            }
        }
        .searchable(text: $viewModel.searchText, prompt: "Search...")
        .navigationTitle("Voxa")
        .toolbar {
            ToolbarItem {
                Button {
                    viewModel.isImporting = true
                } label: {
                    Label("Import", systemImage: "plus")
                }
            }
        }
        .fileImporter(
            isPresented: $viewModel.isImporting,
            allowedContentTypes: TranscriptionListVM.supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                viewModel.importFiles(urls, modelContext: modelContext)
            }
        }
    }
}
