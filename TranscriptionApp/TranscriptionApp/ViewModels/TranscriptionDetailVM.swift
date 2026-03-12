import AppKit
import Foundation
import UniformTypeIdentifiers

@Observable
final class TranscriptionDetailVM {
    let audioService = AudioService()
    let ollamaService = OllamaService()
    var selectedSegmentIndex: Int?
    var showExportSheet = false
    var showSpeakerRenameFor: String?
    var ollamaAvailable: Bool?
    var summaryError: String?
    var audioLoadError: String?

    func loadAudio(for project: TranscriptionProject) {
        let path = project.audioFilePath
        let url = URL(fileURLWithPath: path)
        print("[DetailVM] loadAudio: \(path)")

        guard FileManager.default.fileExists(atPath: path) else {
            let error = "Fichier audio introuvable: \(url.lastPathComponent)"
            print("[DetailVM] ERREUR: \(error)")
            audioLoadError = error
            return
        }

        do {
            try audioService.load(url: url)
            audioLoadError = nil
            print("[DetailVM] Audio charge: duree=\(audioService.duration)s")
        } catch {
            let msg = "Impossible de charger l'audio: \(error.localizedDescription)"
            print("[DetailVM] ERREUR: \(msg)")
            audioLoadError = msg
        }
    }

    func seekToSegment(_ segment: Segment) {
        audioService.seek(to: segment.startTime)
        selectedSegmentIndex = segment.index
        if !audioService.isPlaying {
            audioService.play()
        }
    }

    func renameSpeaker(in project: TranscriptionProject, label: String, newName: String) {
        var names = project.speakerNames
        if newName.trimmingCharacters(in: .whitespaces).isEmpty {
            names.removeValue(forKey: label)
        } else {
            names[label] = newName
            // Sauvegarder le nom dans l'historique global
            SpeakerNameHistory.addNames([newName])
        }
        project.speakerNames = names
    }

    func exportProject(_ project: TranscriptionProject, format: ExportFormat) {
        let content = ExportService.export(project: project, format: format)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.title).\(format.fileExtension)"
        panel.allowedContentTypes = [.plainText]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Speaker Naming + Summary + Meeting Report

    func confirmSpeakerNames(project: TranscriptionProject) {
        project.status = .completed
        project.completedAt = Date()
    }

    func skipSpeakerNames(project: TranscriptionProject) {
        project.status = .completed
        project.completedAt = Date()
    }

    func regenerateAll(project: TranscriptionProject) {
        print("[Generation] regenerateAll appele - speakers: \(project.uniqueSpeakers)")
        project.status = .generatingSummary
        Task {
            await generateAll(project: project, clearExisting: true)
        }
    }

    /// Genere les syntheses par speaker PUIS le compte rendu global
    @MainActor
    private func generateAll(project: TranscriptionProject, clearExisting: Bool = false) async {
        summaryError = nil
        print("[Generation] Debut - \(project.uniqueSpeakers.count) speakers")

        let available = await ollamaService.ensureRunning()
        ollamaAvailable = available
        print("[Generation] LLM disponible: \(available)")

        guard available else {
            project.status = .completed
            summaryError = "Ollama non disponible. Lancez 'ollama serve'."
            print("[Generation] ERREUR: Ollama non disponible")
            return
        }

        if clearExisting {
            project.speakerSummaries = [:]
            project.meetingReport = nil
        }

        let selectedModel = OllamaModel(rawValue:
            UserDefaults.standard.string(forKey: "ollama_model")
                ?? OllamaModel.llama3_1.rawValue
        ) ?? .llama3_1
        print("[Generation] Modele: \(selectedModel.rawValue)")

        // 0. S'assurer que le modele est telecharge
        let modelReady = await ollamaService.ensureModelAvailable(selectedModel)
        guard modelReady else {
            project.status = .completed
            summaryError = "Impossible de telecharger le modele \(selectedModel.displayName). Verifiez Ollama."
            print("[Generation] ERREUR: modele \(selectedModel.rawValue) non disponible")
            return
        }

        // 1. Syntheses par speaker
        do {
            let summaries = try await ollamaService.generateAllSummaries(
                project: project,
                model: selectedModel
            )
            project.speakerSummaries = summaries
            project.summaryModelUsed = selectedModel.rawValue
            print("[Generation] Syntheses OK: \(summaries.count) speakers")
        } catch {
            summaryError = "Syntheses speakers: \(error.localizedDescription)"
            print("[Generation] ERREUR syntheses: \(error)")
        }

        // 2. Compte rendu de reunion
        do {
            print("[Generation] Debut compte rendu...")
            let report = try await ollamaService.generateMeetingReport(
                project: project,
                model: selectedModel
            )
            project.meetingReport = report
            project.reportModelUsed = selectedModel.rawValue
            print("[Generation] Compte rendu OK (\(report.count) chars)")
        } catch {
            let reportError = "Compte rendu: \(error.localizedDescription)"
            summaryError = summaryError != nil ? "\(summaryError!) | \(reportError)" : reportError
            print("[Generation] ERREUR compte rendu: \(error)")
        }

        project.status = .completed
    }

    // MARK: - Meeting Report Export

    func exportMeetingReportMD(project: TranscriptionProject) {
        guard let report = project.meetingReport, !report.isEmpty else { return }

        let content = MeetingReportExporter.exportMarkdown(report: report, title: project.title)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(project.title) - Compte rendu.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor
    func exportMeetingReportPDF(project: TranscriptionProject) {
        guard let report = project.meetingReport, !report.isEmpty else { return }

        do {
            let pdfData = try MeetingReportExporter.generatePDF(
                markdown: report,
                title: project.title
            )

            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(project.title) - Compte rendu.pdf"
            panel.allowedContentTypes = [.pdf]

            guard panel.runModal() == .OK, let url = panel.url else { return }
            try pdfData.write(to: url)
            print("[Export] PDF sauvegarde: \(url.path)")
        } catch {
            print("[Export PDF] Erreur: \(error)")
            summaryError = "Export PDF: \(error.localizedDescription)"
        }
    }

    // Legacy compatibility
    func regenerateSummaries(project: TranscriptionProject) {
        regenerateAll(project: project)
    }
}
