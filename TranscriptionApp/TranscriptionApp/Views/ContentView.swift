import SwiftData
import SwiftUI

struct ContentView: View {
    @Bindable var listVM: TranscriptionListVM
    let recordingVM: RecordingVM
    @State private var selectedProject: TranscriptionProject?

    var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: listVM, selection: $selectedProject)
                // Sur la colonne elle-meme : applique a NavigationSplitView, SwiftUI
                // l'ignorait et la barre laterale coupait les titres ("Bloom...")
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 400)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .top, spacing: 0) {
                    RecordingBanner(recordingVM: recordingVM, listVM: listVM)
                }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    @ViewBuilder
    private var detail: some View {
        if let project = selectedProject {
            TranscriptionDetail(
                project: project,
                estimationService: listVM.currentProject?.id == project.id ? listVM.estimationService : nil
            )
            // Etat propre a chaque projet (audio charge, noms en cours de saisie) :
            // sans cela, les noms saisis pour un projet s'appliquaient au suivant
            .id(project.id)
        } else {
            ContentUnavailableView(
                "No transcription selected",
                systemImage: "waveform",
                description: Text("Import an audio file or select an existing transcription.")
            )
        }
    }
}
