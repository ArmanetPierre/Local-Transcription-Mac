import SwiftData
import SwiftUI

struct TranscriptionDetail: View {
    @Bindable var project: TranscriptionProject
    var estimationService: EstimationService?
    @State private var viewModel = TranscriptionDetailVM()
    @State private var scrollTarget: Int?
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            if project.status == .awaitingSpeakerNames {
                // Audio player pour ecouter les extraits
                if viewModel.audioService.isLoaded {
                    AudioPlayerBar(audioService: viewModel.audioService)
                    Divider()
                } else if let audioError = viewModel.audioLoadError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(audioError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    Divider()
                }
                // Ecran d'identification des speakers
                SpeakerSetupView(project: project, viewModel: viewModel)
            } else if project.status.isProcessing || project.status == .pending {
                ProgressOverlay(project: project, summaryError: viewModel.summaryError, ollamaService: viewModel.ollamaService, estimationService: estimationService)
            } else if project.status == .failed {
                errorView
            } else {
                // Audio player
                if viewModel.audioService.isLoaded {
                    AudioPlayerBar(audioService: viewModel.audioService)
                    Divider()
                }

                // Compte rendu + Syntheses (hors de la List pour un affichage fiable)
                if project.meetingReport != nil || !project.speakerSummaries.isEmpty {
                    ScrollView {
                        VStack(spacing: 0) {
                            MeetingReportView(
                                project: project,
                                onExportMD: { viewModel.exportMeetingReportMD(project: project) },
                                onExportPDF: { viewModel.exportMeetingReportPDF(project: project) }
                            )
                            SpeakerSynthesisView(project: project, viewModel: viewModel)
                        }
                    }
                    .frame(maxHeight: 400)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                    Divider()
                }

                // Segments de transcription
                if project.segments.isEmpty {
                    emptySegmentsView
                } else {
                    segmentList
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if project.status == .completed {
                    if project.meetingReport != nil || !project.speakerSummaries.isEmpty {
                        // Rapport existant → bouton regenerer
                        Button {
                            viewModel.regenerateAll(project: project)
                        } label: {
                            Label("Regenerate", systemImage: "arrow.clockwise")
                        }
                        .help("Regenerate the meeting report and summaries with Ollama")
                    } else {
                        // Pas de rapport → bouton generer
                        Button {
                            viewModel.regenerateAll(project: project)
                        } label: {
                            Label("Meeting Report", systemImage: "brain")
                        }
                        .help("Generate the meeting report and summaries with Ollama")
                    }

                    Menu {
                        ForEach(ExportFormat.allCases) { format in
                            Button(format.displayName) {
                                viewModel.exportProject(project, format: format)
                            }
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .onAppear {
            print("[DEBUG Detail] status=\(project.status), segments=\(project.segments.count), uniqueSpeakers=\(project.uniqueSpeakers)")
            print("[DEBUG Detail] speakerSummariesData nil? \(project.speakerSummariesData == nil), bytes=\(project.speakerSummariesData?.count ?? 0)")
            print("[DEBUG Detail] speakerSummaries=\(project.speakerSummaries)")
            print("[DEBUG Detail] summaryModelUsed=\(project.summaryModelUsed ?? "nil")")

            // Recovery : si le projet est termine mais sans segments,
            // tenter de retrouver des segments orphelins dans la base SwiftData
            if project.status == .completed && project.segments.isEmpty {
                recoverOrphanedSegments()
            }

            if project.status == .completed {
                viewModel.loadAudio(for: project)
            }
        }
        .onChange(of: project.status) { _, newValue in
            if newValue == .completed {
                viewModel.loadAudio(for: project)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: $project.title)
                    .font(.title2.bold())
                    .textFieldStyle(.plain)

                HStack(spacing: 12) {
                    if let lang = project.language {
                        Label(lang.uppercased(), systemImage: "globe")
                    }
                    if project.audioDurationSec > 0 {
                        Label(TimeFormatting.durationText(project.audioDurationSec), systemImage: "clock")
                    }
                    if project.status == .completed && !project.uniqueSpeakers.isEmpty {
                        Label("\(project.uniqueSpeakers.count) speakers", systemImage: "person.2")
                    }
                    if project.status == .completed && !project.segments.isEmpty {
                        Label("\(project.segments.count) segments", systemImage: "text.alignleft")
                    }
                    if let processingTime = project.totalProcessingDurationSec {
                        Label("Processed in \(TimeFormatting.durationText(processingTime))", systemImage: "bolt")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // Avertissement synthese
                if let error = viewModel.summaryError, project.status == .completed {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
                }
            }
            Spacer()
        }
        .padding()
    }

    // MARK: - Error View

    private var isHuggingFaceAccessError: Bool {
        guard let msg = project.errorMessage else { return false }
        return msg.contains("403") || msg.contains("gated repo") || msg.contains("not in the authorized list")
    }

    private var errorView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: isHuggingFaceAccessError ? "lock.circle" : "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundStyle(isHuggingFaceAccessError ? .orange : .red)

            if isHuggingFaceAccessError {
                Text("HuggingFace Model Access Required")
                    .font(.title2.bold())

                Text("The speaker diarization models require you to accept their terms of use on HuggingFace.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 450)

                VStack(spacing: 10) {
                    Link(destination: URL(string: "https://huggingface.co/pyannote/speaker-diarization-3.1")!) {
                        HStack {
                            Image(systemName: "link")
                            Text("Accept: pyannote/speaker-diarization-3.1")
                        }
                        .frame(width: 320)
                    }
                    .buttonStyle(.borderedProminent)

                    Link(destination: URL(string: "https://huggingface.co/pyannote/speaker-diarization-community-1")!) {
                        HStack {
                            Image(systemName: "link")
                            Text("Accept: pyannote/speaker-diarization-community-1")
                        }
                        .frame(width: 320)
                    }
                    .buttonStyle(.borderedProminent)

                    Link(destination: URL(string: "https://huggingface.co/pyannote/segmentation-3.0")!) {
                        HStack {
                            Image(systemName: "link")
                            Text("Accept: pyannote/segmentation-3.0")
                        }
                        .frame(width: 320)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 4)

                Text("Click each link above, sign in to HuggingFace, and click \"Agree and access repository\". Then reimport your audio file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 450)

            } else {
                Text("Error")
                    .font(.title2.bold())

                Text(project.errorMessage ?? String(localized: "Unknown error"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 450)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty Segments

    private var emptySegmentsView: some View {
        ContentUnavailableView {
            Label("No segments", systemImage: "text.alignleft")
        } description: {
            Text("The transcription produced no segments.\nTry reimporting the audio file.")
        }
    }

    // MARK: - Segment Recovery

    /// Si la relation SwiftData segments est vide mais que les Segment existent en base,
    /// on les re-attache au projet (peut arriver apres une migration de schema).
    private func recoverOrphanedSegments() {
        let projectId = project.id
        let descriptor = FetchDescriptor<Segment>(
            predicate: #Predicate<Segment> { segment in
                segment.project?.id == projectId
            },
            sortBy: [SortDescriptor(\Segment.index)]
        )

        guard let segments = try? modelContext.fetch(descriptor), !segments.isEmpty else {
            print("[Recovery] Pas de segments trouves pour project \(projectId)")
            return
        }

        print("[Recovery] \(segments.count) segments retrouves, re-liaison au projet")
        project.segments = segments
    }

    // MARK: - Segment List

    private var segmentList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(project.sortedSegments, id: \.id) { segment in
                    SegmentRow(
                        segment: segment,
                        speakerDisplayName: project.displayName(for: segment.speakerLabel ?? "Unknown"),
                        isPlaying: isSegmentPlaying(segment),
                        onSeek: { viewModel.seekToSegment(segment) },
                        onRenameSpeaker: { newName in
                            if let label = segment.speakerLabel {
                                viewModel.renameSpeaker(in: project, label: label, newName: newName)
                            }
                        }
                    )
                    .id(segment.index)
                    .listRowBackground(isSegmentPlaying(segment) ? Color.accentColor.opacity(0.1) : nil)
                }
            }
            .listStyle(.plain)
            .onChange(of: viewModel.audioService.currentTime) { _, _ in
                // Scroller vers le segment en cours de lecture
                if let idx = viewModel.audioService.currentSegmentIndex(in: project.sortedSegments) {
                    if idx != scrollTarget {
                        scrollTarget = idx
                        withAnimation {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func isSegmentPlaying(_ segment: Segment) -> Bool {
        guard viewModel.audioService.isPlaying || viewModel.audioService.isLoaded else { return false }
        let time = viewModel.audioService.currentTime
        return time >= segment.startTime && time < segment.endTime
    }
}
